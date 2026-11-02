import Foundation
import Combine
import AppKit
import ServiceManagement

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Core API Provider Settings (Universal OpenAI-Compatible)

    @Published public var apiEndpoint: String {
        didSet {
            defaults.set(apiEndpoint, forKey: Keys.apiEndpoint)
            connectionTestState = .idle
        }
    }

    @Published public var apiTokenInput: String = "" {
        didSet {
            connectionTestState = .idle
        }
    }

    @Published public private(set) var hasStoredAPIToken: Bool = false

    @Published public var activePreset: APIProviderPreset {
        didSet { defaults.set(activePreset.rawValue, forKey: Keys.activePreset) }
    }

    @Published public var liveModel: String {
        didSet { defaults.set(liveModel, forKey: Keys.liveModel) }
    }

    @Published public var rewriteModel: String {
        didSet { defaults.set(rewriteModel, forKey: Keys.rewriteModel) }
    }

    @Published public var discoveredModels: [String] = []
    @Published public var isFetchingModels: Bool = false
    @Published public var connectionTestState: ConnectionTestState = .idle
    @Published public private(set) var isCLIProxyReachable: Bool = false

    // MARK: - Writing & Accessibility Preferences

    @Published public var dialect: EnglishDialect {
        didSet { defaults.set(dialect.rawValue, forKey: Keys.dialect) }
    }

    @Published public var debounceMs: Int {
        didSet { defaults.set(debounceMs, forKey: Keys.debounceMs) }
    }

    @Published public var enableAsYouType: Bool {
        didSet { defaults.set(enableAsYouType, forKey: Keys.enableAsYouType) }
    }

    @Published public var enableLocalSpellcheck: Bool {
        didSet { defaults.set(enableLocalSpellcheck, forKey: Keys.enableLocalSpellcheck) }
    }

    @Published public var personalDictionary: [String] {
        didSet { defaults.set(personalDictionary, forKey: Keys.personalDictionary) }
    }

    @Published public var blockedBundleIDs: [String] {
        didSet { defaults.set(blockedBundleIDs, forKey: Keys.blockedBundleIDs) }
    }

    @Published public var customStyleInstruction: String {
        didSet { defaults.set(customStyleInstruction, forKey: Keys.customStyleInstruction) }
    }

    @Published public var savedStyleRules: [SavedStyleRule] {
        didSet {
            if let data = try? JSONEncoder().encode(savedStyleRules) {
                defaults.set(data, forKey: Keys.savedStyleRules)
            }
        }
    }

    @Published public var pausedUntil: Date? {
        didSet { defaults.set(pausedUntil, forKey: Keys.pausedUntil) }
    }

    @Published public var appPillOffsets: [String: AppPillOffset] {
        didSet {
            if let data = try? JSONEncoder().encode(appPillOffsets) {
                defaults.set(data, forKey: Keys.appPillOffsets)
            }
        }
    }

    @Published public var appDialogOffsets: [String: AppPillOffset] {
        didSet {
            if let data = try? JSONEncoder().encode(appDialogOffsets) {
                defaults.set(data, forKey: Keys.appDialogOffsets)
            }
        }
    }

    // MARK: - Dock & Launch at Login Preferences

    @Published public var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: Keys.showDockIcon)
            updateDockIconPolicy()
        }
    }

    @Published public var launchAtLoginState: Bool = false

    // MARK: - Backward Compatibility Properties

    @Published public var authMode: AuthProviderMode {
        didSet { defaults.set(authMode.rawValue, forKey: Keys.authMode) }
    }

    public var cliProxyBaseURL: String {
        get { apiEndpoint }
        set { apiEndpoint = newValue }
    }

    public var apiKeyInput: String {
        get { apiTokenInput }
        set { apiTokenInput = newValue }
    }

    public var hasStoredAPIKey: Bool {
        hasStoredAPIToken
    }

    public var detectedGeminiCLIPath: String? {
        nil
    }

    public var isGeminiCLISignedIn: Bool {
        false
    }

    public var isAuthReady: Bool {
        guard let url = URL(string: apiEndpoint), url.scheme != nil, url.host != nil else {
            return false
        }
        let isLocal = url.host == "127.0.0.1" || url.host == "localhost"
        if isLocal {
            return true
        }
        return hasStoredAPIToken || !(apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private enum Keys {
        static let apiEndpoint = "syntly.apiEndpoint"
        static let activePreset = "syntly.activePreset"
        static let authMode = "syntly.authMode"
        static let dialect = "syntly.dialect"
        static let liveModel = "syntly.liveModel"
        static let rewriteModel = "syntly.rewriteModel"
        static let debounceMs = "syntly.debounceMs"
        static let enableAsYouType = "syntly.enableAsYouType"
        static let enableLocalSpellcheck = "syntly.enableLocalSpellcheck"
        static let personalDictionary = "syntly.personalDictionary"
        static let blockedBundleIDs = "syntly.blockedBundleIDs"
        static let customStyleInstruction = "syntly.customStyleInstruction"
        static let savedStyleRules = "syntly.savedStyleRules"
        static let pausedUntil = "syntly.pausedUntil"
        static let appPillOffsets = "syntly.appPillOffsets"
        static let appDialogOffsets = "syntly.appDialogOffsets"
        static let cliProxyBaseURL = "syntly.cliProxyBaseURL"
        static let showDockIcon = "syntly.showDockIcon"
        static let launchAtLogin = "syntly.launchAtLogin"
    }

    public static let defaultStyleRules: [SavedStyleRule] = [
        SavedStyleRule(
            name: "Active Voice & Concise",
            instruction: "Prefer active voice, eliminate filler words, and keep sentences concise."
        ),
        SavedStyleRule(
            name: "Executive & Formal",
            instruction: "Use professional phrasing, formal syntax, and maintain a polished executive tone."
        ),
        SavedStyleRule(
            name: "Warm & Conversational",
            instruction: "Keep the tone warm, approachable, friendly, and natural without slang."
        ),
        SavedStyleRule(
            name: "Academic & Objective",
            instruction: "Use precise academic vocabulary, third-person perspective, and objective phrasing."
        )
    ]

    public static let availableModels: [String] = [
        "gemini-3.8-flash-high",
        "gemini-3-flash",
        "gemini-2.5-flash",
        "gpt-4o-mini",
        "gpt-4o",
        "claude-3-5-sonnet",
        "claude-sonnet-5-5-high",
        "llama3.2",
        "qwen2.5-7b"
    ]

    public init() {
        let presetStr = defaults.string(forKey: Keys.activePreset) ?? APIProviderPreset.cliProxy.rawValue
        self.activePreset = APIProviderPreset(rawValue: presetStr) ?? .cliProxy

        let savedEndpoint = defaults.string(forKey: Keys.apiEndpoint)
            ?? defaults.string(forKey: Keys.cliProxyBaseURL)
            ?? APIProviderPreset.cliProxy.defaultEndpoint
        self.apiEndpoint = savedEndpoint

        let savedLiveModel = defaults.string(forKey: Keys.liveModel) ?? "gemini-3.8-flash-high"
        self.liveModel = savedLiveModel
        self.rewriteModel = defaults.string(forKey: Keys.rewriteModel) ?? savedLiveModel

        let modeStr = defaults.string(forKey: Keys.authMode) ?? AuthProviderMode.cliProxy.rawValue
        self.authMode = AuthProviderMode(rawValue: modeStr) ?? .cliProxy

        let dialectStr = defaults.string(forKey: Keys.dialect) ?? EnglishDialect.us.rawValue
        self.dialect = EnglishDialect(rawValue: dialectStr) ?? .us

        let savedDebounce = defaults.integer(forKey: Keys.debounceMs)
        self.debounceMs = savedDebounce > 0 ? savedDebounce : 750

        if defaults.object(forKey: Keys.enableAsYouType) == nil {
            self.enableAsYouType = true
        } else {
            self.enableAsYouType = defaults.bool(forKey: Keys.enableAsYouType)
        }

        if defaults.object(forKey: Keys.enableLocalSpellcheck) == nil {
            self.enableLocalSpellcheck = true
        } else {
            self.enableLocalSpellcheck = defaults.bool(forKey: Keys.enableLocalSpellcheck)
        }

        self.personalDictionary = defaults.stringArray(forKey: Keys.personalDictionary) ?? ["Synt(ax)ly", "Syntly", "macOS"]
        self.blockedBundleIDs = defaults.stringArray(forKey: Keys.blockedBundleIDs) ?? [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.1password.1password",
            "com.bitwarden.desktop"
        ]
        self.customStyleInstruction = defaults.string(forKey: Keys.customStyleInstruction) ?? ""

        if let data = defaults.data(forKey: Keys.savedStyleRules),
           let decoded = try? JSONDecoder().decode([SavedStyleRule].self, from: data) {
            self.savedStyleRules = decoded
        } else {
            self.savedStyleRules = Self.defaultStyleRules
        }
        self.pausedUntil = defaults.object(forKey: Keys.pausedUntil) as? Date

        if let data = defaults.data(forKey: Keys.appPillOffsets),
           let decoded = try? JSONDecoder().decode([String: AppPillOffset].self, from: data) {
            self.appPillOffsets = decoded
        } else {
            self.appPillOffsets = [:]
        }

        if let data = defaults.data(forKey: Keys.appDialogOffsets),
           let decoded = try? JSONDecoder().decode([String: AppPillOffset].self, from: data) {
            self.appDialogOffsets = decoded
        } else {
            self.appDialogOffsets = [:]
        }

        if defaults.object(forKey: Keys.showDockIcon) == nil {
            self.showDockIcon = false // Default: hidden in dock (menu bar only)
        } else {
            self.showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        }

        if #available(macOS 13.0, *) {
            self.launchAtLoginState = (SMAppService.mainApp.status == .enabled)
        } else {
            self.launchAtLoginState = defaults.bool(forKey: Keys.launchAtLogin)
        }

        refreshAuthStatus()
    }

    public var onDockIconVisibilityRestored: (() -> Void)?

    public func updateDockIconPolicy() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let policy: NSApplication.ActivationPolicy = self.showDockIcon ? .regular : .accessory
            if NSApp.activationPolicy() != policy {
                NSApp.setActivationPolicy(policy)
            }
            if self.showDockIcon {
                self.onDockIconVisibilityRestored?()
            }
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
                self.launchAtLoginState = (SMAppService.mainApp.status == .enabled)
            } catch {
                print("⚠️ [AppSettings] Failed to update SMAppService launchAtLogin: \(error)")
                self.launchAtLoginState = enabled
            }
        } else {
            self.launchAtLoginState = enabled
        }
        defaults.set(enabled, forKey: Keys.launchAtLogin)
        objectWillChange.send()
    }

    public func refreshAuthStatus() {
        let savedToken = KeychainHelper.loadAPIToken()
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ProcessInfo.processInfo.environment["SYNTHLY_API_KEY"]
            ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]

        self.hasStoredAPIToken = (savedToken != nil && !(savedToken!.isEmpty))
        if let token = savedToken, apiTokenInput.isEmpty {
            self.apiTokenInput = token
        } else if apiTokenInput.isEmpty && isPointingToCLIProxy {
            // Auto-populate with local CLIProxyAPI key if present
            if let autoKey = Self.detectLocalCLIProxyKey() {
                self.apiTokenInput = autoKey
            }
        }

        checkCLIProxyHealth()
    }

    public func checkCLIProxyHealth() {
        guard let url = URL(string: apiEndpoint), let host = url.host else {
            self.isCLIProxyReachable = false
            return
        }

        let isLocal = (host == "127.0.0.1" || host == "localhost")
        guard isLocal else {
            self.isCLIProxyReachable = true
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.0
        let probeSession = URLSession(configuration: config)

        probeSession.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    self?.isCLIProxyReachable = (http.statusCode < 500)
                } else {
                    self?.isCLIProxyReachable = false
                }
            }
        }.resume()
    }

    public func applyPreset(_ preset: APIProviderPreset) {
        self.activePreset = preset
        self.apiEndpoint = preset.defaultEndpoint
        if !preset.defaultModel.isEmpty {
            self.liveModel = preset.defaultModel
            self.rewriteModel = preset.defaultModel
        }
        self.connectionTestState = .idle

        if preset == .cliProxy && apiTokenInput.isEmpty {
            if let detected = Self.detectLocalCLIProxyKey() {
                self.apiTokenInput = detected
            }
        }

        fetchAvailableModels()
    }

    public func saveAPITokenFromInput() {
        let trimmed = apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.deleteAPIToken()
        } else {
            _ = KeychainHelper.saveAPIToken(trimmed)
        }
        refreshAuthStatus()
        fetchAvailableModels()
    }

    public func clearAPIToken() {
        apiTokenInput = ""
        KeychainHelper.deleteAPIToken()
        refreshAuthStatus()
    }

    public func saveAPIKeyFromInput() {
        saveAPITokenFromInput()
    }

    public func clearAPIKey() {
        clearAPIToken()
    }

    public func activeAPIToken() -> String? {
        let trimmed = apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let stored = KeychainHelper.loadAPIToken(), !stored.isEmpty {
            return stored
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["SYNTHLY_API_KEY"], !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        if isPointingToCLIProxy {
            if let autoKey = Self.detectLocalCLIProxyKey() {
                return autoKey
            }
        }
        return nil
    }

    public func activeAPIKey() -> String? {
        activeAPIToken()
    }

    public var isPointingToCLIProxy: Bool {
        if let url = URL(string: apiEndpoint), let host = url.host {
            return (host == "127.0.0.1" || host == "localhost") && url.port == 8317
        }
        return false
    }

    public static func detectLocalCLIProxyKey() -> String? {
        let configPath = "\(NSHomeDirectory())/.cli-proxy-api/config.yaml"
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        let lines = content.components(separatedBy: .newlines)
        var inApiKeysSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api-keys:") {
                inApiKeysSection = true
                continue
            }
            if inApiKeysSection {
                if trimmed.hasPrefix("-") {
                    let rawKey = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
                    if !rawKey.isEmpty {
                        return rawKey
                    }
                } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    inApiKeysSection = false
                }
            }
        }
        return nil
    }

    public func testCurrentConnection() {
        self.connectionTestState = .testing(message: "Starting connection test…")
        let endpoint = self.apiEndpoint
        let token = self.activeAPIToken()
        let live = self.liveModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rewrite = self.rewriteModel.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            if live == rewrite || rewrite.isEmpty {
                // Same model for both (or only one configured)
                await MainActor.run {
                    self.connectionTestState = .testing(message: "Testing model '\(live)'…")
                }
                let res = await LLMService.shared.testConnection(endpoint: endpoint, token: token, model: live)
                await MainActor.run {
                    switch res {
                    case .success(let latency, let model, _):
                        self.isCLIProxyReachable = true
                        self.connectionTestState = .completed(results: [
                            ModelTestResult(role: "As-You-Type & Dialog Model", model: model, latencyMs: latency, isSuccess: true)
                        ])
                    case .failure(let msg):
                        self.connectionTestState = .failure(message: msg)
                    default:
                        self.connectionTestState = res
                    }
                }
            } else {
                // Both models configured and different: test each model sequentially
                await MainActor.run {
                    self.connectionTestState = .testing(message: "1/2: Testing As-You-Type model '\(live)'…")
                }
                let liveRes = await LLMService.shared.testConnection(endpoint: endpoint, token: token, model: live)

                await MainActor.run {
                    self.connectionTestState = .testing(message: "2/2: Testing Dialog model '\(rewrite)'…")
                }
                let rewriteRes = await LLMService.shared.testConnection(endpoint: endpoint, token: token, model: rewrite)

                var results: [ModelTestResult] = []

                switch liveRes {
                case .success(let latency, let m, _):
                    results.append(ModelTestResult(role: "As-You-Type Model", model: m, latencyMs: latency, isSuccess: true))
                case .failure(let msg):
                    results.append(ModelTestResult(role: "As-You-Type Model", model: live, latencyMs: 0, isSuccess: false, errorMessage: msg))
                default: break
                }

                switch rewriteRes {
                case .success(let latency, let m, _):
                    results.append(ModelTestResult(role: "Dialog & Rewrite Model", model: m, latencyMs: latency, isSuccess: true))
                case .failure(let msg):
                    results.append(ModelTestResult(role: "Dialog & Rewrite Model", model: rewrite, latencyMs: 0, isSuccess: false, errorMessage: msg))
                default: break
                }

                let finalResults = results
                await MainActor.run {
                    if finalResults.contains(where: { $0.isSuccess }) {
                        self.isCLIProxyReachable = true
                    }
                    self.connectionTestState = .completed(results: finalResults)
                }
            }
        }
    }

    public func fetchAvailableModels() {
        let endpoint = self.apiEndpoint
        let token = self.activeAPIToken()

        self.isFetchingModels = true

        Task {
            defer {
                Task { @MainActor in
                    self.isFetchingModels = false
                }
            }
            do {
                let models = try await LLMService.shared.fetchAvailableModels(endpoint: endpoint, token: token)
                await MainActor.run {
                    self.discoveredModels = models
                }
            } catch {
                // Silently preserve existing discovered models if endpoint is temporarily unreachable
            }
        }
    }

    public func isCurrentlyPaused() -> Bool {
        guard let until = pausedUntil else { return false }
        if until > Date() {
            return true
        } else {
            DispatchQueue.main.async { self.pausedUntil = nil }
            return false
        }
    }

    public func pauseForOneHour() {
        pausedUntil = Date().addingTimeInterval(3600)
    }

    public func resumeMonitoring() {
        pausedUntil = nil
    }

    public func isAppBlocked(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return blockedBundleIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    public func toggleAppBlocked(bundleID: String) {
        if let idx = blockedBundleIDs.firstIndex(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            blockedBundleIDs.remove(at: idx)
        } else {
            blockedBundleIDs.append(bundleID)
        }
    }

    public func addWordToDictionary(_ word: String) {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !personalDictionary.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            personalDictionary.append(cleaned)
        }
    }

    public func removeWordFromDictionary(_ word: String) {
        personalDictionary.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    // MARK: - Saved Writing Style Rules

    public func saveStyleRule(name: String, instruction: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInst = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInst.isEmpty else { return }

        if let idx = savedStyleRules.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
            savedStyleRules[idx].instruction = trimmedInst
        } else {
            savedStyleRules.append(SavedStyleRule(name: trimmedName, instruction: trimmedInst))
        }
    }

    public func removeStyleRule(id: UUID) {
        savedStyleRules.removeAll { $0.id == id }
    }

    // MARK: - Per-App Pill & Dialog Offset Management

    public func pillOffset(for bundleID: String?) -> AppPillOffset? {
        guard let id = bundleID, !id.isEmpty else { return nil }
        return appPillOffsets[id]
    }

    public func setPillOffset(_ offset: AppPillOffset, for bundleID: String?) {
        guard let id = bundleID, !id.isEmpty else { return }
        appPillOffsets[id] = offset
    }

    public func resetPillOffset(for bundleID: String?) {
        guard let id = bundleID, !id.isEmpty else { return }
        appPillOffsets.removeValue(forKey: id)
    }

    public func dialogOffset(for bundleID: String?) -> AppPillOffset? {
        guard let id = bundleID, !id.isEmpty else { return nil }
        return appDialogOffsets[id]
    }

    public func setDialogOffset(_ offset: AppPillOffset, for bundleID: String?) {
        guard let id = bundleID, !id.isEmpty else { return }
        appDialogOffsets[id] = offset
    }

    public func resetDialogOffset(for bundleID: String?) {
        guard let id = bundleID, !id.isEmpty else { return }
        appDialogOffsets.removeValue(forKey: id)
    }

    public func resetAllPillOffsets() {
        appPillOffsets.removeAll()
        appDialogOffsets.removeAll()
    }
}
