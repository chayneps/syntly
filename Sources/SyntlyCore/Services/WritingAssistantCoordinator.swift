import Foundation
import AppKit
import Combine

@MainActor
public final class WritingAssistantCoordinator: ObservableObject, AXEngineDelegate {
    public static let shared = WritingAssistantCoordinator()

    @Published public private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published public private(set) var currentContext: FocusedTextContext?
    @Published public private(set) var issues: [WritingIssue] = []
    @Published public private(set) var pillState: PillVisualState = .allClear
    @Published public var isPopoverExpanded: Bool = false
    @Published public var isRewriting: Bool = false
    @Published public var rewrittenPreview: String?
    @Published public var customRewritePrompt: String = ""
    @Published public private(set) var totalChecksCount: Int = 0
    @Published public private(set) var totalFixesApplied: Int = 0
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
                self.triggerImmediateCheck(for: ctx.activeParagraph)
            }
            self.onOverlayStateChanged?()
        }
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

        if settings.isAppBlocked(bundleID: ctx.bundleID) {
            pillState = .paused(reason: "Disabled in \(ctx.appName)")
            onOverlayStateChanged?()
            return
        }

        guard settings.enableAsYouType else {
            pillState = .paused(reason: "Manual mode")
            onOverlayStateChanged?()
            return
        }

        let paragraph = ctx.activeParagraph
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
        let localIssues = geminiService.runLocalSpellcheck(on: paragraph).filter {
            !dismissedOriginals.contains($0.original)
        }
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
            await self?.performProofread(on: paragraph, localPreIssues: localIssues)
        }
    }

    public func triggerImmediateCheck(for text: String) {
        debounceTask?.cancel()
        let localIssues = geminiService.runLocalSpellcheck(on: text)
        pillState = .checking
        onOverlayStateChanged?()

        debounceTask = Task { [weak self] in
            await self?.performProofread(on: text, localPreIssues: localIssues)
        }
    }

    private func performProofread(on text: String, localPreIssues: [WritingIssue]) async {
        do {
            let aiIssues = try await geminiService.proofread(text: text)
            guard !Task.isCancelled else { return }

            lastAnalyzedParagraph = text
            totalChecksCount += 1
            lastErrorMessage = nil

            var combined = aiIssues.filter { !dismissedOriginals.contains($0.original) }
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

    public func acceptIssue(_ issue: WritingIssue) {
        let currentText = currentContext?.fullText ?? lastAnalyzedParagraph
        let applied = axEngine.applyIssueReplacement(issue, in: currentText)
        if applied {
            totalFixesApplied += 1
        }
        issues.removeAll { $0.id == issue.id }
        updatePillStateFromIssues()
    }

    public func acceptAllIssues() {
        guard var workingText = currentContext?.fullText ?? (lastAnalyzedParagraph.isEmpty ? nil : lastAnalyzedParagraph) else {
            return
        }
        for issue in issues {
            if let range = workingText.range(of: issue.original) {
                workingText.replaceSubrange(range, with: issue.replacement)
                totalFixesApplied += 1
            }
        }
        _ = axEngine.replaceSelectedOrFullText(with: workingText)
        issues.removeAll()
        updatePillStateFromIssues()
    }

    public func dismissIssue(_ issue: WritingIssue) {
        dismissedOriginals.insert(issue.original)
        issues.removeAll { $0.id == issue.id }
        updatePillStateFromIssues()
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
                self.totalChecksCount += 1
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
        if axEngine.replaceSelectedOrFullText(with: preview) {
            totalFixesApplied += 1
        }
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
