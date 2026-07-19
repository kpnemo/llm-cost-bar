import Foundation
import Security

public struct KeychainError: Error { public let status: OSStatus }

/// Generic-password storage for vendor API keys. App and daemon share items via the
/// keychain-access-groups entitlement (configured in Task 11); tests use the plain login keychain.
public final class KeychainStore: Sendable {
    private let service: String
    public init(service: String = "com.mikeb.llmcostbar") { self.service = service }

    private func baseQuery(_ accountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: accountID]
    }

    public func setKey(_ key: String, accountID: String) throws {
        try deleteKey(accountID: accountID)
        var q = baseQuery(accountID)
        q[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func getKey(accountID: String) throws -> String? {
        var q = baseQuery(accountID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func deleteKey(accountID: String) throws {
        let status = SecItemDelete(baseQuery(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
