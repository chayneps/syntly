import Foundation
import AppKit
import CoreGraphics

public final class GlobalHotkeyMonitor {
    public var onQuickAcceptShortcut: (() -> Void)?
    public var onToggleRewritePanelShortcut: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init() {}

    public func start() {
        stop()

        startEventTap()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleNSEvent(event) == true {
                return nil
            }
            return event
        }
    }

    private func startEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let observer = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                }

                if type == .keyDown {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags

                    let isOption = flags.contains(.maskAlternate)
                    let isCommand = flags.contains(.maskCommand)
                    let isShift = flags.contains(.maskShift)
                    let isControl = flags.contains(.maskControl)

                    // 1. Option + Tab (keyCode 48 = Tab): Quick-Accept top inline suggestion
                    if keyCode == 48 && isOption && !isCommand && !isControl && !isShift {
                        DispatchQueue.main.async {
                            monitor.onQuickAcceptShortcut?()
                        }
                        // Swallow event so the target app does not move focus or tab away
                        return nil
                    }

                    // 2. Cmd + Shift + G (keyCode 5 = 'g'): Toggle Popover / Rewrite Bar
                    if keyCode == 5 && isCommand && isShift && !isControl && !isOption {
                        DispatchQueue.main.async {
                            monitor.onToggleRewritePanelShortcut?()
                        }
                        // Swallow event
                        return nil
                    }
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: observer
        )

        if let tap = tap {
            self.eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            // Fallback to NSEvent global monitor if CGEventTap cannot be initialized
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleNSEvent(event)
            }
        }
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                self.runLoopSource = nil
            }
            self.eventTap = nil
        }
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
    private func handleNSEvent(_ event: NSEvent) -> Bool {
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
