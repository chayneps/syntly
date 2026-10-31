import SwiftUI
import AppKit
import SyntlyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = WritingAssistantCoordinator.shared
    var floatingPanelController: FloatingPanelController?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Show the Playground & Settings window on launch so the user can test immediately
        openSettingsWindow()
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
    @StateObject private var coordinator = WritingAssistantCoordinator.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                coordinator: coordinator,
                settings: settings,
                onOpenSettings: {
                    appDelegate.openSettingsWindow()
                }
            )
        } label: {
            HStack(spacing: 4) {
                Image(systemName: menuBarIconName)
                if case .issuesFound(let count, _) = coordinator.pillState, count > 0 {
                    Text("\(count)")
                }
            }
        }
    }

    private var menuBarIconName: String {
        if settings.isCurrentlyPaused() || !settings.enableAsYouType {
            return "text.badge.minus"
        }
        switch coordinator.pillState {
        case .allClear:
            return "text.badge.checkmark"
        case .checking:
            return "ellipsis.bubble"
        case .issuesFound:
            return "text.badge.star"
        case .paused:
            return "text.badge.minus"
        case .error:
            return "exclamationmark.bubble"
        }
    }
}
