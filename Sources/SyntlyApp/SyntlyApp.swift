import SwiftUI
import AppKit
import SyntlyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = WritingAssistantCoordinator.shared
    var floatingPanelController: FloatingPanelController?
    var statusBarController: StatusBarController?
    var writingPadWindow: NSWindow?
    var settingsWindow: NSWindow?
    private var latencyActivityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS App Nap and CPU throttling so menu bar popovers and hotkeys open instantly at 0ms
        latencyActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Real-time writing assistant and instant status bar response"
        )

        let initialPolicy: NSApplication.ActivationPolicy = AppSettings.shared.showDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(initialPolicy)

        AppSettings.shared.onDockIconVisibilityRestored = { [weak self] in
            self?.refreshDockIcon()
        }
        refreshDockIcon()

        let isSandboxOnly = CommandLine.arguments.contains("--sandbox") || CommandLine.arguments.contains("--sandbox-only")

        if !isSandboxOnly {
            floatingPanelController = FloatingPanelController(coordinator: coordinator)
            coordinator.start()
        } else {
            print("🛡️ Syntly running in SAFE SANDBOX MODE:")
            print("   • macOS Accessibility monitoring is COMPLETELY DISABLED.")
            print("   • Global hotkey listeners are COMPLETELY DISABLED.")
            print("   • Zero access to external apps or keystrokes.")
            print("   • Use the Writing Pad window to test corrections safely.")
        }

        statusBarController = StatusBarController(
            coordinator: coordinator,
            settings: .shared,
            onOpenWritingPad: { [weak self] in
                self?.openWritingPadWindow()
            },
            onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            }
        )

        // Never show Writing Pad on app launch. Synt(ax)ly runs quietly in the menu bar.
        if CommandLine.arguments.contains("--open-writing-pad") {
            openWritingPadWindow()
        }

        if CommandLine.arguments.contains("--demo-pill") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.coordinator.simulateDemoPillOnScreen()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking dock icon always opens/focuses Writing Pad
        openWritingPadWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    func openWritingPadWindow() {
        if let win = writingPadWindow {
            if win.isMiniaturized {
                win.deminiaturize(nil)
            }
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = WritingPadView(
            coordinator: coordinator,
            settings: .shared,
            onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            }
        )
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 936),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 800, height: 680)
        window.title = "Synt(ax)ly — Writing Pad"
        window.contentViewController = hostingController
        window.setFrameAutosaveName("SyntlyWritingPadMainWindow")
        if window.frame.height < 850 {
            window.setContentSize(NSSize(width: max(window.frame.width, 1060), height: 936))
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.writingPadWindow = window
    }

    func openSettingsWindow() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsView(
            coordinator: coordinator,
            settings: .shared,
            onOpenWritingPad: { [weak self] in
                self?.openWritingPadWindow()
            }
        )
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 530),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Synt(ax)ly — Settings & Configuration"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    func refreshDockIcon() {
        guard let image = loadAppIconImage() else { return }

        // Set applicationIconImage for system app switchers (Cmd+Tab)
        NSApp.applicationIconImage = image

        // Explicitly assign custom transparent dockTile contentView so macOS never wraps it in a white squircle
        let tileView = TransparentDockTileView(image: image)
        NSApp.dockTile.contentView = tileView
        NSApp.dockTile.display()

        // Re-flush after WindowServer finishes registering the dynamic tile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.dockTile.display()
        }
    }

    private func loadAppIconImage() -> NSImage? {
        if let iconURL = Bundle.main.url(forResource: "app_icon_1024", withExtension: "png") ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            return image
        }

        let devIconPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/app_icon_1024.png")
        if let image = NSImage(contentsOfFile: devIconPath.path) {
            return image
        }
        return nil
    }
}

// MARK: - Dedicated Transparent Dock Tile View (Zero White Squircle)

final class TransparentDockTileView: NSView {
    private let iconImage: NSImage

    init(image: NSImage) {
        self.iconImage = image
        let size = NSApp.dockTile.size
        let validSize = (size.width > 0 && size.height > 0) ? size : NSSize(width: 128, height: 128)
        super.init(frame: NSRect(origin: .zero, size: validSize))
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        iconImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}

@main
struct SyntlyMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(coordinator: appDelegate.coordinator, settings: .shared)
        }
    }
}
