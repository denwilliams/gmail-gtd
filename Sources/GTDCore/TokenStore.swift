import Foundation
import Security

public struct Tokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiry: Date
}

/// Keychain-backed token storage, shared by the app and the CLI.
public enum TokenStore {
    private static let service = "dev.denw.gmail-gtd"
    private static let account = "oauth-tokens"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func load() -> Tokens? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    public static func save(_ tokens: Tokens) throws {
        let data = try JSONEncoder().encode(tokens)
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw GmailError.keychain(status) }
    }

    public static func clear() { SecItemDelete(query as CFDictionary) }
}
