import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator
    @ObservedObject var settings: AppSettings

    @State private var playgroundText: String = "Hi team, their going to discuss about the new feature tomorrow due to the fact that we need feedback."
    @State private var playgroundIssues: [WritingIssue] = []
    @State private var isCheckingPlayground: Bool = false
    @State private var playgroundError: String?
    @State private var newDictionaryWord: String = ""
    @State private var newBlockedBundleID: String = ""
    @State private var playgroundDebounceTask: Task<Void, Never>?

    public init(coordinator: WritingAssistantCoordinator, settings: AppSettings = .shared) {
        self.coordinator = coordinator
        self.settings = settings
    }

    public var body: some View {
        TabView {
            playgroundTab
                .tabItem {
                    Label("Live Playground", systemImage: "text.cursor")
                }

            geminiAccountTab
                .tabItem {
                    Label("Gemini Account", systemImage: "person.badge.key.fill")
                }

            writingStyleTab
                .tabItem {
                    Label("Writing & Dictionary", systemImage: "book.closed.fill")
                }

            permissionsAndAppsTab
                .tabItem {
                    Label("Permissions & Apps", systemImage: "hand.raised.fill")
                }
        }
        .padding(16)
        .frame(width: 680, height: 500)
        .onAppear {
            settings.refreshAuthStatus()
            runPlaygroundCheck()
        }
    }

    // MARK: - Tab 1: Live As-You-Type Playground

    private var playgroundTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try Real-Time Corrections While You Type")
                        .font(.headline)
                    Text("Type or edit below—Syntly checks your sentences automatically using your Google Gemini account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCheckingPlayground {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        GeminiService.shared.clearCache()
                        runPlaygroundCheck()
                    } label: {
                        Label("Check Now", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // Gemini Connection Banner
            if !settings.hasStoredAPIKey {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "key.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect Your Google Account ($0 Free)")
                                .font(.subheadline.bold())
                            Text("Google gives every Google Account a free Gemini API key with zero credit card required.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Button {
                                    if let url = URL(string: "https://aistudio.google.com/apikey") {
                                        NSWorkspace.shared.open(url)
                                    }
                                } label: {
                                    Label("1. Get Free Key ↗", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                SecureField("2. Paste your Gemini API key here", text: $settings.apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 200)

                                Button("Connect") {
                                    settings.saveAPIKeyFromInput()
                                    GeminiService.shared.clearCache()
                                    runPlaygroundCheck()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(settings.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(10)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Connected to Google Gemini (\(settings.liveModel))")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Change Key") {
                        settings.clearAPIKey()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            HSplitView {
                // Left: Editable text editor
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $playgroundText)
                        .font(.system(size: 14))
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                        .onChange(of: playgroundText) { _, newValue in
                            schedulePlaygroundCheck(for: newValue)
                        }

                    HStack(spacing: 8) {
                        Text("Quick Rewrite:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(RewritePreset.allCases) { preset in
                            Button(preset.title) {
                                runPlaygroundRewrite(preset)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .frame(minWidth: 320)
                .padding(.trailing, 8)

                // Right: Live categorized suggestions
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Suggestions (\(playgroundIssues.count))")
                            .font(.subheadline.bold())
                        Spacer()
                        if playgroundIssues.count > 1 {
                            Button("Accept All") {
                                for issue in playgroundIssues {
                                    if let range = playgroundText.range(of: issue.original) {
                                        playgroundText.replaceSubrange(range, with: issue.replacement)
                                    }
                                }
                                playgroundIssues.removeAll()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    }

                    if let err = playgroundError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(8)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if playgroundIssues.isEmpty && !isCheckingPlayground {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.green)
                            Text("All clear! No issues detected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(playgroundIssues) { issue in
                                    IssueCardRow(
                                        issue: issue,
                                        onAccept: {
                                            if let range = playgroundText.range(of: issue.original) {
                                                playgroundText.replaceSubrange(range, with: issue.replacement)
                                            }
                                            playgroundIssues.removeAll { $0.id == issue.id }
                                        },
                                        onDismiss: {
                                            playgroundIssues.removeAll { $0.id == issue.id }
                                        },
                                        onAddToDictionary: {
                                            settings.addWordToDictionary(issue.original)
                                            playgroundIssues.removeAll { $0.id == issue.id }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 260)
                .padding(.leading, 8)
            }
        }
    }

    private func schedulePlaygroundCheck(for text: String) {
        let local = GeminiService.shared.runLocalSpellcheck(on: text)
        if !local.isEmpty && playgroundIssues.isEmpty {
            playgroundIssues = local
        }
        playgroundDebounceTask?.cancel()
        playgroundDebounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(settings.debounceMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            runPlaygroundCheck()
        }
    }

    private func runPlaygroundCheck() {
        let text = playgroundText
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else {
            playgroundIssues = []
            return
        }

        let local = GeminiService.shared.runLocalSpellcheck(on: text)
        guard settings.hasStoredAPIKey else {
            playgroundIssues = local
            playgroundError = "Please connect your free Google Gemini API key above to enable AI grammar and rewrite checks."
            isCheckingPlayground = false
            return
        }

        isCheckingPlayground = true
        playgroundError = nil

        Task {
            do {
                let ai = try await GeminiService.shared.proofread(text: text)
                var merged = ai
                for item in local where !merged.contains(where: { $0.original.localizedCaseInsensitiveContains(item.original) }) {
                    merged.append(item)
                }
                await MainActor.run {
                    self.playgroundIssues = merged
                    self.isCheckingPlayground = false
                }
            } catch {
                await MainActor.run {
                    self.playgroundIssues = local
                    self.playgroundError = error.localizedDescription
                    self.isCheckingPlayground = false
                }
            }
        }
    }

    private func runPlaygroundRewrite(_ preset: RewritePreset) {
        let text = playgroundText
        guard settings.hasStoredAPIKey else {
            playgroundError = "Please connect your free Google Gemini API key above to enable AI rewrites."
            isCheckingPlayground = false
            return
        }

        isCheckingPlayground = true
        playgroundError = nil
        Task {
            do {
                let rewritten = try await GeminiService.shared.rewrite(text: text, preset: preset)
                await MainActor.run {
                    self.playgroundText = rewritten
                    self.playgroundIssues = []
                    self.isCheckingPlayground = false
                }
            } catch {
                await MainActor.run {
                    self.playgroundError = error.localizedDescription
                    self.isCheckingPlayground = false
                }
            }
        }
    }

    // MARK: - Tab 2: Google Gemini Account ($0 Setup)

    private var geminiAccountTab: some View {
        Form {
            Section("Authentication Mode ($0 Free & Subscription Options)") {
                Picker("Active Provider:", selection: $settings.authMode) {
                    ForEach(AuthProviderMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Option 1: Local Gemini CLI (Uses Your Google Account / Gemini Pro Subscription)") {
                HStack {
                    if let path = settings.detectedGeminiCLIPath {
                        Image(systemName: settings.isGeminiCLISignedIn ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(settings.isGeminiCLISignedIn ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.isGeminiCLISignedIn
                                 ? "Gemini CLI Connected & Signed In (\(path))"
                                 : "Gemini CLI Found at \(path) — Sign In Required")
                                .font(.subheadline.bold())
                            Text("Includes 1,000 requests/day (Free Google Account), 1,500/day (Google AI Pro), or 2,000/day (Ultra) at $0 extra cost.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gemini CLI not detected in /usr/local/bin or /opt/homebrew/bin")
                                .font(.subheadline.bold())
                            Text("Install with `npm install -g @google/gemini-cli` and run `gemini` to sign in with your Google Account.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Refresh Status") {
                        settings.refreshAuthStatus()
                    }
                }
            }

            Section("Option 2: Google AI Studio API Key (Fast <400ms Direct REST)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SecureField("Paste AI Studio API Key (stored in macOS Keychain)", text: $settings.apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save Key") {
                            settings.saveAPIKeyFromInput()
                        }
                        .buttonStyle(.borderedProminent)
                        if settings.hasStoredAPIKey {
                            Button("Clear") {
                                settings.clearAPIKey()
                            }
                        }
                    }

                    HStack {
                        Image(systemName: settings.hasStoredAPIKey ? "lock.shield.fill" : "info.circle")
                            .foregroundStyle(settings.hasStoredAPIKey ? .green : .secondary)
                        Text(settings.hasStoredAPIKey
                             ? "API Key saved securely in macOS Keychain."
                             : "Get a free API key (no credit card needed) or use your Google AI Pro $10/mo Cloud credit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Get Free Key at Google AI Studio ↗") {
                            if let url = URL(string: "https://aistudio.google.com/apikey") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            Section("Gemini Model Selection") {
                Picker("As-You-Type Model (Fast):", selection: $settings.liveModel) {
                    ForEach(AppSettings.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                Picker("Rewrite & Tone Model:", selection: $settings.rewriteModel) {
                    ForEach(AppSettings.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 3: Writing Style & Personal Dictionary

    private var writingStyleTab: some View {
        Form {
            Section("Language & Typing Responsiveness") {
                Picker("English Variety:", selection: $settings.dialect) {
                    ForEach(EnglishDialect.allCases) { dialect in
                        Text(dialect.rawValue).tag(dialect)
                    }
                }

                HStack {
                    Text("Typing Pause Delay (\(settings.debounceMs) ms):")
                    Slider(
                        value: Binding(
                            get: { Double(settings.debounceMs) },
                            set: { settings.debounceMs = Int($0) }
                        ),
                        in: 300...1500,
                        step: 50
                    )
                }

                TextField("Custom style rule (e.g. 'Prefer active voice and concise sentences')", text: $settings.customStyleInstruction)
            }

            Section("Personal Dictionary (Never Flagged)") {
                HStack {
                    TextField("Add name, acronym, or technical term…", text: $newDictionaryWord)
                        .textFieldStyle(.roundedBorder)
                    Button("Add Word") {
                        settings.addWordToDictionary(newDictionaryWord)
                        newDictionaryWord = ""
                    }
                    .disabled(newDictionaryWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(settings.personalDictionary, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word)
                                    .font(.caption)
                                Button {
                                    settings.removeWordFromDictionary(word)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 4: Accessibility Permissions & Per-App Controls

    private var permissionsAndAppsTab: some View {
        Form {
            Section("macOS Accessibility Permission (Required for System-Wide Typing)") {
                HStack {
                    Image(systemName: coordinator.isAccessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(coordinator.isAccessibilityTrusted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.isAccessibilityTrusted
                             ? "Accessibility Permission Granted"
                             : "Accessibility Permission Needed")
                            .font(.subheadline.bold())
                        Text("Allows Syntly to read focused text fields and apply your accepted corrections across apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !coordinator.isAccessibilityTrusted {
                        Button("Prompt Permission") {
                            coordinator.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Open System Settings") {
                        coordinator.openSystemSettings()
                    }
                }
            }

            Section("Disabled Applications (Bundle Identifiers)") {
                HStack {
                    TextField("Bundle ID (e.g. com.apple.Terminal)", text: $newBlockedBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("Disable App") {
                        let trimmed = newBlockedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            settings.toggleAppBlocked(bundleID: trimmed)
                            newBlockedBundleID = ""
                        }
                    }
                }

                ForEach(settings.blockedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button("Re-enable") {
                            settings.toggleAppBlocked(bundleID: bundleID)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
