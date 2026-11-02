import Foundation
import AppKit
import Combine

@MainActor
public final class WritingAssistantCoordinator: ObservableObject, AXEngineDelegate {
    public static let shared = WritingAssistantCoordinator()

    @Published public private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published public private(set) var currentContext: FocusedTextContext?
    @Published public private(set) var issues: [WritingIssue] = []
    @Published public var pillState: PillVisualState = .allClear
    @Published public var isPopoverExpanded: Bool = false
    @Published public var isRewriteTabActive: Bool = false
    @Published public var isRewriting: Bool = false
    @Published public var rewrittenPreview: String?
    @Published public var customRewritePrompt: String = ""
    @Published public private(set) var lastErrorMessage: String?

    private let axEngine: AXEngine
    private let geminiService: GeminiService
    public let settings: AppSettings
    private let hotkeyMonitor = GlobalHotkeyMonitor()
    private var debounceTask: Task<Void, Never>?
    private var dismissedOriginals = Set<String>()
    private var lastAnalyzedParagraph: String = ""

    public var onOverlayStateChanged: (() -> Void)?

    public init(
        axEngine: AXEngine = .shared,
        geminiService: GeminiService = .shared,
        settings: AppSettings = .shared
    ) {
        self.axEngine = axEngine
        self.geminiService = geminiService
        self.settings = settings
        self.isAccessibilityTrusted = axEngine.isTrusted
        self.axEngine.delegate = self

        setupHotkeys()
    }

    public func start() {
        axEngine.start()
        hotkeyMonitor.start()
        isAccessibilityTrusted = axEngine.checkTrust(prompt: false)
    }

    public func stop() {
        debounceTask?.cancel()
        axEngine.stop()
        hotkeyMonitor.stop()
    }

    public func requestAccessibilityPermission() {
        isAccessibilityTrusted = axEngine.checkTrust(prompt: true)
    }

    public func openSystemSettings() {
        axEngine.openSystemAccessibilitySettings()
    }

    public func simulateDemoPillOnScreen(
        appName: String = "Notes",
        issues: [WritingIssue]? = nil
    ) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGPoint(x: screen.midX - 220, y: screen.midY + 140)
        let demoContext = FocusedTextContext(
            appName: appName,
            bundleID: "com.apple.Notes",
            pid: ProcessInfo.processInfo.processIdentifier,
            fullText: "Hi Alex,\n\nDue to the fact that their going to deploy tonight, we need to ensure all benchmarks is verified.",
            selectedText: nil,
            selectedRange: NSRange(location: 50, length: 0),
            anchorAppKitPoint: anchor
        )
        self.currentContext = demoContext
        self.issues = issues ?? [
            WritingIssue(
                original: "their going",
                replacement: "they're going",
                category: .correctness,
                explanation: "Use contraction 'they're' instead of possessive 'their'.",
                utf16Location: 30,
                utf16Length: 11,
                isLocalSpellcheck: false
            ),
            WritingIssue(
                original: "all benchmarks is",
                replacement: "all benchmarks are",
                category: .correctness,
                explanation: "Subject-verb agreement: plural 'benchmarks' takes 'are'.",
                utf16Location: 75,
                utf16Length: 17,
                isLocalSpellcheck: false
            )
        ]
        self.pillState = .issuesFound(count: self.issues.count, topCategory: .correctness)
        self.isPopoverExpanded = true
        self.onOverlayStateChanged?()
    }

    private func setupHotkeys() {
        hotkeyMonitor.onQuickAcceptShortcut = { [weak self] in
            guard let self = self, let topIssue = self.issues.first else { return }
            self.acceptIssue(topIssue)
        }

        hotkeyMonitor.onToggleRewritePanelShortcut = { [weak self] in
            guard let self = self else { return }
            self.axEngine.pollCurrentFocusedElement()
            self.isPopoverExpanded.toggle()
            if self.isPopoverExpanded, let ctx = self.currentContext {
                self.triggerImmediateCheck(for: ctx.analysisText, baseOffset: ctx.analysisRange.location)
            }
            self.onOverlayStateChanged?()
        }
    }

    private static func offsetIssue(_ issue: WritingIssue, by baseOffset: Int) -> WritingIssue {
        guard baseOffset > 0, let loc = issue.utf16Location else { return issue }
        var copy = issue
        copy.utf16Location = loc + baseOffset
        return copy
    }

    // MARK: - AXEngineDelegate

    nonisolated public func axEngineDidChangeTrustStatus(_ isTrusted: Bool) {
        Task { @MainActor in
            self.isAccessibilityTrusted = isTrusted
        }
    }

    nonisolated public func axEngineDidUpdateContext(_ context: FocusedTextContext?) {
        Task { @MainActor in
            self.handleUpdatedContext(context)
        }
    }

    private func handleUpdatedContext(_ context: FocusedTextContext?) {
        guard let ctx = context else {
            if !isPopoverExpanded {
                currentContext = nil
                onOverlayStateChanged?()
            }
            return
        }

        let previousApp = currentContext?.bundleID
        currentContext = ctx

        if previousApp != ctx.bundleID {
            dismissedOriginals.removeAll()
            rewrittenPreview = nil
        }

        if settings.isCurrentlyPaused() {
            pillState = .paused(reason: "Paused")
            onOverlayStateChanged?()
            return
        }

        let appKey = ctx.bundleID ?? ctx.appName

        if settings.isAppPaused(bundleID: appKey) {
            pillState = .paused(reason: "Paused in \(ctx.appName) (1 hr)")
            onOverlayStateChanged?()
            return
        }

        if settings.isAppBlocked(bundleID: appKey) {
            pillState = .paused(reason: "Disabled in \(ctx.appName)")
            onOverlayStateChanged?()
            return
        }

        guard settings.enableAsYouType else {
            pillState = .paused(reason: "Manual mode")
            onOverlayStateChanged?()
            return
        }

        let analysisRange = ctx.analysisRange
        let paragraph = ctx.analysisText
        let baseOffset = analysisRange.location
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= 3 else {
            debounceTask?.cancel()
            issues = []
            pillState = .allClear
            onOverlayStateChanged?()
            return
        }

        // If paragraph hasn't changed and we already have results, keep current state
        if paragraph == lastAnalyzedParagraph {
            onOverlayStateChanged?()
            return
        }

        // 1. Instant local spellcheck (<5ms)
        let localIssues = geminiService.runLocalSpellcheck(on: paragraph)
            .filter { !dismissedOriginals.contains($0.original) }
            .map { Self.offsetIssue($0, by: baseOffset) }
        if !localIssues.isEmpty && issues.isEmpty {
            issues = localIssues
            pillState = .issuesFound(count: localIssues.count, topCategory: .correctness)
        } else {
            pillState = .checking
        }
        onOverlayStateChanged?()

        // 2. Schedule debounced Gemini contextual check
        // Trigger faster (250ms) when user finishes a sentence with '.', '!', '?', or newline
        let endsWithSentencePunctuation = paragraph.hasSuffix(".") || paragraph.hasSuffix("!") || paragraph.hasSuffix("?") || paragraph.hasSuffix("\n")
        let delayMs = endsWithSentencePunctuation ? min(300, settings.debounceMs) : settings.debounceMs

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.performProofread(on: paragraph, localPreIssues: localIssues, baseOffset: baseOffset)
        }
    }

    public func triggerImmediateCheck(for text: String, baseOffset: Int = 0) {
        debounceTask?.cancel()
        let localIssues = geminiService.runLocalSpellcheck(on: text)
            .map { Self.offsetIssue($0, by: baseOffset) }
        pillState = .checking
        onOverlayStateChanged?()

        debounceTask = Task { [weak self] in
            await self?.performProofread(on: text, localPreIssues: localIssues, baseOffset: baseOffset)
        }
    }

    private func performProofread(on text: String, localPreIssues: [WritingIssue], baseOffset: Int = 0) async {
        do {
            let aiIssues = try await geminiService.proofread(text: text)
            guard !Task.isCancelled else { return }

            lastAnalyzedParagraph = text
            lastErrorMessage = nil

            var combined = aiIssues
                .filter { !dismissedOriginals.contains($0.original) }
                .map { Self.offsetIssue($0, by: baseOffset) }
            for local in localPreIssues where !dismissedOriginals.contains(local.original) {
                if !combined.contains(where: { $0.original.localizedCaseInsensitiveContains(local.original) }) {
                    combined.append(local)
                }
            }

            self.issues = combined
            if let first = combined.first {
                self.pillState = .issuesFound(count: combined.count, topCategory: first.category)
            } else {
                self.pillState = .allClear
            }
            self.onOverlayStateChanged?()
        } catch {
            guard !Task.isCancelled else { return }
            self.lastErrorMessage = error.localizedDescription
            if !localPreIssues.isEmpty {
                self.issues = localPreIssues
                self.pillState = .issuesFound(count: localPreIssues.count, topCategory: .correctness)
            } else {
                self.pillState = .error(message: error.localizedDescription)
            }
            self.onOverlayStateChanged?()
        }
    }

    // MARK: - User Actions on Issues & Rewrites

    public var onIssueAccepted: ((WritingIssue) -> Void)?
    public var onAllIssuesAccepted: (([WritingIssue], String) -> Void)?

    public func acceptIssue(_ issue: WritingIssue) {
        let currentText = currentContext?.fullText ?? lastAnalyzedParagraph
        let matchedRange = AXEngine.findBestOccurrenceRange(
            of: issue.original,
            preferredUTF16Location: issue.utf16Location,
            in: currentText
        )
        _ = axEngine.applyIssueReplacement(issue, in: currentText)

        onIssueAccepted?(issue)

        let delta = (issue.replacement as NSString).length - (issue.original as NSString).length
        let replacedLoc = matchedRange.location != NSNotFound ? matchedRange.location : (issue.utf16Location ?? 0)

        if let current = currentContext, matchedRange.location != NSNotFound {
            let nsCurrent = current.fullText as NSString
            if matchedRange.location + matchedRange.length <= nsCurrent.length {
                let updated = nsCurrent.replacingCharacters(in: matchedRange, with: issue.replacement)
                self.currentContext = FocusedTextContext(
                    appName: current.appName,
                    bundleID: current.bundleID,
                    pid: current.pid,
                    fullText: updated,
                    selectedText: current.selectedText,
                    selectedRange: current.selectedRange,
                    anchorAppKitPoint: current.anchorAppKitPoint
                )
                self.lastAnalyzedParagraph = updated
            }
        }

        // Shift UTF-16 offsets of remaining issues located after the accepted issue
        var remaining: [WritingIssue] = []
        for var item in issues where item.id != issue.id {
            if let loc = item.utf16Location, loc > replacedLoc {
                item.utf16Location = max(0, loc + delta)
            }
            remaining.append(item)
        }
        issues = remaining
        updatePillStateFromIssues()

        if issues.isEmpty && isPopoverExpanded {
            isPopoverExpanded = false
            onOverlayStateChanged?()
        }
    }

    public func acceptAllIssues() {
        guard var workingText = currentContext?.fullText ?? (lastAnalyzedParagraph.isEmpty ? nil : lastAnalyzedParagraph) else {
            return
        }
        let accepted = self.issues

        // Resolve ranges in workingText and apply from end to start so earlier replacements never shift later ranges
        let resolvedPairs: [(issue: WritingIssue, range: NSRange)] = issues.compactMap { issue in
            let range = AXEngine.findBestOccurrenceRange(
                of: issue.original,
                preferredUTF16Location: issue.utf16Location,
                in: workingText
            )
            guard range.location != NSNotFound else { return nil }
            return (issue, range)
        }.sorted { $0.range.location > $1.range.location }

        var nsWorking = workingText as NSString
        for pair in resolvedPairs {
            if pair.range.location + pair.range.length <= nsWorking.length {
                workingText = nsWorking.replacingCharacters(in: pair.range, with: pair.issue.replacement)
                nsWorking = workingText as NSString
            }
        }

        _ = axEngine.replaceSelectedOrFullText(with: workingText)

        onAllIssuesAccepted?(accepted, workingText)

        if let current = currentContext {
            self.currentContext = FocusedTextContext(
                appName: current.appName,
                bundleID: current.bundleID,
                pid: current.pid,
                fullText: workingText,
                selectedText: current.selectedText,
                selectedRange: current.selectedRange,
                anchorAppKitPoint: current.anchorAppKitPoint
            )
            self.lastAnalyzedParagraph = workingText
        }

        issues.removeAll()
        updatePillStateFromIssues()
    }

    public func dismissIssue(_ issue: WritingIssue) {
        dismissedOriginals.insert(issue.original)
        issues.removeAll { $0.id == issue.id }
        updatePillStateFromIssues()

        if issues.isEmpty && isPopoverExpanded {
            isPopoverExpanded = false
            onOverlayStateChanged?()
        }
    }

    public func addIssueWordToDictionary(_ issue: WritingIssue) {
        settings.addWordToDictionary(issue.original)
        geminiService.clearCache()
        dismissIssue(issue)
    }

    public func runRewritePreset(_ preset: RewritePreset, customPrompt: String? = nil) {
        let targetText: String
        if let sel = currentContext?.selectedText, !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetText = sel
        } else if let para = currentContext?.activeParagraph, !para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetText = para
        } else {
            return
        }

        isRewriting = true
        rewrittenPreview = nil

        Task {
            do {
                let result = try await geminiService.rewrite(text: targetText, preset: preset, customPrompt: customPrompt)
                self.rewrittenPreview = result
                self.lastErrorMessage = nil
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
            self.isRewriting = false
            self.onOverlayStateChanged?()
        }
    }

    public func applyRewrittenPreview() {
        guard let preview = rewrittenPreview else { return }
        _ = axEngine.replaceSelectedOrFullText(with: preview)
        rewrittenPreview = nil
        isPopoverExpanded = false
        onOverlayStateChanged?()
    }

    private func updatePillStateFromIssues() {
        if let first = issues.first {
            pillState = .issuesFound(count: issues.count, topCategory: first.category)
        } else {
            pillState = .allClear
        }
        onOverlayStateChanged?()
    }
}
