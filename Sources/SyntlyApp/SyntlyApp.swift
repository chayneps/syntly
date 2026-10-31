import SwiftUI
import AppKit
import SyntlyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = WritingAssistantCoordinator.shared
    var floatingPanelController: FloatingPanelController?
    var statusBarController: StatusBarController?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let isSandboxOnly = CommandLine.arguments.contains("--sandbox") || CommandLine.arguments.contains("--sandbox-only")

        if !isSandboxOnly {
            floatingPanelController = FloatingPanelController(coordinator: coordinator)
            coordinator.start()
        } else {
            print("🛡️ Syntly running in SAFE SANDBOX MODE:")
            print("   • macOS Accessibility monitoring is COMPLETELY DISABLED.")
            print("   • Global hotkey listeners are COMPLETELY DISABLED.")
            print("   • Zero access to external apps or keystrokes.")
            print("   • Use the Live Playground window to test corrections safely.")
        }

        // Initialize dedicated AppKit NSStatusItem so ✨ Syntly ALWAYS appears in the menu bar
        statusBarController = StatusBarController(
            coordinator: coordinator,
            settings: .shared,
            onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            }
        )

        // Show the Playground & Settings window on launch so the user can test immediately
        openSettingsWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    func openSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsView(coordinator: coordinator, settings: .shared)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Syntly — Real-Time Gemini Writing Assistant"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
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
