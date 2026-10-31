import SwiftUI
import AppKit

public struct MenuBarView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator
    @ObservedObject var settings: AppSettings
    public var onOpenSettings: () -> Void

    public init(
        coordinator: WritingAssistantCoordinator,
        settings: AppSettings = .shared,
        onOpenSettings: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkles")
                Text("Syntly Writing Assistant")
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
                }
            }

            Divider()

            Toggle("Correct While I Type", isOn: $settings.enableAsYouType)
            Toggle("Instant Local Spellcheck", isOn: $settings.enableLocalSpellcheck)

            if settings.isCurrentlyPaused() {
                Button("Resume Syntly Now") {
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

            Text("Session: \(coordinator.totalChecksCount) checks • \(coordinator.totalFixesApplied) fixes applied")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Open Playground & Settings…") {
                onOpenSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Syntly") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(4)
    }

    private var authStatusSummary: String {
        if settings.authMode == .cliProxy {
            return settings.isCLIProxyReachable
                ? "Auth: CLIProxyAPI (\(settings.cliProxyBaseURL))"
                : "Auth: CLIProxyAPI (waiting on \(settings.cliProxyBaseURL))"
        } else if settings.hasStoredAPIKey {
            return "Auth: Google AI Studio Key (\(settings.liveModel))"
        } else if settings.detectedGeminiCLIPath != nil && settings.isGeminiCLISignedIn {
            return "Auth: Gemini CLI Subscription (\(settings.liveModel))"
        } else if settings.detectedGeminiCLIPath != nil {
            return "Auth: Gemini CLI found (run `gemini` to sign in)"
        } else {
            return "Auth: Setup required in Settings"
        }
    }
}
