import Foundation
import Security

/// The Hugging Face access token, kept in the login Keychain rather than the
/// config JSON. The app reads it only when it talks to Hugging Face, so an
/// ad-hoc rebuild asks for Keychain access at most once, and only then.
enum KeychainToken {
    static let service = "com.humandetector.app.huggingface"
    private static let account = "token"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain: \(detail)"
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Whether a token is saved. Reads attributes only, which never prompts.
    static var exists: Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrLabel as String] = "Human Detector — Hugging Face token"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
