import AppKit
import SwiftUI
import Combine

@MainActor
public final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let coordinator: WritingAssistantCoordinator
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private let onOpenSettings: () -> Void

    public init(
        coordinator: WritingAssistantCoordinator,
        settings: AppSettings,
        onOpenSettings: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        super.init()

        setupStatusItem()
        setupPopover()
        observeState()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Syntly")?.withSymbolConfiguration(config)
        icon?.isTemplate = true
        button.image = icon
        button.title = "" // Compact 22px width so it fits next to the MacBook camera notch
        button.toolTip = "Syntly Writing Assistant"
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 300, height: 280)

        let menuView = MenuBarView(
            coordinator: coordinator,
            settings: settings,
            onOpenSettings: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenSettings()
            }
        )
        let hostingController = NSHostingController(rootView: menuView.padding(14))
        pop.contentViewController = hostingController
        self.popover = pop
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func observeState() {
        coordinator.$pillState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusButton(state: state)
            }
            .store(in: &cancellables)

        coordinator.$isAccessibilityTrusted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateStatusButton(state: self.coordinator.pillState)
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton(state: PillVisualState) {
        guard let button = statusItem?.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

        if !coordinator.isAccessibilityTrusted {
            let warnIcon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Syntly Permission Needed")?.withSymbolConfiguration(config)
            button.image = warnIcon
            button.toolTip = "Syntly: Accessibility Permission Needed (Click to Grant)"
            return
        }

        switch state {
        case .issuesFound(let count, _):
            let starIcon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Syntly Issues")?.withSymbolConfiguration(config)
            button.image = starIcon
            button.toolTip = "Syntly: \(count) issue\(count == 1 ? "" : "s") found"
        case .checking:
            let checkIcon = NSImage(systemSymbolName: "ellipsis.bubble", accessibilityDescription: "Checking")?.withSymbolConfiguration(config)
            button.image = checkIcon
            button.toolTip = "Syntly: Checking writing…"
        case .error:
            let errIcon = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: "Error")?.withSymbolConfiguration(config)
            button.image = errIcon
            button.toolTip = "Syntly: Error"
        case .paused:
            let pauseIcon = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")?.withSymbolConfiguration(config)
            button.image = pauseIcon
            button.toolTip = "Syntly: Paused"
        case .allClear:
            let normalIcon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Syntly All Clear")?.withSymbolConfiguration(config)
            button.image = normalIcon
            button.toolTip = "Syntly: All Clear"
        }
    }

    public func closePopover() {
        popover?.performClose(nil)
    }
}
