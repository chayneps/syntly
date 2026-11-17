import Foundation
import AppKit
import CoreGraphics

public final class GlobalHotkeyMonitor {
    public var onQuickAcceptShortcut: (() -> Void)?
    public var onToggleRewritePanelShortcut: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private let stateLock = NSLock()
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

        guard let tap = CGEvent.tapCreate(
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
                    monitor.stateLock.lock()
                    let tap = monitor.eventTap
                    monitor.stateLock.unlock()
                    if let tap = tap {
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
        ) else {
            // Fallback to NSEvent global monitor if CGEventTap cannot be initialized
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleNSEvent(event)
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        stateLock.lock()
        self.eventTap = tap
        self.runLoopSource = source
        stateLock.unlock()

        // Host the CGEventTap on its own dedicated .userInteractive thread RunLoop so
        // system-wide keystrokes never wait behind Main Thread UI layout or NLP work.
        let thread = Thread { [weak self] in
            guard let self = self, let src = source else { return }
            let rl = CFRunLoopGetCurrent()
            self.stateLock.lock()
            self.tapRunLoop = rl
            self.stateLock.unlock()

            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()

            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        thread.name = "dev.syntly.hotkeyTap"
        thread.qualityOfService = .userInteractive
        stateLock.lock()
        self.tapThread = thread
        stateLock.unlock()
        thread.start()
    }

    public func stop() {
        stateLock.lock()
        let tap = eventTap
        let src = runLoopSource
        let rl = tapRunLoop
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        stateLock.unlock()

        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl = rl {
            if let src = src {
                CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
                    CFRunLoopRemoveSource(rl, src, .commonModes)
                }
            }
            CFRunLoopStop(rl)
            CFRunLoopWakeUp(rl)
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
        let isOption = event.modifierFlags.contains(.option)
        let isCommand = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)
        let isControl = event.modifierFlags.contains(.control)

        // 1. Option + Tab (keyCode 48 = Tab): Quick-Accept top inline suggestion
        if event.keyCode == 48 && isOption && !isCommand && !isControl && !isShift {
            DispatchQueue.main.async {
                self.onQuickAcceptShortcut?()
            }
            return true
        }

        // 2. Cmd + Shift + G (keyCode 5 = 'g'): Open / Toggle Syntly Popover & Rewrite Bar
        if event.keyCode == 5 && isCommand && isShift && !isControl && !isOption {
            DispatchQueue.main.async {
                self.onToggleRewritePanelShortcut?()
            }
            return true
        }

        return false
    }
}
