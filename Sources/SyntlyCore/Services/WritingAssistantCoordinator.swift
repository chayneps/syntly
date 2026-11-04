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
    @Published public var openedByHover: Bool = false
    @Published public var isBadgeHovered: Bool = false
    @Published public var isPillHovered: Bool = false
    @Published public var isDialogHovered: Bool = false
    @Published public var rewrittenPreview: String?
    @Published public var customRewritePrompt: String = ""
    @Published public private(set) var lastErrorMessage: String?

    private let axEngine: AXEngine
    private let geminiService: GeminiService
    public let settings: AppSettings
    private let hotkeyMonitor = GlobalHotkeyMonitor()
    private var debounceTask: Task<Void, Never>?
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var dismissedOriginals = Set<String>()
    private var lastAnalyzedParagraph: String = ""

    public var onOverlayStateChanged: (() -> Void)?
    public var onOpenWritingPad: (() -> Void)?
    @Published public var incomingWritingPadText: String? = nil

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
            self?.togglePopover()
        }
    }

    public func togglePopover() {
        cancelHoverTimers()
        axEngine.pollCurrentFocusedElement()
        isPopoverExpanded.toggle()
        if isPopoverExpanded, let ctx = currentContext {
            triggerImmediateCheck(for: ctx.analysisText, baseOffset: ctx.analysisRange.location)
        }
        onOverlayStateChanged?()
    }

    public func openWritingPadToRewrite() {
        let textToBring: String
        if let current = currentContext {
            if let sel = current.selectedText, !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textToBring = sel
            } else if !current.activeParagraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textToBring = current.activeParagraph
            } else {
                textToBring = current.fullText
            }
        } else if !lastAnalyzedParagraph.isEmpty {
            textToBring = lastAnalyzedParagraph
        } else {
            textToBring = ""
        }

        if !textToBring.isEmpty {
            self.incomingWritingPadText = textToBring
        }

        cancelHoverTimers()
        isPopoverExpanded = false
        onOverlayStateChanged?()

        onOpenWritingPad?()
    }

    // MARK: - Hover Peek & Auto-Dismiss Logic

    public func handleBadgeHover(_ hovering: Bool) {
        isBadgeHovered = hovering

        guard case .issuesFound = pillState else {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            return
        }

        if hovering {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil

            if isPopoverExpanded { return }

            hoverOpenTask?.cancel()
            hoverOpenTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard !self.isPopoverExpanded else { return }
                guard case .issuesFound = self.pillState else { return }
                self.openedByHover = true
                self.isPopoverExpanded = true
                self.onOverlayStateChanged?()
            }
        } else {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil

            if isPopoverExpanded && openedByHover && !isDialogHovered && !isPillHovered {
                scheduleHoverClose(delay: 0.5)
            }
        }
    }

    public func handlePillHover(_ hovering: Bool) {
        isPillHovered = hovering
        if hovering {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil
        } else {
            if isPopoverExpanded && openedByHover && !isDialogHovered && !isBadgeHovered {
                scheduleHoverClose(delay: 0.5)
            }
        }
    }

    public func handleDialogHover(_ hovering: Bool) {
        isDialogHovered = hovering
        if hovering {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil
        } else {
            if isPopoverExpanded && openedByHover && !isPillHovered && !isBadgeHovered {
                scheduleHoverClose(delay: 0.5)
            }
        }
    }

    public func scheduleHoverClose(delay: Double = 0.5) {
        hoverCloseTask?.cancel()
        hoverCloseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.isPopoverExpanded && self.openedByHover else { return }
            guard !self.isDialogHovered && !self.isPillHovered && !self.isBadgeHovered else { return }
            self.isPopoverExpanded = false
            self.cancelHoverTimers()
            self.onOverlayStateChanged?()
        }
    }

    public func cancelHoverTimers() {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        hoverCloseTask?.cancel()
        hoverCloseTask = nil
        isBadgeHovered = false
        isPillHovered = false
        isDialogHovered = false
        openedByHover = false
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
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.handleUpdatedContext(context)
            }
        } else {
            Task { @MainActor in
                self.handleUpdatedContext(context)
            }
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
            issues = []
            lastAnalyzedParagraph = ""
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

        // 1. Instant local macOS NaturalLanguage + NSSpellChecker pass (<3ms) with active-word caret protection
        let isChromium = AXEngine.isChromiumOrElectronApp(bundleID: ctx.bundleID, appName: ctx.appName)
        let translatedCaretLocation: Int? = {
            guard let sel = ctx.selectedRange, sel.length == 0 else { return nil }
            if isChromium {
                return AXEngine.convertDOMSelectionToAXValueOffset(domLocation: sel.location, in: ctx.fullText)
            }
            return sel.location
        }()

        let localCaretOffset: Int? = {
            guard let caret = translatedCaretLocation, caret >= baseOffset else { return nil }
            return caret - baseOffset
        }()

        let localIssues = geminiService.runLocalSpellcheck(on: paragraph, caretUTF16Location: localCaretOffset)
            .filter { !dismissedOriginals.contains($0.original) }
            .map { Self.offsetIssue($0, by: baseOffset) }

        // Keep still-valid issues from unchanged sentences alive with updated UTF-16 locations while typing or moving cursor
        let activeWordInFullText = MacOSNLPEngine.activeTypingWordRange(
            in: ctx.fullText,
            caretUTF16Location: translatedCaretLocation
        )
        var provisionalIssues: [WritingIssue] = []

        for var existing in issues where !dismissedOriginals.contains(existing.original) {
            let liveRange = AXEngine.findBestOccurrenceRange(
                of: existing.original,
                preferredUTF16Location: existing.utf16Location,
                in: ctx.fullText
            )
            if liveRange.location != NSNotFound {
                existing.utf16Location = liveRange.location
                existing.utf16Length = liveRange.length
                provisionalIssues.append(existing)
            }
        }

        let sentenceCached = geminiService.cachedIssuesForUnchangedSentences(in: paragraph)
            .filter { !dismissedOriginals.contains($0.original) }
            .map { Self.offsetIssue($0, by: baseOffset) }

        for var candidate in (sentenceCached + localIssues) {
            let liveRange = AXEngine.findBestOccurrenceRange(
                of: candidate.original,
                preferredUTF16Location: candidate.utf16Location,
                in: ctx.fullText
            )
            guard liveRange.location != NSNotFound else { continue }
            if let active = activeWordInFullText, NSIntersectionRange(active, liveRange).length > 0 {
                continue
            }
            candidate.utf16Location = liveRange.location
            candidate.utf16Length = liveRange.length

            let overlappingIndices = provisionalIssues.indices.filter { idx in
                let existingRange = NSRange(
                    location: provisionalIssues[idx].utf16Location ?? 0,
                    length: provisionalIssues[idx].utf16Length ?? (provisionalIssues[idx].original as NSString).length
                )
                return NSIntersectionRange(existingRange, liveRange).length > 0
            }
            if overlappingIndices.isEmpty {
                provisionalIssues.append(candidate)
            } else if overlappingIndices.allSatisfy({ idx in
                let existingLen = provisionalIssues[idx].utf16Length ?? (provisionalIssues[idx].original as NSString).length
                return liveRange.length > existingLen || (!candidate.isLocalSpellcheck && provisionalIssues[idx].isLocalSpellcheck)
            }) {
                for idx in overlappingIndices.reversed() {
                    provisionalIssues.remove(at: idx)
                }
                provisionalIssues.append(candidate)
            }
        }

        provisionalIssues.sort { ($0.utf16Location ?? 0) < ($1.utf16Location ?? 0) }

        // Always update internal issues array so invalidated partial/stale issues are immediately removed
        self.issues = provisionalIssues

        // Surface instant local NLP & spellcheck issues immediately on the pill
        let newPillState: PillVisualState
        if !provisionalIssues.isEmpty {
            newPillState = .issuesFound(
                count: provisionalIssues.count,
                topCategory: provisionalIssues.first?.category ?? .correctness
            )
        } else {
            newPillState = .checking
        }

        if pillState != newPillState {
            pillState = newPillState
            onOverlayStateChanged?()
        }

        // If paragraph text hasn't changed (e.g. only caret moved), do not re-run debounced Gemini API call
        if paragraph == lastAnalyzedParagraph {
            onOverlayStateChanged?()
            return
        }

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
        // Re-run local NLP & spellcheck with `caretUTF16Location: nil` now that the user has paused typing
        // for the debounce interval, so sentence-final words and missing question marks at the caret are detected.
        let settledLocalIssues = geminiService.runLocalSpellcheck(on: text, caretUTF16Location: nil)
            .filter { !dismissedOriginals.contains($0.original) }
            .map { Self.offsetIssue($0, by: baseOffset) }

        do {
            let aiIssues = try await geminiService.proofread(text: text)
            guard !Task.isCancelled else { return }
            if let currentAnalysis = currentContext?.analysisText, currentAnalysis != text {
                return
            }

            lastAnalyzedParagraph = text
            lastErrorMessage = nil

            var combined = aiIssues
                .filter { !dismissedOriginals.contains($0.original) }
                .map { Self.offsetIssue($0, by: baseOffset) }

            for local in (settledLocalIssues.isEmpty ? localPreIssues : settledLocalIssues) where !dismissedOriginals.contains(local.original) {
                let localRange = NSRange(
                    location: local.utf16Location ?? 0,
                    length: local.utf16Length ?? (local.original as NSString).length
                )
                let overlapsExisting = combined.contains { existing in
                    let existingRange = NSRange(
                        location: existing.utf16Location ?? 0,
                        length: existing.utf16Length ?? (existing.original as NSString).length
                    )
                    return NSIntersectionRange(localRange, existingRange).length > 0
                        || existing.original.localizedCaseInsensitiveContains(local.original)
                        || local.original.localizedCaseInsensitiveContains(existing.original)
                }
                if !overlapsExisting {
                    combined.append(local)
                }
            }
            combined.sort { ($0.utf16Location ?? 0) < ($1.utf16Location ?? 0) }

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
            let fallbackLocal = settledLocalIssues.isEmpty ? localPreIssues : settledLocalIssues
            if !fallbackLocal.isEmpty {
                self.issues = fallbackLocal
                self.pillState = .issuesFound(count: fallbackLocal.count, topCategory: .correctness)
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
        guard !axEngine.isApplyingReplacement else { return }
        debounceTask?.cancel()
        dismissedOriginals.insert(issue.original)
        geminiService.clearCache()

        let currentText = currentContext?.fullText ?? lastAnalyzedParagraph
        let matchedRange = AXEngine.findBestOccurrenceRange(
            of: issue.original,
            preferredUTF16Location: issue.utf16Location,
            in: currentText
        )
        guard matchedRange.location != NSNotFound else {
            // Word no longer exists in currentText as a whole word (user edited it or moved on)
            issues.removeAll { $0.id == issue.id || $0.original == issue.original }
            updatePillStateFromIssues()
            if issues.isEmpty && isPopoverExpanded {
                isPopoverExpanded = false
                cancelHoverTimers()
            }
            onOverlayStateChanged?()
            return
        }
        let applied = axEngine.applyIssueReplacement(issue, in: currentText)
        guard applied else { return }

        onIssueAccepted?(issue)

        let delta = (issue.replacement as NSString).length - (issue.original as NSString).length
        let replacedLoc = matchedRange.location

        if let current = currentContext {
            let nsCurrent = current.fullText as NSString
            if matchedRange.location + matchedRange.length <= nsCurrent.length {
                let updated = nsCurrent.replacingCharacters(in: matchedRange, with: issue.replacement)
                let updatedContext = FocusedTextContext(
                    appName: current.appName,
                    bundleID: current.bundleID,
                    pid: current.pid,
                    fullText: updated,
                    selectedText: current.selectedText,
                    selectedRange: current.selectedRange,
                    anchorAppKitPoint: current.anchorAppKitPoint
                )
                self.currentContext = updatedContext
                self.lastAnalyzedParagraph = updatedContext.analysisText
            }
        }

        // Remove the accepted issue AND any overlapping sub-issues covering the same UTF-16 range,
        // and shift UTF-16 offsets of remaining issues located after the accepted issue.
        var remaining: [WritingIssue] = []
        for var item in issues where item.id != issue.id && !(item.original == issue.original && item.replacement == issue.replacement) {
            let itemRange = NSRange(
                location: item.utf16Location ?? 0,
                length: item.utf16Length ?? (item.original as NSString).length
            )
            if NSIntersectionRange(itemRange, matchedRange).length > 0 {
                dismissedOriginals.insert(item.original)
                continue
            }
            if let loc = item.utf16Location, loc > replacedLoc {
                item.utf16Location = max(0, loc + delta)
            }
            remaining.append(item)
        }

        // Re-evaluate local NLP on updated text so sequential Alt-Tab keypresses can immediately fix
        // terminal question marks, periods, or newly revealed issues without waiting.
        if let current = currentContext {
            let freshLocal = geminiService.runLocalSpellcheck(on: current.analysisText, caretUTF16Location: current.selectedRange?.location)
            for fresh in freshLocal where !dismissedOriginals.contains(fresh.original) {
                let freshRange = NSRange(
                    location: fresh.utf16Location ?? 0,
                    length: fresh.utf16Length ?? (fresh.original as NSString).length
                )
                let alreadyPresent = remaining.contains { existing in
                    let existingRange = NSRange(
                        location: existing.utf16Location ?? 0,
                        length: existing.utf16Length ?? (existing.original as NSString).length
                    )
                    return NSIntersectionRange(freshRange, existingRange).length > 0
                        || existing.original == fresh.original
                }
                if !alreadyPresent {
                    remaining.append(fresh)
                }
            }
            remaining.sort { ($0.utf16Location ?? 0) < ($1.utf16Location ?? 0) }
        }

        issues = remaining

        if issues.isEmpty {
            pillState = .allClear
            if isPopoverExpanded {
                isPopoverExpanded = false
                cancelHoverTimers()
            }
        } else {
            updatePillStateFromIssues()
        }
        onOverlayStateChanged?()
    }

    public func acceptAllIssues() {
        debounceTask?.cancel()
        geminiService.clearCache()
        lastAnalyzedParagraph = ""

        guard var workingText = currentContext?.fullText ?? (lastAnalyzedParagraph.isEmpty ? nil : lastAnalyzedParagraph) else {
            issues = []
            pillState = .allClear
            isPopoverExpanded = false
            cancelHoverTimers()
            onOverlayStateChanged?()
            return
        }
        let accepted = self.issues
        for item in accepted {
            dismissedOriginals.insert(item.original)
        }

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

        issues = []
        pillState = .allClear
        isPopoverExpanded = false
        cancelHoverTimers()
        onOverlayStateChanged?()

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
        }
    }

    public func dismissIssue(_ issue: WritingIssue) {
        dismissedOriginals.insert(issue.original)
        issues.removeAll { $0.id == issue.id || ($0.original == issue.original && $0.replacement == issue.replacement) }
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
