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
        button.imagePosition = .imageLeading
        button.title = " Syntly"
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
            .sink { [weak self] trusted in
                guard let self = self, let button = self.statusItem?.button else { return }
                if !trusted {
                    button.title = " Syntly ⚠️"
                } else {
                    self.updateStatusButton(state: self.coordinator.pillState)
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton(state: PillVisualState) {
        guard let button = statusItem?.button else { return }

        if !coordinator.isAccessibilityTrusted {
            button.title = " Syntly ⚠️"
            return
        }

        switch state {
        case .issuesFound(let count, _):
            button.title = " Syntly (\(count))"
        case .checking:
            button.title = " Syntly…"
        case .error:
            button.title = " Syntly (!)"
        case .paused:
            button.title = " Syntly (Paused)"
        case .allClear:
            button.title = " Syntly"
        }
    }

    public func closePopover() {
        popover?.performClose(nil)
    }
}
