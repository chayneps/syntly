import Foundation
import AppKit
import Carbon

public final class GlobalHotkeyMonitor {
    public var onQuickAcceptShortcut: (() -> Void)?
    public var onToggleRewritePanelShortcut: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init() {}

    public func start() {
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil
            }
            return event
        }
    }

    public func stop() {
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
        if let local = localMonitor {
            NSEvent.removeMonitor(local)
            localMonitor = nil
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 1. Option + Tab (keyCode 48 = Tab): Quick-Accept top inline suggestion
        if event.keyCode == 48 && flags == [.option] {
            DispatchQueue.main.async {
                self.onQuickAcceptShortcut?()
            }
            return true
        }

        // 2. Cmd + Shift + G (keyCode 5 = 'g'): Open / Toggle Syntly Popover & Rewrite Bar
        if event.keyCode == 5 && flags == [.command, .shift] {
            DispatchQueue.main.async {
                self.onToggleRewritePanelShortcut?()
            }
            return true
        }

        return false
    }
}
