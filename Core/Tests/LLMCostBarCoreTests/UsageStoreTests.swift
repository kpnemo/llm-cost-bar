import XCTest
import GRDB
@testable import LLMCostBarCore

final class UsageStoreTests: XCTestCase {
    func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()          // in-memory
        try Database.migrator.migrate(dbq)
        return dbq
    }

    func testMigrationCreatesAllTables() throws {
        let dbq = try makeDB()
        try dbq.read { db in
            for table in ["usage_daily", "balances", "accounts", "alert_events", "sync_log"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
        }
    }

    func seed(_ store: UsageStore) throws {
        try store.addAccount(id: "acc1", vendor: "openrouter", displayName: "personal")
        try store.upsertUsage([
            UsageRecord(vendor: "openrouter", accountID: "acc1", apiKeyID: "claude-code",
                        model: "anthropic/claude-sonnet-4", day: "2026-07-19",
                        requests: 10, tokensIn: 1000, tokensOut: 500, costUSD: 1.40),
            UsageRecord(vendor: "openrouter", accountID: "acc1", apiKeyID: "research-bot",
                        model: "openai/gpt-5", day: "2026-07-19",
                        requests: 3, tokensIn: 200, tokensOut: 100, costUSD: 0.70),
            UsageRecord(vendor: "openrouter", accountID: "acc1", apiKeyID: "claude-code",
                        model: "anthropic/claude-sonnet-4", day: "2026-07-01",
                        requests: 50, tokensIn: 9000, tokensOut: 4000, costUSD: 59.10),
        ])
        try store.upsertBalance(vendor: "openrouter", accountID: "acc1", balanceUSD: 38.50)
    }

    func testUpsertIsIdempotentAndOverwrites() throws {
        let store = UsageStore(db: try makeDB())
        try seed(store)
        // Re-poll same day with higher numbers → row replaced, not duplicated
        try store.upsertUsage([
            UsageRecord(vendor: "openrouter", accountID: "acc1", apiKeyID: "claude-code",
                        model: "anthropic/claude-sonnet-4", day: "2026-07-19",
                        requests: 12, tokensIn: 1200, tokensOut: 600, costUSD: 2.10),
        ])
        let s = try store.summary(today: "2026-07-19", monthPrefix: "2026-07")
        XCTAssertEqual(s.todayUSD, 2.80, accuracy: 0.001)       // 2.10 + 0.70
        XCTAssertEqual(s.monthUSD, 61.90, accuracy: 0.001)      // + 59.10
    }

    func testVendorSummaryWithTopKeys() throws {
        let store = UsageStore(db: try makeDB())
        try seed(store)
        let vendors = try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07")
        XCTAssertEqual(vendors.count, 1)
        let v = vendors[0]
        XCTAssertEqual(v.vendor, "openrouter")
        XCTAssertEqual(v.todayUSD, 2.10, accuracy: 0.001)
        XCTAssertEqual(v.monthUSD, 61.20, accuracy: 0.001)
        XCTAssertEqual(v.balanceUSD, 38.50)
        XCTAssertEqual(v.topKeys.first?.apiKeyID, "claude-code") // ranked by today's spend
        XCTAssertEqual(v.topKeys.first?.accountID, "acc1")
        XCTAssertEqual(v.topKeys.first?.todayUSD ?? 0, 1.40, accuracy: 0.001)
    }

    func testSyncLogRoundTrip() throws {
        let store = UsageStore(db: try makeDB())
        try store.logSync(vendor: "openrouter", accountID: "acc1", endpoint: "/api/v1/credits",
                          httpStatus: 429, errorClass: "transient", message: "rate limited",
                          snippet: "{\"error\":\"slow down\"}")
        let rows = try store.recentSyncLog(limit: 10)
        XCTAssertEqual(rows.first?.errorClass, "transient")
        XCTAssertEqual(rows.first?.httpStatus, 429)
    }

    func testNeedsReauthFlag() throws {
        let store = UsageStore(db: try makeDB())
        try store.addAccount(id: "acc1", vendor: "openrouter", displayName: "personal")
        try store.setNeedsReauth(accountID: "acc1", value: true)
        XCTAssertTrue(try store.accounts()[0].needsReauth)
    }

    func testRemoveAccountCascades() throws {
        let store = UsageStore(db: try makeDB())
        try seed(store)
        try store.removeAccount(id: "acc1")
        XCTAssertTrue(try store.accounts().isEmpty)
        let s = try store.summary(today: "2026-07-19", monthPrefix: "2026-07")
        XCTAssertEqual(s.todayUSD, 0, accuracy: 0.001)
        XCTAssertEqual(s.monthUSD, 0, accuracy: 0.001)
        XCTAssertTrue(try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07").isEmpty)
    }

    func testMarkSyncOKClearsNeedsReauth() throws {
        let store = UsageStore(db: try makeDB())
        try store.addAccount(id: "acc1", vendor: "openrouter", displayName: "personal")
        try store.setNeedsReauth(accountID: "acc1", value: true)
        try store.markSyncOK(accountID: "acc1")
        let account = try store.accounts()[0]
        XCTAssertFalse(account.needsReauth)
        XCTAssertNotNil(account.lastSyncOK)
    }
}
