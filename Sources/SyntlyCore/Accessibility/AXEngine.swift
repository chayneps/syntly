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

    public var activeParagraph: String {
        guard !fullText.isEmpty else { return "" }
        let nsText = fullText as NSString
        if let sel = selectedRange, sel.location <= nsText.length {
            let safeRange = NSRange(location: min(sel.location, max(0, nsText.length - 1)), length: 0)
            let paraRange = nsText.paragraphRange(for: safeRange)
            return nsText.substring(with: paraRange)
        }
        return fullText
    }
}

public protocol AXEngineDelegate: AnyObject {
    func axEngineDidUpdateContext(_ context: FocusedTextContext?)
    func axEngineDidChangeTrustStatus(_ isTrusted: Bool)
}

public final class AXEngine {
    public static let shared = AXEngine()

    public weak var delegate: AXEngineDelegate?
    public private(set) var isTrusted: Bool = AXIsProcessTrusted()
    /// Optional hook used by End-to-End tests to intercept and verify in-place text replacements without mutating external windows.
    public var testReplacementHandler: ((_ issue: WritingIssue?, _ resultingText: String) -> Bool)?

    private var currentObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var lastFocusedElement: AXUIElement?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var trustPollTimer: Timer?
    private var enabledElectronPIDs = Set<pid_t>()

    public init() {}

    // MARK: - Lifecycle & Permissions

    public func start() {
        checkTrust(prompt: true)
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

        // Ignore Syntly's own floating windows unless testing in Settings Playground
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

    // MARK: - Replacing Text (3-Tier Fallback Cascade)

    @discardableResult
    public func applyIssueReplacement(_ issue: WritingIssue, in currentText: String) -> Bool {
        if let handler = testReplacementHandler {
            let nsText = currentText as NSString
            if let loc = issue.utf16Location, let len = issue.utf16Length,
               loc + len <= nsText.length,
               nsText.substring(with: NSRange(location: loc, length: len)) == issue.original {
                let updated = nsText.replacingCharacters(in: NSRange(location: loc, length: len), with: issue.replacement)
                return handler(issue, updated)
            } else {
                let range = nsText.range(of: issue.original)
                if range.location != NSNotFound {
                    let updated = nsText.replacingCharacters(in: range, with: issue.replacement)
                    return handler(issue, updated)
                }
            }
            return handler(issue, currentText)
        }

        guard let element = lastFocusedElement else { return false }

        // Compute current range of `issue.original` in the live element text
        let liveText = copyStringAttribute(element, attribute: kAXValueAttribute) ?? currentText
        let nsLive = liveText as NSString
        var targetRange: NSRange = NSRange(location: NSNotFound, length: 0)

        if let loc = issue.utf16Location, let len = issue.utf16Length,
           loc + len <= nsLive.length,
           nsLive.substring(with: NSRange(location: loc, length: len)) == issue.original {
            targetRange = NSRange(location: loc, length: len)
        } else {
            targetRange = nsLive.range(of: issue.original)
        }

        // Tier 1: Direct AX Selected Range + Selected Text Replacement
        if targetRange.location != NSNotFound {
            var cfRange = CFRange(location: targetRange.location, length: targetRange.length)
            if let rangeValue = AXValueCreate(.cfRange, &cfRange) {
                let setRangeErr = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextRangeAttribute as CFString,
                    rangeValue
                )
                if setRangeErr == .success {
                    let setTextErr = AXUIElementSetAttributeValue(
                        element,
                        kAXSelectedTextAttribute as CFString,
                        issue.replacement as CFTypeRef
                    )
                    if setTextErr == .success {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.pollCurrentFocusedElement()
                        }
                        return true
                    }
                }
            }

            // Tier 2: Full kAXValueAttribute Replacement
            let updatedFullText = nsLive.replacingCharacters(in: targetRange, with: issue.replacement)
            let setValErr = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                updatedFullText as CFTypeRef
            )
            if setValErr == .success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.pollCurrentFocusedElement()
                }
                return true
            }

            // Tier 3: Select range via AX + Transient Clipboard Cmd+V Paste Fallback
            var cfRangePaste = CFRange(location: targetRange.location, length: targetRange.length)
            if let rangeValue = AXValueCreate(.cfRange, &cfRangePaste) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
                pasteViaTransientClipboard(issue.replacement)
                return true
            }
        }

        return false
    }

    @discardableResult
    public func replaceSelectedOrFullText(with newText: String) -> Bool {
        if let handler = testReplacementHandler {
            return handler(nil, newText)
        }

        guard let element = lastFocusedElement else { return false }

        // If user has a selection, replace selection first
        if let selRange = copyRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute),
           selRange.length > 0 {
            let err = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                newText as CFTypeRef
            )
            if err == .success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.pollCurrentFocusedElement()
                }
                return true
            }
        }

        // Otherwise replace full value attribute
        let valErr = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )
        if valErr == .success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.pollCurrentFocusedElement()
            }
            return true
        }

        // Fallback to transient clipboard paste
        pasteViaTransientClipboard(newText)
        return true
    }

    private func pasteViaTransientClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        // Post synthetic Cmd + V (keyCode 0x09 = 'v')
        let source = CGEventSource(stateID: .combinedSessionState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        // Restore previous clipboard after 150ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let prev = previousString {
                pasteboard.clearContents()
                pasteboard.setString(prev, forType: .string)
            }
            self.pollCurrentFocusedElement()
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
        var valueRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard err == .success, let val = valueRef as? String else { return nil }
        return val
    }

    private func copyRangeAttribute(_ element: AXUIElement, attribute: String) -> NSRange? {
        var valueRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard err == .success, let axVal = valueRef else { return nil }
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axVal as! AXValue, .cfRange, &cfRange), cfRange.location != kCFNotFound else {
            return nil
        }
        return NSRange(location: cfRange.location, length: cfRange.length)
    }

    /// Resolves the bottom-right corner of the focused text field (or caret bounds) in AppKit screen coordinates.
    private func resolveAnchorAppKitPoint(for element: AXUIElement, selectedRange: NSRange?) -> CGPoint {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080

        // 1. Try element frame (bottom-right corner of the focused text box)
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
                // Clamp extraordinarily tall webviews/editors to visible window or caret bounds
                if size.height <= 500 {
                    let quartzBottomRightX = point.x + size.width - 16
                    let quartzBottomRightY = point.y + size.height - 12
                    let appKitY = primaryScreenHeight - quartzBottomRightY
                    return CGPoint(x: max(40, quartzBottomRightX), y: max(40, appKitY))
                }
            }
        }

        // 2. Try caret / selection parameterized bounds (`kAXBoundsForRangeParameterizedAttribute`)
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
                       rect.origin.x > 0 || rect.origin.y > 0 {
                        let quartzX = rect.maxX + 12
                        let quartzY = rect.maxY + 8
                        let appKitY = primaryScreenHeight - quartzY
                        return CGPoint(x: max(40, quartzX), y: max(40, appKitY))
                    }
                }
            }
        }

        // 3. Fallback near mouse cursor or bottom-right of main screen
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: max(60, mouse.x + 24), y: max(60, mouse.y - 24))
    }
}
