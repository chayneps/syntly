import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator
    @ObservedObject var settings: AppSettings
    public var onOpenWritingPad: (() -> Void)?

    @State private var newDictionaryWord: String = ""
    @State private var newBlockedBundleID: String = ""

    public init(
        coordinator: WritingAssistantCoordinator,
        settings: AppSettings = .shared,
        onOpenWritingPad: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.onOpenWritingPad = onOpenWritingPad
    }

    public var body: some View {
        TabView {
            apiConfigTab
                .tabItem {
                    Label("API & Models", systemImage: "server.rack")
                }

            writingStyleTab
                .tabItem {
                    Label("Preferences", systemImage: "slider.horizontal.3")
                }

            permissionsAndAppsTab
                .tabItem {
                    Label("Permissions & Apps", systemImage: "hand.raised.fill")
                }
        }
        .padding(16)
        .frame(width: 680, height: 530)
        .onAppear {
            settings.refreshAuthStatus()
            settings.fetchAvailableModels()
        }
    }

    // MARK: - Tab 1: Universal API Provider & Models

    private var apiConfigTab: some View {
        Form {
            Section("Quick Setup Presets") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a preset to automatically configure standard endpoints and models:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(APIProviderPreset.allCases) { preset in
                                Button {
                                    settings.applyPreset(preset)
                                } label: {
                                    HStack(spacing: 5) {
                                        if settings.activePreset == preset {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.blue)
                                        }
                                        Text(preset.displayName)
                                            .font(.caption.bold())
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        settings.activePreset == preset
                                            ? Color.blue.opacity(0.12)
                                            : Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(settings.activePreset == preset ? Color.blue.opacity(0.4) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Endpoint & Authentication (OpenAI Compatible)") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Base URL:")
                            .font(.caption.bold())
                        HStack {
                            TextField("http://127.0.0.1:8317/v1", text: $settings.apiEndpoint)
                                .textFieldStyle(.roundedBorder)
                            Button("Reset") {
                                settings.apiEndpoint = settings.activePreset.defaultEndpoint
                            }
                            .controlSize(.small)
                        }
                        Text("Accepts standard OpenAI-compatible completions endpoints (CLIProxyAPI, Kiro, LM Studio, Ollama, OpenAI, vLLM, etc.)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Token / Bearer Key:")
                            .font(.caption.bold())
                        HStack {
                            SecureField(settings.activePreset.requiresToken ? "Enter API Token or Key" : "Optional for local LM Studio / Ollama", text: $settings.apiTokenInput)
                                .textFieldStyle(.roundedBorder)

                            Button("Save Token") {
                                settings.saveAPITokenFromInput()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            if settings.hasStoredAPIToken {
                                Button("Clear") {
                                    settings.clearAPIToken()
                                }
                                .controlSize(.small)
                            }
                        }

                        HStack {
                            Image(systemName: settings.hasStoredAPIToken ? "lock.shield.fill" : "info.circle")
                                .foregroundStyle(settings.hasStoredAPIToken ? .green : .secondary)
                            Text(settings.hasStoredAPIToken
                                 ? "Token saved securely in macOS Keychain."
                                 : (settings.isPointingToCLIProxy
                                    ? "Using auto-detected key from ~/.cli-proxy-api/config.yaml or enter your custom key."
                                    : "Required for cloud gateways. Saved securely in macOS Keychain."))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Model Selection") {
                VStack(alignment: .leading, spacing: 14) {
                    // 1. As-You-Type Inline Checking Model
                    SuggestiveModelDropdown(
                        title: "As-You-Type Model",
                        subtitle: "Used in real-time as you type in text fields to detect typos and grammar mistakes. Low-latency models recommended.",
                        icon: "bolt.fill",
                        placeholder: "Type or select model…",
                        selectedModel: $settings.liveModel,
                        allModels: settings.discoveredModels,
                        isFetching: settings.isFetchingModels
                    )

                    Divider()

                    // 2. Dialog & Rewrite Model
                    SuggestiveModelDropdown(
                        title: "Dialog & Rewrite Model",
                        subtitle: "Used inside the suggestion popover dialog for deep explanations, tone adjustments, and full sentence rewrites.",
                        icon: "character.bubble.fill",
                        placeholder: "Type or select model…",
                        selectedModel: $settings.rewriteModel,
                        allModels: settings.discoveredModels,
                        isFetching: settings.isFetchingModels
                    )
                }
            }

            Section("Connection Test") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            settings.testCurrentConnection()
                        } label: {
                            if settings.connectionTestState.isTesting {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Testing Endpoint…")
                                }
                            } else {
                                Label("Test Connection Now", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.connectionTestState.isTesting)

                        Spacer()
                    }

                    switch settings.connectionTestState {
                    case .idle:
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("Click 'Test Connection Now' to test your endpoint, token, and models.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                    case .testing(let message):
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                    case .completed(let results):
                        let allPassed = !results.isEmpty && results.allSatisfy { $0.isSuccess }
                        let anyPassed = results.contains { $0.isSuccess }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: allPassed ? "checkmark.seal.fill" : (anyPassed ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                                    .foregroundStyle(allPassed ? .green : (anyPassed ? .orange : .red))
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(allPassed ? "Connection Succeeded" : (anyPassed ? "Partial Connection Warning" : "Connection Failed"))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(allPassed ? .green : (anyPassed ? .orange : .red))

                                    Text(allPassed ? "All configured models responded cleanly. Synt(ax)ly is ready!" : "One or more models failed to respond. Review details below.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(results) { res in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: res.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .foregroundStyle(res.isSuccess ? .green : .red)
                                                .font(.caption)

                                            Text(res.role)
                                                .font(.caption.bold())
                                                .foregroundStyle(.primary)

                                            Text("(\(res.model))")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)

                                            Spacer()

                                            if res.isSuccess {
                                                Text("\(res.latencyMs)ms")
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.12), in: Capsule())
                                                    .foregroundStyle(.green)
                                            } else {
                                                Text("Failed")
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.red.opacity(0.12), in: Capsule())
                                                    .foregroundStyle(.red)
                                            }
                                        }

                                        if let err = res.errorMessage, !res.isSuccess {
                                            Text(err)
                                                .font(.caption2)
                                                .foregroundStyle(.red)
                                                .padding(.leading, 18)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            (allPassed ? Color.green : (anyPassed ? Color.orange : Color.red)).opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    (allPassed ? Color.green : (anyPassed ? Color.orange : Color.red)).opacity(0.25),
                                    lineWidth: 1
                                )
                        )

                    case .success(let latencyMs, let model, _):
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connection Succeeded (\(latencyMs)ms)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.green)
                                Text("Model '\(model)' responded cleanly. Synt(ax)ly is ready!")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                        )

                    case .failure(let message):
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connection Failed")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.red)
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            settings.fetchAvailableModels()
        }
        .onChange(of: settings.apiEndpoint) { _, _ in
            settings.fetchAvailableModels()
        }
    }

    // MARK: - Tab 3: Writing Style & Personal Dictionary

    private var writingStyleTab: some View {
        Form {
            Section("Language & Dialect") {
                Picker("English Variety:", selection: $settings.dialect) {
                    ForEach(EnglishDialect.allCases) { dialect in
                        Text(dialect.rawValue).tag(dialect)
                    }
                }

                Toggle("Only Activate on English Text", isOn: $settings.enableEnglishOnlyActivation)
                Text("Automatically hides the pill and skips proofreading when text starts with a non-English language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("Floating Pill Size") {
                Picker("Pill Size:", selection: $settings.pillSize) {
                    ForEach(PillSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Text("Controls the size of the floating manga thought bubble indicator near your typing cursor. Default is Compact (the original compact size).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("System & Dock") {
                Toggle("Show App Icon in Dock", isOn: $settings.showDockIcon)
                Text("When disabled, Synt(ax)ly runs quietly in your menu bar without occupying space in the Dock.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLoginState },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                Text("Automatically launches Synt(ax)ly in your menu bar when you log in to macOS.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                        Text("Allows Synt(ax)ly to read focused text fields and apply your accepted corrections across apps.")
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

            Section("Floating Pill Position Memory") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "hand.draw.fill")
                            .foregroundStyle(.pink)
                        Text("Per-App Drag & Memory")
                            .font(.subheadline.bold())
                        Spacer()
                        if !settings.appPillOffsets.isEmpty {
                            Button("Reset All Positions") {
                                settings.resetAllPillOffsets()
                            }
                            .controlSize(.small)
                        }
                    }

                    Text("You can drag the Synt(ax)ly pill anytime to place it anywhere relative to your text. Each app automatically memorizes its dragged position.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Tip: Double-click the pill in any app to instantly snap it back to default.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if settings.appPillOffsets.isEmpty {
                        Text("No custom positions saved yet. Pill is using default placement.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    } else {
                        Text("\(settings.appPillOffsets.count) app(s) have memorized custom pill positions.")
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension View {
    @ViewBuilder
    func disableWritingToolsIfAvailable() -> some View {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            self.writingToolsBehavior(.disabled)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Suggestive Model Dropdown

struct SuggestiveModelDropdown: View {
    let title: String
    let subtitle: String
    let icon: String
    let placeholder: String
    @Binding var selectedModel: String
    let allModels: [String]
    let isFetching: Bool

    @State private var isDropdownOpen: Bool = false
    @FocusState private var isFieldFocused: Bool

    var filteredModels: [String] {
        let q = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return allModels
        }
        return allModels.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                    .font(.caption.bold())
                Text(title)
                    .font(.subheadline.weight(.semibold))

                if isFetching {
                    ProgressView().controlSize(.small)
                        .scaleEffect(0.7)
                }

                Spacer()

                if !allModels.isEmpty {
                    Text("\(allModels.count) discovered")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Direct editable input field with dropdown chevron
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $selectedModel)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFieldFocused)
                    .onSubmit {
                        isDropdownOpen = false
                    }
                    .onChange(of: selectedModel) { _, newValue in
                        // As user types, if field is focused and not already an exact match, show suggestions
                        if isFieldFocused && !newValue.isEmpty && !allModels.contains(newValue) {
                            isDropdownOpen = true
                        }
                    }

                if !selectedModel.isEmpty {
                    Button {
                        selectedModel = ""
                        isDropdownOpen = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    isDropdownOpen.toggle()
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDropdownOpen || isFieldFocused ? Color.blue : Color.primary.opacity(0.15), lineWidth: 1)
            )
            .popover(isPresented: $isDropdownOpen, arrowEdge: .bottom) {
                dropdownPopoverList
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    private var dropdownPopoverList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(allModels.isEmpty ? "No Models Discovered" : "Discovered Models (\(filteredModels.count))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    isDropdownOpen = false
                }
                .controlSize(.small)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if allModels.isEmpty {
                        VStack(spacing: 4) {
                            Text("No models discovered from endpoint.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Check your API Base URL and token above.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                    } else if filteredModels.isEmpty {
                        VStack(spacing: 4) {
                            Text("No discovered models matching \"\(selectedModel)\".")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("You can keep this custom model name or clear the text to see all.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                    } else {
                        ForEach(filteredModels, id: \.self) { model in
                            ModelRowButton(
                                model: model,
                                isSelected: selectedModel == model
                            ) {
                                selectedModel = model
                                isDropdownOpen = false
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 240)

            Divider()

            HStack {
                Text("Click a model to select, or type custom name in the field")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 360, height: 300)
    }
}

struct ModelRowButton: View {
    let model: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }

                Text(model)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isSelected ? .blue : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color.blue.opacity(0.12)
                    : (isHovered ? Color.primary.opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
