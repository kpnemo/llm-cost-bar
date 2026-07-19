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
        try store.upsertBalance(vendor: "openrouter", accountID: "acc1",
                                balance: Balance(balanceUSD: 38.50, totalCreditsUSD: 110, totalUsageUSD: 71.5))
        try store.upsertKeyTotals(vendor: "openrouter", accountID: "acc1", totals: [
            KeyTotal(apiKeyID: "claude-code", totalUSD: 120.5),
            KeyTotal(apiKeyID: "research-bot", totalUSD: 12.25),
            KeyTotal(apiKeyID: "unused-key", totalUSD: 0),
        ])
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
        XCTAssertEqual(v.creditsTotalUSD, 110)
        XCTAssertEqual(v.creditsUsedUSD, 71.5)
        XCTAssertEqual(v.topKeys.count, 2)                        // zero-spend keys hidden
        XCTAssertEqual(v.topKeys.first?.apiKeyID, "claude-code")  // ranked by lifetime spend
        XCTAssertEqual(v.topKeys.first?.accountID, "acc1")
        XCTAssertEqual(v.topKeys.first?.totalUSD ?? 0, 120.5, accuracy: 0.001)
    }

    func testLiveTodayDeltaOverridesLaggingActivity() throws {
        let store = UsageStore(db: try makeDB())
        try store.addAccount(id: "acc1", vendor: "openrouter", displayName: "personal")
        // Activity feed lags: no rows for today, one for yesterday.
        try store.upsertUsage([
            UsageRecord(vendor: "openrouter", accountID: "acc1", apiKeyID: "k",
                        model: "m", day: "2026-07-18", requests: 1,
                        tokensIn: 10, tokensOut: 5, costUSD: 3.00),
        ])
        // First sync of the day snapshotted lifetime usage at 70.0; it's now 72.5.
        try store.recordDailyBaseline(vendor: "openrouter", accountID: "acc1",
                                      day: "2026-07-19", totalUsageUSD: 70.0)
        try store.upsertBalance(vendor: "openrouter", accountID: "acc1",
                                balance: Balance(balanceUSD: 7.5, totalCreditsUSD: 80, totalUsageUSD: 72.5))
        let s = try store.summary(today: "2026-07-19", monthPrefix: "2026-07")
        XCTAssertEqual(s.todayUSD, 2.5, accuracy: 0.001)          // live delta, not 0
        XCTAssertEqual(s.monthUSD, 5.5, accuracy: 0.001)          // 3.00 (yesterday) + 2.5, no double count
        let v = try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07")[0]
        XCTAssertEqual(v.todayUSD, 2.5, accuracy: 0.001)
        // Baseline is INSERT OR IGNORE — a later sync must not move it.
        try store.recordDailyBaseline(vendor: "openrouter", accountID: "acc1",
                                      day: "2026-07-19", totalUsageUSD: 99.0)
        XCTAssertEqual(try store.summary(today: "2026-07-19", monthPrefix: "2026-07").todayUSD, 2.5, accuracy: 0.001)
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
