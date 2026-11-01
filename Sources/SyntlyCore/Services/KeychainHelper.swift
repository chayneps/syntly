import Foundation
import Security

/// Manages secure credential storage for Syntly.
/// Prefers user-private credentials file (`~/.config/syntly/credentials.json` with chmod 0600)
/// to avoid repeated macOS Keychain authorization prompts on ad-hoc signed builds,
/// with graceful fallback to system Keychain when needed.
public enum KeychainHelper {
    private static let service = "dev.syntly.app"
    private static let apiKeyAccount = "syntly_api_token"
    private static let legacyAccount = "gemini_api_key"

    private static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/syntly/credentials.json")
    }

    public static func saveAPIToken(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return deleteAPIToken()
        }

        // 1. Save to ~/.config/syntly/credentials.json with POSIX 0600 permissions
        let fileSaved = saveToFile(trimmed)

        // 2. Also attempt to save to Keychain (silent failover if restricted)
        if let data = trimmed.data(using: .utf8) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: apiKeyAccount
            ]
            SecItemDelete(query as CFDictionary)
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }

        return fileSaved
    }

    public static func loadAPIToken() -> String? {
        // 1. Try ~/.config/syntly/credentials.json first (fast, zero macOS password prompts)
        if let fileKey = loadFromFile(), !fileKey.isEmpty {
            return fileKey
        }

        // 2. Fallback to macOS Keychain (try current account, then legacy account)
        for account in [apiKeyAccount, legacyAccount] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess,
               let data = item as? Data,
               let str = String(data: data, encoding: .utf8),
               !str.isEmpty {
                return str
            }
        }
        return nil
    }

    @discardableResult
    public static func deleteAPIToken() -> Bool {
        // Delete file
        let url = configURL
        try? FileManager.default.removeItem(at: url)

        // Delete from Keychain
        for account in [apiKeyAccount, legacyAccount] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
        return true
    }

    // Backwards-compatible aliases
    public static func saveAPIKey(_ key: String) -> Bool { saveAPIToken(key) }
    public static func loadAPIKey() -> String? { loadAPIToken() }
    @discardableResult
    public static func deleteAPIKey() -> Bool { deleteAPIToken() }

    private static func saveToFile(_ key: String) -> Bool {
        let url = configURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            let json = try JSONSerialization.data(withJSONObject: ["api_token": key, "gemini_api_key": key], options: [.prettyPrinted])
            try json.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func loadFromFile() -> String? {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let token = obj["api_token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let key = obj["gemini_api_key"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
