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
    private let onOpenWritingPad: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenAbout: (() -> Void)?

    public init(
        coordinator: WritingAssistantCoordinator,
        settings: AppSettings,
        onOpenWritingPad: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenAbout: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.onOpenWritingPad = onOpenWritingPad
        self.onOpenSettings = onOpenSettings
        self.onOpenAbout = onOpenAbout
        super.init()

        setupStatusItem()
        setupPopover()
        observeState()
    }

    private func setupStatusItem() {
        // Set exact compact 26pt length so menu bar spacing is perfectly tight with adjacent icons (no wide gap)
        statusItem = NSStatusBar.system.statusItem(withLength: 26.0)
        guard let button = statusItem?.button else { return }

        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = makeMangaBubbleIcon()
        button.toolTip = "Synt(ax)ly Writing Assistant"
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    private func setupPopover() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentSize = NSSize(width: 320, height: 360)

        let menuView = MenuBarView(
            coordinator: coordinator,
            settings: settings,
            onOpenWritingPad: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenWritingPad()
            },
            onOpenSettings: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenSettings()
            },
            onOpenAbout: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenAbout?()
            }
        )
        let hostingController = NSHostingController(rootView: menuView.padding(14))
        hostingController.view.wantsLayer = true
        _ = hostingController.view
        pop.contentViewController = hostingController
        self.popover = pop
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async {
                if let window = self.popover?.contentViewController?.view.window {
                    window.makeKey()
                }
            }
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

        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = makeMangaBubbleIcon()

        let tooltip: String
        if !coordinator.isAccessibilityTrusted {
            tooltip = "Synt(ax)ly Writing Assistant (Click to Grant Accessibility)"
        } else {
            switch state {
            case .issuesFound(let count, _):
                tooltip = "Synt(ax)ly: \(count) issue\(count == 1 ? "" : "s") found"
            case .checking:
                tooltip = "Synt(ax)ly: Checking writing…"
            case .error:
                tooltip = "Synt(ax)ly: Connection Issue"
            case .paused:
                tooltip = "Synt(ax)ly: Paused"
            case .allClear:
                tooltip = "Synt(ax)ly: All Clear"
            }
        }
        button.toolTip = tooltip
    }

    private func makeMangaBubbleIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "menu_bar_icon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = false
            return img
        }

        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets/menu_bar_icon.png")
        if let img = NSImage(contentsOf: devPath) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = false
            return img
        }

        return Self.renderMangaBubble(size: 18)
    }

    public static func renderMangaBubble(size ptSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: ptSize, height: ptSize))
        image.lockFocus()
        guard let cg = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // Vibrant hot pink matching app icon: #FE02E3
        let pinkColor = NSColor(calibratedRed: 0.996, green: 0.008, blue: 0.890, alpha: 1.0)
        pinkColor.setFill()

        // Scale proportionally from base 18pt canvas to requested ptSize
        let scale = ptSize / 18.0
        cg.scaleBy(x: scale, y: scale)

        let center = CGPoint(x: 8.5, y: 9.5)
        let mainRadius: CGFloat = 6.2

        let lobeCount = 9
        let lobeRadius: CGFloat = 3.2
        for i in 0..<lobeCount {
            let angle = CGFloat(i) * (2 * .pi / CGFloat(lobeCount))
            let lx = center.x + cos(angle) * (mainRadius - 0.5)
            let ly = center.y + sin(angle) * (mainRadius - 0.5)
            let rect = CGRect(x: lx - lobeRadius, y: ly - lobeRadius, width: lobeRadius * 2, height: lobeRadius * 2)
            cg.fillEllipse(in: rect)
        }
        let centerRect = CGRect(x: center.x - mainRadius, y: center.y - mainRadius, width: mainRadius * 2, height: mainRadius * 2)
        cg.fillEllipse(in: centerRect)

        let trail1 = CGRect(x: 13.5, y: 3.5, width: 2.8, height: 2.8)
        cg.fillEllipse(in: trail1)

        let trail2 = CGRect(x: 15.2, y: 1.6, width: 1.8, height: 1.8)
        cg.fillEllipse(in: trail2)

        let sFont = NSFont.systemFont(ofSize: 9.5, weight: .black)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: sFont,
            .foregroundColor: NSColor.white
        ]
        let sStr = NSAttributedString(string: "S", attributes: attrs)
        let strSize = sStr.size()
        let textRect = CGRect(
            x: center.x - strSize.width / 2.0 - 0.2,
            y: center.y - strSize.height / 2.0 - 0.2,
            width: strSize.width,
            height: strSize.height
        )
        sStr.draw(in: textRect)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    public func closePopover() {
        popover?.performClose(nil)
    }
}
