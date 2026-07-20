import XCTest
import Security
@testable import LLMCostBarCore

final class KeychainStoreTests: XCTestCase {
    func testSetGetDeleteRoundTrip() throws {
        let store = KeychainStore(service: "com.mikeb.llmcostbar.test-\(UUID().uuidString)")
        XCTAssertNil(try store.getKey(accountID: "acc1"))
        try store.setKey("sk-or-v1-abc123", accountID: "acc1")
        XCTAssertEqual(try store.getKey(accountID: "acc1"), "sk-or-v1-abc123")
        try store.setKey("sk-or-v1-rotated", accountID: "acc1")   // overwrite
        XCTAssertEqual(try store.getKey(accountID: "acc1"), "sk-or-v1-rotated")
        try store.deleteKey(accountID: "acc1")
        XCTAssertNil(try store.getKey(accountID: "acc1"))
    }

    /// The whole point of the vault: any number of keys, ONE keychain item —
    /// so the daemon triggers one consent prompt total, not one per vendor.
    func testManyKeysProduceSingleKeychainItem() throws {
        let service = "com.mikeb.llmcostbar.test-\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        try store.setKey("key-a", accountID: "openrouter-1")
        try store.setKey("key-b", accountID: "anthropic-1")
        try store.setKey("key-c", accountID: "openai-1")
        XCTAssertEqual(try itemCount(service: service), 1)
        XCTAssertEqual(try store.getKey(accountID: "anthropic-1"), "key-b")
        try store.deleteKey(accountID: "anthropic-1")
        XCTAssertNil(try store.getKey(accountID: "anthropic-1"))
        XCTAssertEqual(try store.getKey(accountID: "openai-1"), "key-c")   // others untouched
    }

    /// Keys written by pre-1.3.4 versions (one item per account) must stay
    /// readable without migration — the daemon reads them via fallback.
    func testLegacyPerAccountItemReadableViaFallback() throws {
        let service = "com.mikeb.llmcostbar.test-\(UUID().uuidString)"
        try writeLegacyItem(service: service, accountID: "acc-legacy", key: "sk-old")
        let store = KeychainStore(service: service)
        XCTAssertEqual(try store.getKey(accountID: "acc-legacy"), "sk-old")
    }

    func testMigrationAbsorbsLegacyItemsIntoVault() throws {
        let service = "com.mikeb.llmcostbar.test-\(UUID().uuidString)"
        try writeLegacyItem(service: service, accountID: "acc1", key: "sk-one")
        try writeLegacyItem(service: service, accountID: "acc2", key: "sk-two")
        let store = KeychainStore(service: service)
        let migrated = try store.migrateLegacyKeys(accountIDs: ["acc1", "acc2", "acc-gone"])
        XCTAssertEqual(migrated, 2)
        XCTAssertEqual(try itemCount(service: service), 1)                  // legacy items deleted
        XCTAssertEqual(try store.getKey(accountID: "acc1"), "sk-one")
        XCTAssertEqual(try store.getKey(accountID: "acc2"), "sk-two")
        // Idempotent: second run is a no-op.
        XCTAssertEqual(try store.migrateLegacyKeys(accountIDs: ["acc1", "acc2"]), 0)
    }

    /// Vault entry wins over a stale legacy item with the same account id.
    func testVaultTakesPrecedenceOverLegacy() throws {
        let service = "com.mikeb.llmcostbar.test-\(UUID().uuidString)"
        try writeLegacyItem(service: service, accountID: "acc1", key: "sk-stale")
        let store = KeychainStore(service: service)
        try store.setKey("sk-fresh", accountID: "acc1")
        XCTAssertEqual(try store.getKey(accountID: "acc1"), "sk-fresh")
    }

    // MARK: - helpers

    /// Writes an item exactly the way pre-1.3.4 KeychainStore.setKey did.
    private func writeLegacyItem(service: String, accountID: String, key: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func itemCount(service: String) throws -> Int {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else {
            throw KeychainError(status: status)
        }
        return items.count
    }
}
