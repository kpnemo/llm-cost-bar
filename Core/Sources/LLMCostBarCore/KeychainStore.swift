import Foundation
import Security

public struct KeychainError: Error, Equatable, Sendable { public let status: OSStatus }

/// Vendor API keys in the macOS Keychain, consolidated into a SINGLE generic-
/// password item (the "vault": account `__vault__`, value = JSON {accountID: key}).
///
/// Why one item: the keychain prompts per ITEM the first time a program reads
/// it. The daemon (a separate binary) reads keys — with one item that's one
/// "Always Allow" ever, instead of one per connected vendor.
///
/// Versions before 1.3.4 stored one item per account. Reads fall back to those
/// legacy items (the daemon was already allowed on them, so no new prompts),
/// and the APP absorbs them into the vault at launch via migrateLegacyKeys()
/// — silently, because the app created them. New installs have no legacy
/// items; the sweep is a no-op.
public final class KeychainStore: Sendable {
    private let service: String
    private static let vaultAccount = "__vault__"

    public init(service: String = "com.mikeb.llmcostbar") { self.service = service }

    // MARK: - public API (unchanged shape)

    public func getKey(accountID: String) throws -> String? {
        if let key = try readVault()[accountID] { return key }
        return try readItem(account: accountID)   // legacy per-account fallback
    }

    public func setKey(_ key: String, accountID: String) throws {
        var vault = try readVault()
        vault[accountID] = key
        try writeVault(vault)
        try deleteItem(account: accountID)        // drop any stale legacy copy
    }

    public func deleteKey(accountID: String) throws {
        var vault = try readVault()
        if vault.removeValue(forKey: accountID) != nil {
            try writeVault(vault)
        }
        try deleteItem(account: accountID)
    }

    /// One-shot consolidation of pre-1.3.4 per-account items into the vault.
    /// Call ONLY from the app (which created the legacy items, so reads are
    /// silent) — never from the daemon. Idempotent; returns how many keys
    /// were absorbed.
    @discardableResult
    public func migrateLegacyKeys(accountIDs: [String]) throws -> Int {
        var vault = try readVault()
        var migrated = 0
        for id in accountIDs where vault[id] == nil {
            guard let key = try readItem(account: id) else { continue }
            vault[id] = key
            migrated += 1
        }
        guard migrated > 0 else { return 0 }
        try writeVault(vault)
        for id in accountIDs { try deleteItem(account: id) }
        return migrated
    }

    // MARK: - vault codec

    private func readVault() throws -> [String: String] {
        guard let data = try readItemData(account: Self.vaultAccount) else { return [:] }
        // A corrupt vault must not brick key reads — treat as empty (legacy
        // fallback still works) rather than throwing on every sync.
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func writeVault(_ vault: [String: String]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try writeItemData(enc.encode(vault), account: Self.vaultAccount)
    }

    // MARK: - raw item helpers

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func readItem(account: String) throws -> String? {
        try readItemData(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func readItemData(account: String) throws -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return data
    }

    private func writeItemData(_ data: Data, account: String) throws {
        var q = baseQuery(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(q as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else { throw KeychainError(status: addStatus) }
        let updateStatus = SecItemUpdate(baseQuery(account) as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
    }

    private func deleteItem(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
