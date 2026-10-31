import Foundation
import Combine

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published public var authMode: AuthProviderMode {
        didSet { defaults.set(authMode.rawValue, forKey: Keys.authMode) }
    }

    @Published public var dialect: EnglishDialect {
        didSet { defaults.set(dialect.rawValue, forKey: Keys.dialect) }
    }

    @Published public var liveModel: String {
        didSet { defaults.set(liveModel, forKey: Keys.liveModel) }
    }

    @Published public var rewriteModel: String {
        didSet { defaults.set(rewriteModel, forKey: Keys.rewriteModel) }
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

    @Published public var pausedUntil: Date? {
        didSet { defaults.set(pausedUntil, forKey: Keys.pausedUntil) }
    }

    @Published public var cliProxyBaseURL: String {
        didSet { defaults.set(cliProxyBaseURL, forKey: Keys.cliProxyBaseURL) }
    }

    @Published public var apiKeyInput: String = ""
    @Published public private(set) var hasStoredAPIKey: Bool = false
    @Published public private(set) var detectedGeminiCLIPath: String?
    @Published public private(set) var isGeminiCLISignedIn: Bool = false
    @Published public private(set) var isCLIProxyReachable: Bool = false

    public var isAuthReady: Bool {
        switch authMode {
        case .cliProxy:
            return true // Will ping on demand
        case .geminiCLI:
            return isGeminiCLISignedIn
        case .apiKey:
            return hasStoredAPIKey
        case .auto:
            return isCLIProxyReachable || hasStoredAPIKey || isGeminiCLISignedIn
        }
    }

    private enum Keys {
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
        static let pausedUntil = "syntly.pausedUntil"
        static let cliProxyBaseURL = "syntly.cliProxyBaseURL"
    }

    public static let availableModels: [String] = [
        "gemini-3-flash-preview",
        "gemini-3.5-flash",
        "gemini-3.1-flash-lite",
        "gemini-flash-latest",
        "gemini-2.5-flash"
    ]

    public init() {
        let modeStr = defaults.string(forKey: Keys.authMode) ?? AuthProviderMode.apiKey.rawValue
        self.authMode = AuthProviderMode(rawValue: modeStr) ?? .apiKey

        let dialectStr = defaults.string(forKey: Keys.dialect) ?? EnglishDialect.us.rawValue
        self.dialect = EnglishDialect(rawValue: dialectStr) ?? .us

        self.liveModel = "gemini-3-flash-preview"
        self.rewriteModel = "gemini-3-flash-preview"

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

        self.personalDictionary = defaults.stringArray(forKey: Keys.personalDictionary) ?? ["Syntly", "macOS"]
        self.blockedBundleIDs = defaults.stringArray(forKey: Keys.blockedBundleIDs) ?? [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.1password.1password",
            "com.bitwarden.desktop"
        ]
        self.customStyleInstruction = defaults.string(forKey: Keys.customStyleInstruction) ?? ""
        self.pausedUntil = defaults.object(forKey: Keys.pausedUntil) as? Date
        self.cliProxyBaseURL = defaults.string(forKey: Keys.cliProxyBaseURL) ?? "http://127.0.0.1:8317"

        refreshAuthStatus()
    }

    public func refreshAuthStatus() {
        let savedKey = KeychainHelper.loadAPIKey() ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
        self.hasStoredAPIKey = (savedKey != nil && !(savedKey!.isEmpty))
        if let key = savedKey, apiKeyInput.isEmpty {
            self.apiKeyInput = key
        }

        self.detectedGeminiCLIPath = Self.locateGeminiBinary()
        self.isGeminiCLISignedIn = Self.checkGeminiCLICredentials()

        checkCLIProxyHealth()
    }

    public func checkCLIProxyHealth() {
        guard let url = URL(string: cliProxyBaseURL) else {
            self.isCLIProxyReachable = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.0
        let probeSession = URLSession(configuration: config)

        probeSession.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    self?.isCLIProxyReachable = (http.statusCode < 500)
                } else {
                    self?.isCLIProxyReachable = false
                }
            }
        }.resume()
    }

    public func saveAPIKeyFromInput() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.deleteAPIKey()
        } else {
            _ = KeychainHelper.saveAPIKey(trimmed)
        }
        refreshAuthStatus()
    }

    public func clearAPIKey() {
        apiKeyInput = ""
        KeychainHelper.deleteAPIKey()
        refreshAuthStatus()
    }

    public func activeAPIKey() -> String? {
        if !apiKeyInput.isEmpty {
            return apiKeyInput
        }
        if let key = KeychainHelper.loadAPIKey(), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"], !env.isEmpty {
            return env
        }
        return nil
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

    public static func locateGeminiBinary() -> String? {
        let candidates = [
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini",
            "\(NSHomeDirectory())/.nvm/current/bin/gemini",
            "\(NSHomeDirectory())/.volta/bin/gemini",
            "\(NSHomeDirectory())/.bun/bin/gemini"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func checkGeminiCLICredentials() -> Bool {
        let home = NSHomeDirectory()
        let credPaths = [
            "\(home)/.gemini/oauth_creds.json",
            "\(home)/.gemini/google_accounts.json"
        ]
        return credPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
