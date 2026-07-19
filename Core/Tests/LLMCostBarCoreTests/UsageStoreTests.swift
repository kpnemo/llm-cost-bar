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
        let s = try store.summary(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(s.todayUSD, 2.80, accuracy: 0.001)       // 2.10 + 0.70
        XCTAssertEqual(s.monthUSD, 61.90, accuracy: 0.001)      // + 59.10
    }

    func testVendorSummaryWithTopKeys() throws {
        let store = UsageStore(db: try makeDB())
        try seed(store)
        let vendors = try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
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
        let s = try store.summary(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(s.todayUSD, 2.5, accuracy: 0.001)          // live delta, not 0
        XCTAssertEqual(s.monthUSD, 5.5, accuracy: 0.001)          // 3.00 (yesterday) + 2.5, no double count
        XCTAssertEqual(s.last30USD, 5.5, accuracy: 0.001)         // same live-corrected t flows into last30
        let v = try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")[0]
        XCTAssertEqual(v.todayUSD, 2.5, accuracy: 0.001)
        XCTAssertEqual(v.last30USD, 5.5, accuracy: 0.001)         // 3.00 (2026-07-18, inside window) + 2.5 live delta
        // Baseline is INSERT OR IGNORE — a later sync must not move it.
        try store.recordDailyBaseline(vendor: "openrouter", accountID: "acc1",
                                      day: "2026-07-19", totalUsageUSD: 99.0)
        XCTAssertEqual(try store.summary(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20").todayUSD, 2.5, accuracy: 0.001)
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
        let s = try store.summary(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(s.todayUSD, 0, accuracy: 0.001)
        XCTAssertEqual(s.monthUSD, 0, accuracy: 0.001)
        XCTAssertTrue(try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20").isEmpty)
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

    /// Regression: header Today must equal the sum of the per-vendor cards even when
    /// one vendor's activity feed lags (live baseline delta wins) while another's is
    /// current (activity rows win). Previously summary() took a single max over the
    /// POOLED activity sum and the POOLED live delta, under-counting vs the cards,
    /// which each take their own per-vendor max.
    func testHeaderTodayEqualsSumOfVendorCardsWhenFeedsDisagree() throws {
        let store = UsageStore(db: try makeDB())
        // OpenAI: activity feed is current for today.
        try store.addAccount(id: "acc-oai", vendor: "openai", displayName: "oai")
        try store.upsertUsage([UsageRecord(vendor: "openai", accountID: "acc-oai", apiKeyID: "org",
                                           model: "GPT-4o", day: "2026-07-19", requests: 1,
                                           tokensIn: 1, tokensOut: 1, costUSD: 0.054)])
        // OpenRouter: activity feed lags (no row for today); live balance delta is the truth.
        try store.addAccount(id: "acc-or", vendor: "openrouter", displayName: "or")
        try store.recordDailyBaseline(vendor: "openrouter", accountID: "acc-or",
                                      day: "2026-07-19", totalUsageUSD: 70.528)
        try store.upsertBalance(vendor: "openrouter", accountID: "acc-or",
                                balance: Balance(balanceUSD: 9, totalCreditsUSD: 80, totalUsageUSD: 70.982))
        // Anthropic: nothing at all today.
        try store.addAccount(id: "acc-ant", vendor: "anthropic", displayName: "ant")

        let summary = try store.summary(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        let vendors = try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(vendors.count, 3)
        let cardsToday = vendors.reduce(0) { $0 + $1.todayUSD }
        let cardsMonth = vendors.reduce(0) { $0 + $1.monthUSD }
        // openai 0.054 + openrouter (70.982-70.528)=0.454 + anthropic 0 = 0.508
        XCTAssertEqual(cardsToday, 0.508, accuracy: 0.001)
        XCTAssertEqual(summary.todayUSD, cardsToday, accuracy: 0.0001,
                       "header today must equal the sum of the vendor cards")
        XCTAssertEqual(summary.monthUSD, cardsMonth, accuracy: 0.0001,
                       "header MTD must equal the sum of the vendor cards")
    }

    /// Multi-vendor: rows are bucketed per vendor and the header aggregates all of them.
    func testSummaryAggregatesAcrossVendors() throws {
        let store = UsageStore(db: try makeDB())
        try store.addAccount(id: "a1", vendor: "openrouter", displayName: "or")
        try store.addAccount(id: "a2", vendor: "openai", displayName: "oai")
        try store.upsertUsage([
            UsageRecord(vendor: "openrouter", accountID: "a1", apiKeyID: "k", model: "m",
                        day: "2026-07-19", requests: 1, tokensIn: 1, tokensOut: 1, costUSD: 1.0),
            UsageRecord(vendor: "openai", accountID: "a2", apiKeyID: "k", model: "m",
                        day: "2026-07-19", requests: 1, tokensIn: 1, tokensOut: 1, costUSD: 2.0),
            UsageRecord(vendor: "openai", accountID: "a2", apiKeyID: "k", model: "m",
                        day: "2026-07-01", requests: 1, tokensIn: 1, tokensOut: 1, costUSD: 10.0),
        ])
        let vendors = try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(Set(vendors.map(\.vendor)), ["openrouter", "openai"])
        XCTAssertEqual(vendors.first { $0.vendor == "openrouter" }?.todayUSD ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(vendors.first { $0.vendor == "openai" }?.monthUSD ?? 0, 12.0, accuracy: 0.001)
        let s = try store.summary(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(s.todayUSD, 3.0, accuracy: 0.001)
        XCTAssertEqual(s.monthUSD, 13.0, accuracy: 0.001)
    }

    /// Regression: the per-vendor Today must sum per-ACCOUNT maxes. A max over
    /// vendor-pooled sums under-counts when one account's activity feed is current
    /// while another account's lags and only its live delta knows about spend.
    func testVendorTodaySumsPerAccountMaxes() throws {
        let store = UsageStore(db: try makeDB())
        // Account 1: activity current ($5); its live delta only knows $2.
        try store.addAccount(id: "a1", vendor: "openrouter", displayName: "one")
        try store.upsertUsage([UsageRecord(vendor: "openrouter", accountID: "a1", apiKeyID: "k",
                                           model: "m", day: "2026-07-19", requests: 0,
                                           tokensIn: 0, tokensOut: 0, costUSD: 5)])
        try store.recordDailyBaseline(vendor: "openrouter", accountID: "a1", day: "2026-07-19", totalUsageUSD: 100)
        try store.upsertBalance(vendor: "openrouter", accountID: "a1",
                                balance: Balance(balanceUSD: 0, totalCreditsUSD: nil, totalUsageUSD: 102))
        // Account 2: activity lags (no rows); live delta is the truth ($3).
        try store.addAccount(id: "a2", vendor: "openrouter", displayName: "two")
        try store.recordDailyBaseline(vendor: "openrouter", accountID: "a2", day: "2026-07-19", totalUsageUSD: 50)
        try store.upsertBalance(vendor: "openrouter", accountID: "a2",
                                balance: Balance(balanceUSD: 0, totalCreditsUSD: nil, totalUsageUSD: 53))

        let v = try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(v.count, 1)
        // max(5,2) + max(0,3) = 8; a vendor-pooled max(5+0, 2+3) would say 5.
        XCTAssertEqual(v[0].todayUSD, 8.0, accuracy: 0.001)
        let s = try store.summary(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(s.todayUSD, 8.0, accuracy: 0.001)
    }

    /// Regression: removing an account must not leave key_totals/usage_snapshots
    /// orphans — stale key rows would double the per-key list after re-pairing.
    func testRemoveAccountClearsKeyTotalsAndSnapshots() throws {
        let store = UsageStore(db: try makeDB())
        try store.addAccount(id: "a1", vendor: "openai", displayName: "one")
        try store.upsertKeyTotals(vendor: "openai", accountID: "a1",
                                  totals: [KeyTotal(apiKeyID: "prod", totalUSD: 9)])
        try store.recordDailyBaseline(vendor: "openai", accountID: "a1", day: "2026-07-19", totalUsageUSD: 1)
        try store.removeAccount(id: "a1")

        // Re-pair under a new account id: the vendor card must show only fresh rows.
        try store.addAccount(id: "a2", vendor: "openai", displayName: "two")
        try store.upsertKeyTotals(vendor: "openai", accountID: "a2",
                                  totals: [KeyTotal(apiKeyID: "prod", totalUSD: 4)])
        let v = try store.vendorSummaries(today: "2026-07-19", monthPrefix: "2026-07", last30Start: "2026-06-20")
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].topKeys.count, 1, "stale key_totals from the removed account must be gone")
        XCTAssertEqual(v[0].topKeys[0].totalUSD, 4.0, accuracy: 0.001)
    }

    func testKeyTotalWindowsRoundTripAndMTDOrdering() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q)
        let store = UsageStore(db: q)
        try store.upsertKeyTotals(vendor: "anthropic", accountID: "a", totals: [
            KeyTotal(apiKeyID: "small-total-big-mtd", totalUSD: 5, todayUSD: 1, mtdUSD: 4),
            KeyTotal(apiKeyID: "big-total-small-mtd", totalUSD: 9, todayUSD: 0, mtdUSD: 2),
        ])
        // OpenRouter-style: no windows → NULLs round-trip as nil
        try store.upsertKeyTotals(vendor: "openrouter", accountID: "o", totals: [
            KeyTotal(apiKeyID: "or-key", totalUSD: 7),
        ])
        let vendors = try store.vendorSummaries(today: "2026-07-20", monthPrefix: "2026-07", last30Start: "2026-06-21")
        let anth = vendors.first { $0.vendor == "anthropic" }!.topKeys
        XCTAssertEqual(anth.map(\.apiKeyID), ["small-total-big-mtd", "big-total-small-mtd"],
                       "ordering must be by MTD desc, not total")
        XCTAssertEqual(anth[0].todayUSD, 1); XCTAssertEqual(anth[0].mtdUSD, 4)
        XCTAssertEqual(anth[1].todayUSD, 0)
        XCTAssertEqual(anth[1].mtdUSD, 2)
        let or = vendors.first { $0.vendor == "openrouter" }!.topKeys
        XCTAssertNil(or[0].todayUSD); XCTAssertNil(or[0].mtdUSD)
        XCTAssertEqual(or[0].totalUSD, 7)
    }

    /// last30USD must be live-corrected the same way today/MTD are: a window sum
    /// over [last30Start, today) that EXCLUDES today's rows, plus the same `t`
    /// (max(activityToday, liveDelta)) added back in — so today's spend is never
    /// double-counted (once from the window sum, once from live correction) nor
    /// dropped (if today's activity feed lags and only the live delta knows about it).
    func testLast30SumIsLiveCorrectedAndWindowed() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q)
        let store = UsageStore(db: q)
        try store.upsertUsage([
            // inside window (== last30Start, inclusive)
            UsageRecord(vendor: "openrouter", accountID: "a", apiKeyID: "k", model: "m",
                        day: "2026-06-21", requests: 0, tokensIn: 0, tokensOut: 0, costUSD: 3),
            // outside window (day before last30Start)
            UsageRecord(vendor: "openrouter", accountID: "a", apiKeyID: "k", model: "m",
                        day: "2026-06-20", requests: 0, tokensIn: 0, tokensOut: 0, costUSD: 100),
            // today — must NOT be double counted: excluded from the SUM, added via todayUSD
            UsageRecord(vendor: "openrouter", accountID: "a", apiKeyID: "k", model: "m",
                        day: "2026-07-20", requests: 0, tokensIn: 0, tokensOut: 0, costUSD: 2),
        ])
        let vendors = try store.vendorSummaries(today: "2026-07-20", monthPrefix: "2026-07",
                                                last30Start: "2026-06-21")
        let v = vendors.first { $0.vendor == "openrouter" }!
        XCTAssertEqual(v.todayUSD, 2, accuracy: 0.001)
        XCTAssertEqual(v.last30USD, 5, accuracy: 0.001)   // 3 (window) + 2 (today)
        let s = try store.summary(today: "2026-07-20", monthPrefix: "2026-07", last30Start: "2026-06-21")
        XCTAssertEqual(s.last30USD, 5, accuracy: 0.001)
    }

    func testV5MigrationPreservesExistingKeyTotals() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q, upTo: "v4-usage-snapshots")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO key_totals (vendor, account_id, api_key_id, total_usd, fetched_at)
                VALUES ('openrouter','a','k',5.0,'2026-07-19T00:00:00Z')
                """)
        }
        try Database.migrator.migrate(q)
        let row = try q.read { try Row.fetchOne($0, sql: "SELECT * FROM key_totals")! }
        XCTAssertEqual(row["total_usd"] as Double, 5.0)
        XCTAssertNil(row["today_usd"] as Double?)
        XCTAssertNil(row["mtd_usd"] as Double?)
    }
}
