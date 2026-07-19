import XCTest
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
}
