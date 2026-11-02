import Foundation
import AppKit
import ApplicationServices
import Carbon

public struct FocusedTextContext: Equatable {
    public let appName: String
    public let bundleID: String?
    public let pid: pid_t
    public let fullText: String
    public let selectedText: String?
    public let selectedRange: NSRange?
    /// Screen frame in AppKit coordinates (bottom-left origin) suitable for positioning an `NSPanel`
    public let anchorAppKitPoint: CGPoint

    public init(
        appName: String,
        bundleID: String?,
        pid: pid_t,
        fullText: String,
        selectedText: String? = nil,
        selectedRange: NSRange? = nil,
        anchorAppKitPoint: CGPoint = CGPoint(x: 300, y: 300)
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.fullText = fullText
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.anchorAppKitPoint = anchorAppKitPoint
    }

    public var activeParagraphRange: NSRange {
        let nsText = fullText as NSString
        guard nsText.length > 0 else { return NSRange(location: 0, length: 0) }
        if let sel = selectedRange, sel.location <= nsText.length {
            let safeRange = NSRange(location: min(sel.location, max(0, nsText.length - 1)), length: 0)
            return nsText.paragraphRange(for: safeRange)
        }
        return NSRange(location: 0, length: nsText.length)
    }

    public var activeParagraph: String {
        guard !fullText.isEmpty else { return "" }
        let nsText = fullText as NSString
        return nsText.substring(with: activeParagraphRange)
    }

    /// Returns the UTF-16 range to analyze for live proofreading.
    /// For typical messages and multi-line bulleted/numbered lists (<= 1500 UTF-16 code units),
    /// analyzes the full text so all bullet items and surrounding lines are checked together
    /// with accurate full-text UTF-16 offsets. For longer documents, analyzes the active paragraph.
    public var analysisRange: NSRange {
        let nsText = fullText as NSString
        guard nsText.length > 0 else { return NSRange(location: 0, length: 0) }
        if nsText.length <= 1500 {
            return NSRange(location: 0, length: nsText.length)
        }
        return activeParagraphRange
    }

    public var analysisText: String {
        guard !fullText.isEmpty else { return "" }
        let nsText = fullText as NSString
        return nsText.substring(with: analysisRange)
    }
}

public protocol AXEngineDelegate: AnyObject {
    func axEngineDidUpdateContext(_ context: FocusedTextContext?)
    func axEngineDidChangeTrustStatus(_ isTrusted: Bool)
}

/// Abstraction over low-level AXUIElement attribute operations and clipboard paste
/// so unit/E2E tests can deterministically simulate Chromium/Electron/Slack DOM offset drift.
public protocol AXElementAccessing: AnyObject {
    func copyString(_ element: AXUIElement, attribute: String) -> String?
    func copyRange(_ element: AXUIElement, attribute: String) -> NSRange?
    func setRange(_ element: AXUIElement, attribute: String, range: NSRange) -> AXError
    func setString(_ element: AXUIElement, attribute: String, value: String) -> AXError
    func isChromiumOrElectron(_ element: AXUIElement) -> Bool?
    func performPaste(_ text: String) -> Bool
}

public final class AXEngine {
    public static let shared = AXEngine()

    public weak var delegate: AXEngineDelegate?
    public private(set) var isTrusted: Bool = AXIsProcessTrusted()
    /// Optional hook used by End-to-End tests to intercept and verify in-place text replacements without mutating external windows.
    public var testReplacementHandler: ((_ issue: WritingIssue?, _ resultingText: String) -> Bool)?
    /// Optional low-level element accessor used by tests to simulate Chromium/Electron DOM selection offset drift.
    public var elementAccessor: AXElementAccessing?

    private var currentObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var lastFocusedElement: AXUIElement?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var trustPollTimer: Timer?
    private var enabledElectronPIDs = Set<pid_t>()

    public init() {}

    public func setTestingFocusedElement(_ element: AXUIElement?) {
        self.lastFocusedElement = element
    }

    // MARK: - Lifecycle & Permissions

    public func start() {
        // Silently check trust status on startup; never trigger an invasive OS modal prompt automatically.
        checkTrust(prompt: false)
        setupWorkspaceNotifications()
        startTrustPolling()

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            attachToApplication(frontApp)
        }
    }

    public func stop() {
        detachObserver()
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()
        trustPollTimer?.invalidate()
        trustPollTimer = nil
    }

    @discardableResult
    public func checkTrust(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted != isTrusted {
            isTrusted = trusted
            delegate?.axEngineDidChangeTrustStatus(trusted)
        }
        return trusted
    }

    public func openSystemAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startTrustPolling() {
        trustPollTimer?.invalidate()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let wasTrusted = self.isTrusted
            let nowTrusted = self.checkTrust(prompt: false)
            if !wasTrusted && nowTrusted, let frontApp = NSWorkspace.shared.frontmostApplication {
                self.attachToApplication(frontApp)
            }
        }
    }

    // MARK: - App Activation & AXObserver Setup

    private func setupWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        let token = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self.attachToApplication(app)
        }
        workspaceTokens.append(token)
    }

    public func attachToApplication(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        guard checkTrust(prompt: false) else { return }

        // Enable Electron / Chromium accessibility DOM tree if not yet enabled for this PID
        enableElectronAccessibilityIfNeeded(pid: pid)

        if observedPID == pid, currentObserver != nil {
            pollCurrentFocusedElement()
            return
        }

        detachObserver()
        observedPID = pid

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon = refcon else { return }
            let engine = Unmanaged<AXEngine>.fromOpaque(refcon).takeUnretainedValue()
            let notifName = notification as String
            DispatchQueue.main.async {
                engine.handleAXNotification(notifName)
            }
        }

        let err = AXObserverCreate(pid, callback, &observer)
        guard err == .success, let axObserver = observer else {
            pollCurrentFocusedElement()
            return
        }

        currentObserver = axObserver
        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let notifications: [String] = [
            kAXFocusedUIElementChangedNotification,
            kAXValueChangedNotification,
            kAXSelectedTextChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification
        ]

        for notif in notifications {
            AXObserverAddNotification(axObserver, appElement, notif as CFString, selfPtr)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(axObserver),
            .defaultMode
        )

        pollCurrentFocusedElement()
    }

    private func detachObserver() {
        if let observer = currentObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        currentObserver = nil
        observedPID = 0
    }

    private func enableElectronAccessibilityIfNeeded(pid: pid_t) {
        guard !enabledElectronPIDs.contains(pid) else { return }
        enabledElectronPIDs.insert(pid)

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func handleAXNotification(_ notification: String) {
        pollCurrentFocusedElement()
    }

    // MARK: - Inspect Focused Text Element

    public func pollCurrentFocusedElement() {
        guard checkTrust(prompt: false) else {
            delegate?.axEngineDidUpdateContext(nil)
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            delegate?.axEngineDidUpdateContext(nil)
            return
        }

        // Ignore Syntly's own floating windows unless testing in Writing Pad
        if frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)

        guard err == .success, let elementRef = focusedRef else {
            delegate?.axEngineDidUpdateContext(nil)
            return
        }

        let element = elementRef as! AXUIElement

        // Security guardrail: Never inspect password / secure text fields
        if isSecureTextField(element) {
            delegate?.axEngineDidUpdateContext(nil)
            return
        }

        guard isEditableTextElement(element) else {
            delegate?.axEngineDidUpdateContext(nil)
            return
        }

        lastFocusedElement = element

        let fullText = copyStringAttribute(element, attribute: kAXValueAttribute) ?? ""
        let selectedText = copyStringAttribute(element, attribute: kAXSelectedTextAttribute)
        let selectedRange = copyRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute)
        let anchorPoint = resolveAnchorAppKitPoint(for: element, selectedRange: selectedRange)

        let context = FocusedTextContext(
            appName: frontApp.localizedName ?? "App",
            bundleID: frontApp.bundleIdentifier,
            pid: frontApp.processIdentifier,
            fullText: fullText,
            selectedText: selectedText,
            selectedRange: selectedRange,
            anchorAppKitPoint: anchorPoint
        )

        delegate?.axEngineDidUpdateContext(context)
    }

    // MARK: - Replacing Text (3-Tier Fallback Cascade with Selection Calibration)

    /// Normalizes 1-to-1 BMP typographic variants (`\u{00A0}` non-breaking space -> `' '`,
    /// curly apostrophes `’`/`‘` -> `'`, curly quotes `“`/`”` -> `"`) while strictly preserving UTF-16 length.
    public static func normalizeTypographicCharacters(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00A0, 0x2007, 0x202F:
                scalars.append(UnicodeScalar(0x0020)!)
            case 0x2018, 0x2019, 0x02BC, 0xFF07:
                scalars.append(UnicodeScalar(0x0027)!)
            case 0x201C, 0x201D, 0xFF02:
                scalars.append(UnicodeScalar(0x0022)!)
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    public static func typographicallyEqual(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard (lhs as NSString).length == (rhs as NSString).length else { return false }
        return normalizeTypographicCharacters(lhs) == normalizeTypographicCharacters(rhs)
    }

    /// Returns true if `range` in `nsText` respects word boundaries at the start and end of `substring`
    /// whenever `substring` starts or ends with an alphanumeric character.
    public static func isWholeWordMatch(range: NSRange, of substring: String, in nsText: NSString) -> Bool {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location + range.length <= nsText.length else {
            return false
        }
        let nsSub = substring as NSString
        guard nsSub.length > 0 else { return false }

        let alphanumerics = CharacterSet.alphanumerics
        func isWordUnit(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return alphanumerics.contains(scalar)
        }

        if isWordUnit(nsSub.character(at: 0)), range.location > 0 {
            if isWordUnit(nsText.character(at: range.location - 1)) {
                return false
            }
        }

        if isWordUnit(nsSub.character(at: nsSub.length - 1)), range.location + range.length < nsText.length {
            if isWordUnit(nsText.character(at: range.location + range.length)) {
                return false
            }
        }

        return true
    }

    /// Finds the occurrence of `substring` in `text` whose UTF-16 location is closest to `preferredUTF16Location`,
    /// preferring whole-word boundary matches over partial-word substring matches (e.g. matching standalone `"his"` over `"this"`),
    /// and tolerating `\u{00A0}` (`&nbsp;`) and smart quotes (`’`, `“`, `”`).
    public static func findBestOccurrenceRange(
        of substring: String,
        preferredUTF16Location: Int?,
        in text: String
    ) -> NSRange {
        guard !substring.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        let nsText = text as NSString
        let subLen = (substring as NSString).length
        guard subLen <= nsText.length else { return NSRange(location: NSNotFound, length: 0) }

        if let loc = preferredUTF16Location,
           loc >= 0,
           loc + subLen <= nsText.length {
            let exactRange = NSRange(location: loc, length: subLen)
            if typographicallyEqual(nsText.substring(with: exactRange), substring),
               isWholeWordMatch(range: exactRange, of: substring, in: nsText) {
                return exactRange
            }
        }

        let normText = normalizeTypographicCharacters(text) as NSString
        let normSub = normalizeTypographicCharacters(substring)

        var searchRange = NSRange(location: 0, length: normText.length)
        var bestWholeWordRange = NSRange(location: NSNotFound, length: 0)
        var bestWholeWordDistance = Int.max
        var bestFallbackRange = NSRange(location: NSNotFound, length: 0)
        var bestFallbackDistance = Int.max

        while searchRange.location < normText.length {
            let found = normText.range(of: normSub, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }

            let wholeWord = isWholeWordMatch(range: found, of: normSub, in: normText)
            let distance = preferredUTF16Location.map { abs(found.location - $0) } ?? found.location

            if wholeWord {
                if distance < bestWholeWordDistance {
                    bestWholeWordDistance = distance
                    bestWholeWordRange = found
                }
            } else if distance < bestFallbackDistance {
                bestFallbackDistance = distance
                bestFallbackRange = found
            }

            let nextLoc = found.location + max(1, found.length)
            searchRange = NSRange(location: nextLoc, length: normText.length - nextLoc)
        }

        return bestWholeWordRange.location != NSNotFound ? bestWholeWordRange : bestFallbackRange
    }

    /// Estimates candidate UTF-16 offset drifts caused by rich-text bullet / numbered list markers or CRLF line endings
    /// in Chromium/Electron/WebKit editors (where `kAXValueAttribute` includes `"• "`, `"1. "`, or `\r\n` sequences
    /// that count for fewer offsets in `kAXSelectedTextRangeAttribute`).
    public static func estimateListMarkerDrifts(in text: String, upTo utf16Location: Int) -> [Int] {
        let nsText = text as NSString
        let limit = min(max(0, utf16Location), nsText.length)
        guard limit > 0 else { return [] }

        let bulletChars = CharacterSet(charactersIn: "•◦▪▫▸‣⁃-*+☐☑✓✔")
        var bulletLineCount = 0
        var bulletPrefixTotalUnits = 0
        var numberedLineCount = 0
        var numberedPrefixTotalUnits = 0
        var crlfCount = 0

        // Count CRLF (\r\n) sequences prior to `limit`
        if limit >= 2 {
            var idx = 0
            while idx + 1 < limit {
                if nsText.character(at: idx) == 0x0D && nsText.character(at: idx + 1) == 0x0A {
                    crlfCount += 1
                    idx += 2
                } else {
                    idx += 1
                }
            }
        }

        var lineStart = 0
        while lineStart <= limit && lineStart < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = nsText.substring(with: lineRange)
            let nsLine = line as NSString

            // Count optional leading spaces/tabs
            var idx = 0
            while idx < nsLine.length {
                let ch = nsLine.character(at: idx)
                if ch == 0x20 || ch == 0x09 || ch == 0x00A0 {
                    idx += 1
                } else {
                    break
                }
            }

            if idx < nsLine.length {
                let firstScalar = UnicodeScalar(nsLine.character(at: idx))
                if let scalar = firstScalar, bulletChars.contains(scalar) {
                    var afterBullet = idx + 1
                    var spaceCount = 0
                    while afterBullet < nsLine.length {
                        let sp = nsLine.character(at: afterBullet)
                        if sp == 0x20 || sp == 0x09 || sp == 0x00A0 {
                            spaceCount += 1
                            afterBullet += 1
                        } else {
                            break
                        }
                    }
                    // Either a classic "• " prefix or a Unicode bullet symbol at the start of a list item
                    if spaceCount > 0 || (scalar.value >= 0x2022 && scalar.value <= 0x27FF) {
                        if lineRange.location + idx < limit {
                            bulletLineCount += 1
                            bulletPrefixTotalUnits += (idx + 1 + spaceCount)
                        }
                    }
                } else {
                    // Check for ordered list marker such as "1. ", "2. ", "10. ", "1) ", "a. ", "a) "
                    var markerEnd = idx
                    while markerEnd < nsLine.length {
                        let ch = nsLine.character(at: markerEnd)
                        if ch >= 0x30 && ch <= 0x39 {
                            markerEnd += 1
                        } else {
                            break
                        }
                    }
                    // Also support single alphabetic list markers ("a. ", "b) ")
                    if markerEnd == idx && idx + 2 < nsLine.length {
                        let ch = nsLine.character(at: idx)
                        let isAlpha = (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x41 && ch <= 0x5A)
                        if isAlpha {
                            markerEnd = idx + 1
                        }
                    }
                    if markerEnd > idx && markerEnd + 1 < nsLine.length {
                        let punct = nsLine.character(at: markerEnd)
                        let spaceAfter = nsLine.character(at: markerEnd + 1)
                        if (punct == 0x2E || punct == 0x29) && (spaceAfter == 0x20 || spaceAfter == 0x09 || spaceAfter == 0x00A0) {
                            if lineRange.location + idx < limit {
                                numberedLineCount += 1
                                numberedPrefixTotalUnits += (markerEnd + 2 - idx)
                            }
                        }
                    }
                }
            }

            let nextStart = lineRange.location + lineRange.length
            if nextStart <= lineStart { break }
            lineStart = nextStart
        }

        var candidates: [Int] = []
        func appendUnique(_ drift: Int) {
            if drift != 0 && !candidates.contains(drift) {
                candidates.append(drift)
            }
        }

        if bulletLineCount > 0 {
            // In Slack/Chromium, each "• " (2 UTF-16 units in AXValue) counts as 1 unit in AXSelectedTextRange -> -1 per bullet
            appendUnique(-bulletLineCount)
            // If the editor counts 0 units for "• " -> -2 per bullet
            appendUnique(-(bulletLineCount * 2))
            appendUnique(-bulletPrefixTotalUnits)
            appendUnique(-(bulletPrefixTotalUnits - bulletLineCount))
        }

        if numberedLineCount > 0 {
            // In Chromium <ol><li>, "1. " (3 UTF-16 units in AXValue) counts as 1 unit in AXSelectedTextRange -> -(len - 1) per item
            appendUnique(-(numberedPrefixTotalUnits - numberedLineCount))
            appendUnique(-numberedPrefixTotalUnits)
            appendUnique(-numberedLineCount)
        }

        if bulletLineCount > 0 && numberedLineCount > 0 {
            let combinedSingle = -(bulletLineCount + (numberedPrefixTotalUnits - numberedLineCount))
            appendUnique(combinedSingle)
            appendUnique(-(bulletPrefixTotalUnits + numberedPrefixTotalUnits))
        }

        if crlfCount > 0 {
            appendUnique(-crlfCount)
            if bulletLineCount > 0 {
                appendUnique(-(bulletLineCount + crlfCount))
            }
            if numberedLineCount > 0 {
                appendUnique(-((numberedPrefixTotalUnits - numberedLineCount) + crlfCount))
            }
        }

        return candidates
    }

    /// Computes the exact UTF-16 offset adjustment between `expected` and `actualAtRange`
    /// when `kAXSelectedTextAttribute` is shifted left or right due to rich-text / DOM markers.
    public static func computeRangeOffsetCorrection(expected: String, actualAtRange: String) -> Int? {
        if typographicallyEqual(expected, actualAtRange) { return 0 }
        let nsExpected = normalizeTypographicCharacters(expected) as NSString
        let nsActual = normalizeTypographicCharacters(actualAtRange) as NSString
        let expLen = nsExpected.length
        let actLen = nsActual.length
        guard expLen >= 2, actLen >= 1 else { return nil }

        let maxOverlap = min(expLen - 1, actLen)

        // Case 1: DOM selection is shifted to the RIGHT of `expected` (requires negative shift).
        // A suffix of `expected` matches a prefix of `actualAtRange`.
        if maxOverlap >= 1 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                if overlap < 2 && actLen > 1 { continue }
                let expectedSuffix = nsExpected.substring(from: expLen - overlap)
                let actualPrefix = nsActual.substring(to: overlap)
                if expectedSuffix == actualPrefix {
                    return -(expLen - overlap)
                }
            }
        }

        // Case 2: DOM selection is shifted to the LEFT of `expected` (requires positive shift).
        // A prefix of `expected` matches a suffix of `actualAtRange`.
        if maxOverlap >= 2 {
            for overlap in stride(from: maxOverlap, through: 2, by: -1) {
                let expectedPrefix = nsExpected.substring(to: overlap)
                let actualSuffix = nsActual.substring(from: actLen - overlap)
                if expectedPrefix == actualSuffix {
                    return actLen - overlap
                }
            }
        }

        return nil
    }

    /// Selects `rawRange` and verifies `kAXSelectedTextAttribute` against `expectedOriginal`.
    /// If rich-text bullets or DOM list markers shift the selection offset (as in Slack/Chromium),
    /// calibrates the range using overlap detection, list marker drift estimation, and local search
    /// until `kAXSelectedTextAttribute` matches `expectedOriginal`.
    public func calibrateAndSelectRange(
        for expectedOriginal: String,
        rawRange: NSRange,
        in fullText: String,
        element: AXUIElement,
        isChromium: Bool
    ) -> NSRange? {
        guard rawRange.location != NSNotFound, rawRange.length > 0 else { return nil }

        var triedLocations = Set<Int>()

        func tryLocation(_ loc: Int) -> (matched: Bool, actualText: String?) {
            guard loc >= 0 else { return (false, nil) }
            triedLocations.insert(loc)
            let candidate = NSRange(location: loc, length: rawRange.length)
            _ = setRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute, range: candidate)
            let actual = readSettledSelectedText(from: element, expectedRange: candidate, isChromium: isChromium)
            if let actual = actual, Self.typographicallyEqual(actual, expectedOriginal) {
                return (true, actual)
            }
            return (false, actual)
        }

        // 1. Try rawRange first
        let initialAttempt = tryLocation(rawRange.location)
        if initialAttempt.matched {
            return rawRange
        }

        // 2. If `kAXSelectedTextAttribute` returned shifted text, compute exact overlap correction first
        if let actual = initialAttempt.actualText,
           !actual.isEmpty,
           let shift = Self.computeRangeOffsetCorrection(expected: expectedOriginal, actualAtRange: actual) {
            let correctedLoc = rawRange.location + shift
            if correctedLoc >= 0 && !triedLocations.contains(correctedLoc) {
                let attempt = tryLocation(correctedLoc)
                if attempt.matched {
                    return NSRange(location: correctedLoc, length: rawRange.length)
                }
            }
        }

        // 3. Try estimated list marker drifts (handles bullets, numbered lists, and CRLF, including words at EOF)
        let listDrifts = Self.estimateListMarkerDrifts(in: fullText, upTo: rawRange.location)
        for drift in listDrifts {
            let candidateLoc = rawRange.location + drift
            if candidateLoc >= 0 && !triedLocations.contains(candidateLoc) {
                let attempt = tryLocation(candidateLoc)
                if attempt.matched {
                    return NSRange(location: candidateLoc, length: rawRange.length)
                }
                // If this drift got us close enough to overlap with `expectedOriginal`, refine from here
                if let actual = attempt.actualText,
                   !actual.isEmpty,
                   let refineShift = Self.computeRangeOffsetCorrection(expected: expectedOriginal, actualAtRange: actual) {
                    let refinedLoc = candidateLoc + refineShift
                    if refinedLoc >= 0 && !triedLocations.contains(refinedLoc) {
                        let refinedAttempt = tryLocation(refinedLoc)
                        if refinedAttempt.matched {
                            return NSRange(location: refinedLoc, length: rawRange.length)
                        }
                    }
                }
            }
        }

        // 4. Bounded spiral search around rawRange.location (and primary list drift if present)
        let baseLocations = [rawRange.location] + listDrifts.prefix(3).map { rawRange.location + $0 }
        for baseLoc in baseLocations {
            for radius in 1...20 {
                for sign in [-1, 1] {
                    let candidateLoc = baseLoc + (radius * sign)
                    if candidateLoc >= 0 && !triedLocations.contains(candidateLoc) {
                        let attempt = tryLocation(candidateLoc)
                        if attempt.matched {
                            return NSRange(location: candidateLoc, length: rawRange.length)
                        }
                    }
                }
            }
        }

        // 5. Fallback if the control does not implement `kAXSelectedTextAttribute` at all (returns nil/empty everywhere)
        if initialAttempt.actualText == nil || initialAttempt.actualText == "" {
            let fallbackLoc: Int
            if isChromium, let primaryListDrift = listDrifts.first, rawRange.location + primaryListDrift >= 0 {
                fallbackLoc = rawRange.location + primaryListDrift
            } else {
                fallbackLoc = rawRange.location
            }
            let fallbackRange = NSRange(location: fallbackLoc, length: rawRange.length)
            _ = setRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute, range: fallbackRange)
            return fallbackRange
        }

        // Never overwrite unverified mismatched text if `kAXSelectedTextAttribute` reported different non-empty text
        return nil
    }

    private func readSettledSelectedText(
        from element: AXUIElement,
        expectedRange: NSRange,
        isChromium: Bool
    ) -> String? {
        let immediateText = copyStringAttribute(element, attribute: kAXSelectedTextAttribute)
        let immediateRange = copyRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute)

        // When using synchronous test accessor or native controls, return immediately
        if elementAccessor != nil || !isChromium {
            return immediateText
        }

        if let text = immediateText,
           (text as NSString).length == expectedRange.length,
           immediateRange == expectedRange {
            return text
        }

        // In Chromium/Electron, setting kAXSelectedTextRangeAttribute dispatches an async IPC to the renderer.
        // Poll briefly (up to 4 x 4ms = 16ms) for kAXSelectedTextAttribute to reflect the updated selection.
        var latestText = immediateText
        for _ in 0..<4 {
            usleep(4_000)
            latestText = copyStringAttribute(element, attribute: kAXSelectedTextAttribute)
            let currentRange = copyRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute)
            if let text = latestText,
               (text as NSString).length == expectedRange.length,
               currentRange == expectedRange {
                return text
            }
        }
        return latestText
    }

    @discardableResult
    public func applyIssueReplacement(_ issue: WritingIssue, in currentText: String) -> Bool {
        if let handler = testReplacementHandler, elementAccessor == nil {
            let nsText = currentText as NSString
            let targetRange = Self.findBestOccurrenceRange(
                of: issue.original,
                preferredUTF16Location: issue.utf16Location,
                in: currentText
            )
            if targetRange.location != NSNotFound {
                let updated = nsText.replacingCharacters(in: targetRange, with: issue.replacement)
                return handler(issue, updated)
            }
            return handler(issue, currentText)
        }

        guard let element = lastFocusedElement else { return false }
        let targetApp = resolveTargetApplication(from: element)

        // Ensure host application is active before manipulating selection
        if elementAccessor == nil, let app = targetApp, !app.isActive {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }

        // Compute current range of `issue.original` in the live element text
        let liveText = copyStringAttribute(element, attribute: kAXValueAttribute) ?? currentText
        let nsLive = liveText as NSString
        let targetRange = Self.findBestOccurrenceRange(
            of: issue.original,
            preferredUTF16Location: issue.utf16Location,
            in: liveText
        )

        guard targetRange.location != NSNotFound else { return false }

        if elementAccessor == nil {
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        let isChromium = isChromiumOrElectronApp(targetApp, element: element)

        // Select and calibrate the target text range so bullet/numbered list marker offsets never shift the selection
        guard let calibratedRange = calibrateAndSelectRange(
            for: issue.original,
            rawRange: targetRange,
            in: liveText,
            element: element,
            isChromium: isChromium
        ) else {
            return false
        }

        let hasListMarkers = !Self.estimateListMarkerDrifts(in: liveText, upTo: nsLive.length).isEmpty

        // For native macOS applications (TextEdit, Notes, Mail), try direct AXSelectedTextAttribute first
        if !isChromium {
            let setTextErr = setStringAttribute(
                element,
                attribute: kAXSelectedTextAttribute,
                value: issue.replacement
            )
            if setTextErr == .success {
                let liveSelected = copyStringAttribute(element, attribute: kAXSelectedTextAttribute)
                let liveVal = copyStringAttribute(element, attribute: kAXValueAttribute)
                if liveSelected == issue.replacement || (liveVal != nil && liveVal != liveText) {
                    if let handler = testReplacementHandler, let liveVal = liveVal {
                        _ = handler(issue, liveVal)
                    }
                    if elementAccessor == nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.pollCurrentFocusedElement()
                        }
                    }
                    return true
                }
            }

            // Tier 2: Try kAXValueAttribute ONLY when there is no rich-text list offset drift or list markers
            if calibratedRange == targetRange && !hasListMarkers {
                let updatedFullText = nsLive.replacingCharacters(in: targetRange, with: issue.replacement)
                let setValErr = setStringAttribute(
                    element,
                    attribute: kAXValueAttribute,
                    value: updatedFullText
                )
                if setValErr == .success {
                    let liveVal = copyStringAttribute(element, attribute: kAXValueAttribute)
                    if liveVal == updatedFullText || (liveVal != nil && !liveVal!.contains(issue.original)) {
                        if let handler = testReplacementHandler, let liveVal = liveVal {
                            _ = handler(issue, liveVal)
                        }
                        if elementAccessor == nil {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                self.pollCurrentFocusedElement()
                            }
                        }
                        return true
                    }
                }
            }
        }

        // Tier 3: Calibrated selection is set via AXSelectedTextRangeAttribute.
        // Dispatch transient clipboard Cmd+V paste to replace the selection while preserving rich-text bullet formatting.
        pasteViaTransientClipboard(
            issue.replacement,
            targetApp: targetApp,
            element: element,
            calibratedRange: calibratedRange,
            expectedOriginal: issue.original,
            issueForTestHandler: issue
        )
        return true
    }

    @discardableResult
    public func replaceSelectedOrFullText(with newText: String) -> Bool {
        if let handler = testReplacementHandler, elementAccessor == nil {
            return handler(nil, newText)
        }

        guard let element = lastFocusedElement else { return false }
        let targetApp = resolveTargetApplication(from: element)

        if elementAccessor == nil {
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        let isChromium = isChromiumOrElectronApp(targetApp, element: element)

        if !isChromium {
            // If user has a selection, replace selection first
            if let selRange = copyRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute),
               selRange.length > 0 {
                let err = setStringAttribute(
                    element,
                    attribute: kAXSelectedTextAttribute,
                    value: newText
                )
                if err == .success {
                    let liveSelected = copyStringAttribute(element, attribute: kAXSelectedTextAttribute)
                    if liveSelected == newText {
                        if let handler = testReplacementHandler,
                           let liveVal = copyStringAttribute(element, attribute: kAXValueAttribute) {
                            _ = handler(nil, liveVal)
                        }
                        if elementAccessor == nil {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                self.pollCurrentFocusedElement()
                            }
                        }
                        return true
                    }
                }
            }

            // Otherwise replace full value attribute
            let valErr = setStringAttribute(
                element,
                attribute: kAXValueAttribute,
                value: newText
            )
            if valErr == .success {
                let liveVal = copyStringAttribute(element, attribute: kAXValueAttribute)
                if liveVal == newText {
                    if let handler = testReplacementHandler {
                        _ = handler(nil, newText)
                    }
                    if elementAccessor == nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.pollCurrentFocusedElement()
                        }
                    }
                    return true
                }
            }
        } else {
            // In Chromium/Electron, ensure text is selected before pasting
            let selRange = copyRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute)
            if selRange == nil || selRange?.length == 0 {
                if let liveText = copyStringAttribute(element, attribute: kAXValueAttribute) {
                    let fullRange = NSRange(location: 0, length: (liveText as NSString).length)
                    _ = setRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute, range: fullRange)
                }
            }
        }

        // Fallback to transient clipboard paste
        pasteViaTransientClipboard(newText, targetApp: targetApp, element: element)
        return true
    }

    private func resolveTargetApplication(from element: AXUIElement) -> NSRunningApplication? {
        var targetPID: pid_t = 0
        AXUIElementGetPid(element, &targetPID)
        var targetApp = targetPID > 0 ? NSRunningApplication(processIdentifier: targetPID) : nil

        if targetApp == nil || targetApp?.activationPolicy != .regular {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                targetApp = front
            }
        }

        // If targetApp is an accessory or helper process, map to main regular app
        if let app = targetApp, app.activationPolicy != .regular {
            if let bid = app.bundleIdentifier?.lowercased() {
                if bid.contains("chrome") {
                    if let mainApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
                        targetApp = mainApp
                    }
                } else if bid.contains("antigravity") {
                    if let mainApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.google.antigravity" }) {
                        targetApp = mainApp
                    }
                }
            }
        }

        return targetApp
    }

    private func isChromiumOrElectronApp(_ targetApp: NSRunningApplication?, element: AXUIElement) -> Bool {
        if let accessorResult = elementAccessor?.isChromiumOrElectron(element) {
            return accessorResult
        }

        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        let bid = (app?.bundleIdentifier ?? "").lowercased()
        let name = (app?.localizedName ?? "").lowercased()

        if bid.contains("chrome") || bid.contains("antigravity") || bid.contains("electron") ||
           bid.contains("slack") || bid.contains("vscode") || bid.contains("code") ||
           bid.contains("brave") || bid.contains("edge") || bid.contains("discord") ||
           bid.contains("notion") || bid.contains("cursor") ||
           name.contains("chrome") || name.contains("antigravity") {
            return true
        }

        let role = copyStringAttribute(element, attribute: kAXRoleAttribute) ?? ""
        let subrole = copyStringAttribute(element, attribute: kAXSubroleAttribute) ?? ""
        if role.contains("Web") || subrole.contains("Web") {
            return true
        }

        return false
    }

    private func pasteViaTransientClipboard(
        _ text: String,
        targetApp: NSRunningApplication?,
        element: AXUIElement? = nil,
        calibratedRange: NSRange? = nil,
        expectedOriginal: String? = nil,
        issueForTestHandler: WritingIssue? = nil
    ) {
        if let accessor = elementAccessor, accessor.performPaste(text) {
            if let handler = testReplacementHandler,
               let el = element ?? lastFocusedElement,
               let updated = copyStringAttribute(el, attribute: kAXValueAttribute) {
                _ = handler(issueForTestHandler, updated)
            }
            return
        }

        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Ensure host application has active window focus
        if let app = targetApp, !app.isActive {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }

        // Delay 50ms to allow target window and selection to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Re-verify selection right before dispatching Cmd+V in case window/panel transition disturbed it
            if let el = element, let range = calibratedRange {
                if let expected = expectedOriginal {
                    let currentSelected = self.copyStringAttribute(el, attribute: kAXSelectedTextAttribute)
                    if currentSelected != expected {
                        _ = self.setRangeAttribute(el, attribute: kAXSelectedTextRangeAttribute, range: range)
                        usleep(12_000)
                    }
                } else if self.copyRangeAttribute(el, attribute: kAXSelectedTextRangeAttribute) != range {
                    _ = self.setRangeAttribute(el, attribute: kAXSelectedTextRangeAttribute, range: range)
                    usleep(12_000)
                }
            }

            let source = CGEventSource(stateID: .combinedSessionState)
            source?.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitSystemDefinedEvents],
                state: .eventSuppressionStateSuppressionInterval
            )

            let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V
            // Command flag with left-command device flag 0x000008 (NX_DEVICELCMDKEYMASK)
            let cmdFlags: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x000008)]

            guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
                  let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
                return
            }

            vDown.flags = cmdFlags
            vUp.flags = cmdFlags

            vDown.post(tap: .cgSessionEventTap)
            vUp.post(tap: .cgSessionEventTap)

            // Safe clipboard restoration after 1.2 seconds:
            // Only restore if clipboard still contains the replacement text (user hasn't copied something else)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let prev = previousString, pasteboard.string(forType: .string) == text {
                    pasteboard.clearContents()
                    pasteboard.setString(prev, forType: .string)
                }
                self.pollCurrentFocusedElement()
            }
        }
    }

    // MARK: - Attribute & Coordinate Helpers

    private func isSecureTextField(_ element: AXUIElement) -> Bool {
        if let subrole = copyStringAttribute(element, attribute: kAXSubroleAttribute),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        return false
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        let role = copyStringAttribute(element, attribute: kAXRoleAttribute) ?? ""
        let editableRoles: Set<String> = [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
            "AXWebArea",
            "AXGroup"
        ]

        var isValueSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isValueSettable)

        var isSelectedTextSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSelectedTextSettable)

        if isValueSettable.boolValue || isSelectedTextSettable.boolValue {
            return true
        }

        if editableRoles.contains(role), copyStringAttribute(element, attribute: kAXValueAttribute) != nil {
            return true
        }

        return false
    }

    private func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        if let accessor = elementAccessor {
            return accessor.copyString(element, attribute: attribute)
        }
        var valueRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard err == .success, let val = valueRef else { return nil }
        if let str = val as? String {
            return str
        }
        if let attrStr = val as? NSAttributedString {
            return attrStr.string
        }
        return nil
    }

    private func copyRangeAttribute(_ element: AXUIElement, attribute: String) -> NSRange? {
        if let accessor = elementAccessor {
            return accessor.copyRange(element, attribute: attribute)
        }
        var valueRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard err == .success, let axVal = valueRef else { return nil }
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axVal as! AXValue, .cfRange, &cfRange), cfRange.location != kCFNotFound else {
            return nil
        }
        return NSRange(location: cfRange.location, length: cfRange.length)
    }

    @discardableResult
    private func setRangeAttribute(_ element: AXUIElement, attribute: String, range: NSRange) -> AXError {
        if let accessor = elementAccessor {
            return accessor.setRange(element, attribute: attribute, range: range)
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, attribute as CFString, rangeValue)
    }

    @discardableResult
    private func setStringAttribute(_ element: AXUIElement, attribute: String, value: String) -> AXError {
        if let accessor = elementAccessor {
            return accessor.setString(element, attribute: attribute, value: value)
        }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef)
    }

    /// Resolves the caret bounds or top-left corner of the focused text field in AppKit screen coordinates.
    private func resolveAnchorAppKitPoint(for element: AXUIElement, selectedRange: NSRange?) -> CGPoint {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080

        // 1. Try caret / selection parameterized bounds first (`kAXBoundsForRangeParameterizedAttribute`)
        if let sel = selectedRange {
            var cfRange = CFRange(location: sel.location, length: max(0, sel.length))
            if let rangeVal = AXValueCreate(.cfRange, &cfRange) {
                var boundsRef: CFTypeRef?
                let err = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    rangeVal,
                    &boundsRef
                )
                if err == .success, let bVal = boundsRef {
                    var rect = CGRect.zero
                    if AXValueGetValue(bVal as! AXValue, .cgRect, &rect),
                       rect.origin.x > 0 || rect.origin.y > 0,
                       rect.size.height > 2 {
                        let appKitTopY = primaryScreenHeight - rect.minY
                        // Dock right beside the caret
                        let appKitLeftX = rect.maxX + 12
                        return CGPoint(x: max(20, appKitLeftX), y: max(40, appKitTopY))
                    }
                }
            }
        }

        // 2. Fallback to Element Frame (positioned cleanly inside the editor, not spilling into adjacent sidebars)
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let pVal = posRef, let sVal = sizeRef {
            var point = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(pVal as! AXValue, .cgPoint, &point),
               AXValueGetValue(sVal as! AXValue, .cgSize, &size),
               size.width > 20, size.height > 12 {
                let appKitTopY = primaryScreenHeight - point.y
                let appKitLeftX = point.x + 20
                return CGPoint(x: max(20, appKitLeftX), y: max(40, appKitTopY - 12))
            }
        }

        // 3. Fallback near mouse cursor or top-left of main screen
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: max(40, mouse.x - 24), y: max(40, mouse.y + 24))
    }
}
