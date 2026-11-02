import SwiftUI
import AppKit

public struct MenuBarView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator
    @ObservedObject var settings: AppSettings
    public var onOpenWritingPad: () -> Void
    public var onOpenSettings: () -> Void
    public var onOpenAbout: (() -> Void)?

    public init(
        coordinator: WritingAssistantCoordinator,
        settings: AppSettings = .shared,
        onOpenWritingPad: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenAbout: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.onOpenWritingPad = onOpenWritingPad
        self.onOpenSettings = onOpenSettings
        self.onOpenAbout = onOpenAbout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Synt(ax)ly Writing Assistant")
                    .font(.headline)
            }

            Divider()

            // Auth & Permission Status
            Text(authStatusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !coordinator.isAccessibilityTrusted {
                Button("⚠️ Grant Accessibility Access…") {
                    coordinator.requestAccessibilityPermission()
                    coordinator.openSystemSettings()
                }
            }

            Divider()

            Toggle("Correct While I Type", isOn: $settings.enableAsYouType)
            Toggle("Instant Local Spellcheck", isOn: $settings.enableLocalSpellcheck)

            Divider()

            Toggle("Show Icon in Dock", isOn: $settings.showDockIcon)
            Toggle("Launch at Login", isOn: Binding(
                get: { settings.launchAtLoginState },
                set: { settings.setLaunchAtLogin($0) }
            ))

            if settings.isCurrentlyPaused() {
                Button("Resume Synt(ax)ly Now") {
                    settings.resumeMonitoring()
                }
            } else {
                Button("Pause for 1 Hour") {
                    settings.pauseForOneHour()
                }
            }

            if let ctx = coordinator.currentContext, let bundleID = ctx.bundleID {
                let isBlocked = settings.isAppBlocked(bundleID: bundleID)
                Button(isBlocked ? "Enable in \(ctx.appName)" : "Disable in \(ctx.appName)") {
                    settings.toggleAppBlocked(bundleID: bundleID)
                }
            }

            Divider()

            Button {
                onOpenWritingPad()
            } label: {
                Label("Open Writing Pad", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button {
                onOpenSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button {
                onOpenAbout?()
            } label: {
                Label("About Synt(ax)ly…", systemImage: "info.circle")
            }

            Divider()

            Button("Quit Synt(ax)ly") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(4)
    }

    private var authStatusSummary: String {
        if settings.isAuthReady {
            return "API: Connected (\(settings.apiEndpoint))"
        } else {
            return "API: Setup required in Settings"
        }
    }
}
