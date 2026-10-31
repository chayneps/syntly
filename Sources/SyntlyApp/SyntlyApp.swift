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

        statusBarController = StatusBarController(
            coordinator: coordinator,
            settings: .shared,
            onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            }
        )

        // Force open the main window right in the center of the user's screen
        openSettingsWindow()

        if CommandLine.arguments.contains("--demo-pill") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.coordinator.simulateDemoPillOnScreen()
            }
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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
