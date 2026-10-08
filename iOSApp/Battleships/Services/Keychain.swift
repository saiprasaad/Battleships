import Foundation
import Security

/// Stores the session token in the keychain, readable only on this device after first unlock.
@MainActor
final class KeychainTokenStorage: TokenStorage {
    private let service: String
    private let tokenAccount = "session-token"
    private let revocationsAccount = "sessions-to-revoke"

    init(service: String = Bundle.main.bundleIdentifier ?? "Battleships") {
        self.service = service
    }

    func loadToken() -> String? {
        load(tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveToken(_ token: String?) {
        save(token.map { Data($0.utf8) }, as: tokenAccount)
    }

    func loadPendingRevocations() -> [String] {
        load(revocationsAccount).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    func savePendingRevocations(_ tokens: [String]) {
        save(tokens.isEmpty ? nil : try? JSONEncoder().encode(tokens), as: revocationsAccount)
    }

    private func load(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func save(_ data: Data?, as account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let data else { return }
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
