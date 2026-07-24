import XCTest
import GRDB
@testable import LLMCostBarCore

final class SubscriptionStoreTests: XCTestCase {
    let iso = ISO8601DateFormatter()

    func makeStore() throws -> UsageStore {
        let dbq = try DatabaseQueue()
        try Database.migrator.migrate(dbq)
        return UsageStore(db: dbq)
    }

    func date(_ s: String) -> Date { iso.date(from: s)! }

    func snap(source: String = "claude", plan: String? = "max_5x", observed: String,
              origin: String = "api", windows: [SubscriptionWindow]) -> SubscriptionSnapshot {
        SubscriptionSnapshot(source: source, planType: plan, observedAt: date(observed),
                             origin: origin, windows: windows)
    }

    func testMigrationCreatesSubscriptionTables() throws {
        let dbq = try DatabaseQueue()
        try Database.migrator.migrate(dbq)
        try dbq.read { db in
            XCTAssertTrue(try db.tableExists("subscription_sources"))
            XCTAssertTrue(try db.tableExists("subscription_snapshots"))
            XCTAssertTrue(try db.tableExists("subscription_credit"))
        }
    }

    func testCreditRowUpsertsAndZeroOverwrites() throws {
        let store = try makeStore()
        try store.registerSubscriptionSource(source: "claude")
        var s = snap(observed: "2026-07-24T10:00:00Z", origin: "web",
                     windows: [SubscriptionWindow(windowID: "five_hour", usedPercent: 10)])
        s.credit = SubscriptionCredit(spentMinor: 1234, limitMinor: 5000, currency: "USD",
                                      resetsAt: date("2026-08-01T00:00:00Z"), freeCreditsMinor: 500)
        try store.upsertSubscriptionSnapshot(s, now: date("2026-07-24T10:00:00Z"))
        var rows = try store.subscriptionCredits()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].spentMinor, 1234)
        XCTAssertEqual(rows[0].freeCreditsMinor, 500)
        XCTAssertEqual(rows[0].resetsAt, "2026-08-01T00:00:00Z")

        // Monthly reset: all-zero credit must overwrite the stale nonzero row.
        s.credit = SubscriptionCredit(spentMinor: 0, limitMinor: 5000, currency: "USD")
        s.observedAt = date("2026-08-01T10:00:00Z")
        try store.upsertSubscriptionSnapshot(s, now: date("2026-08-01T10:00:00Z"))
        rows = try store.subscriptionCredits()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].spentMinor, 0)

        // Snapshot without credit (OAuth fallback) leaves the row untouched.
        s.credit = nil
        s.observedAt = date("2026-08-01T11:00:00Z")
        try store.upsertSubscriptionSnapshot(s, now: date("2026-08-01T11:00:00Z"))
        XCTAssertEqual(try store.subscriptionCredits()[0].observedAt, "2026-08-01T10:00:00Z")
    }

    func testUpsertIsIdempotentOnObservedAt() throws {
        let store = try makeStore()
        try store.registerSubscriptionSource(source: "codex")
        let s = snap(source: "codex", plan: "plus", observed: "2026-07-20T10:00:00Z", origin: "jsonl",
                     windows: [SubscriptionWindow(windowID: "primary", usedPercent: 12,
                                                  resetsAt: date("2026-07-27T03:00:00Z"), windowMinutes: 10080)])
        try store.upsertSubscriptionSnapshot(s, now: date("2026-07-20T10:05:00Z"))
        try store.upsertSubscriptionSnapshot(s, now: date("2026-07-20T10:10:00Z"))   // re-parse of same event
        let rows = try store.latestSubscriptionWindows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].usedPercent, 12)
        XCTAssertEqual(rows[0].origin, "jsonl")
    }

    func testLatestPerWindowWithMixedHistory() throws {
        let store = try makeStore()
        try store.registerSubscriptionSource(source: "claude")
        try store.upsertSubscriptionSnapshot(
            snap(observed: "2026-07-20T09:00:00Z", windows: [
                SubscriptionWindow(windowID: "five_hour", usedPercent: 30),
                SubscriptionWindow(windowID: "seven_day", usedPercent: 55),
            ]), now: date("2026-07-20T09:00:00Z"))
        try store.upsertSubscriptionSnapshot(
            snap(observed: "2026-07-20T10:00:00Z", windows: [
                SubscriptionWindow(windowID: "five_hour", usedPercent: 42),
            ]), now: date("2026-07-20T10:00:00Z"))
        let rows = try store.latestSubscriptionWindows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.windowID == "five_hour" }?.usedPercent, 42)
        XCTAssertEqual(rows.first { $0.windowID == "seven_day" }?.usedPercent, 55)   // older row survives
    }

    func testSeriesBucketsSixHoursKeepingMax() throws {
        let store = try makeStore()
        try store.registerSubscriptionSource(source: "claude")
        // Two points in the same 6h bucket (00:00–06:00 UTC), one in the next.
        for (t, pct) in [("2026-07-20T01:00:00Z", 20.0), ("2026-07-20T05:00:00Z", 35.0),
                         ("2026-07-20T07:00:00Z", 40.0)] {
            try store.upsertSubscriptionSnapshot(
                snap(observed: t, windows: [SubscriptionWindow(windowID: "seven_day", usedPercent: pct)]),
                now: date(t))
        }
        let pts = try store.subscriptionSeries(source: "claude", windowID: "seven_day",
                                               now: date("2026-07-20T12:00:00Z"))
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0].usedPercent, 35)   // MAX in bucket, not last
        XCTAssertEqual(pts[1].usedPercent, 40)
    }

    func testRetentionPrunesOldSnapshots() throws {
        let store = try makeStore()
        try store.registerSubscriptionSource(source: "claude")
        try store.upsertSubscriptionSnapshot(
            snap(observed: "2026-07-01T00:00:00Z", windows: [SubscriptionWindow(windowID: "seven_day", usedPercent: 10)]),
            now: date("2026-07-01T00:00:00Z"))
        // A write 15+ days later prunes the old row.
        try store.upsertSubscriptionSnapshot(
            snap(observed: "2026-07-20T00:00:00Z", windows: [SubscriptionWindow(windowID: "seven_day", usedPercent: 50)]),
            now: date("2026-07-20T00:00:00Z"))
        let pts = try store.subscriptionSeries(source: "claude", windowID: "seven_day",
                                               sinceDaysAgo: 30, now: date("2026-07-20T01:00:00Z"))
        XCTAssertEqual(pts.count, 1)
        XCTAssertEqual(pts[0].usedPercent, 50)
    }

    func testRegisterPreservesEnabledToggle() throws {
        let store = try makeStore()
        try store.registerSubscriptionSource(source: "codex")
        try store.setSubscriptionSourceEnabled(source: "codex", enabled: false)
        try store.registerSubscriptionSource(source: "codex")   // re-detection next poll
        XCTAssertEqual(try store.subscriptionSources().first?.enabled, false)
    }

    func testClearSubscriptionStale() throws {
        // The app calls this optimistically right after a successful reconnect
        // so the card recovers instantly instead of waiting out the daemon's
        // next poll (users clicked Reconnect 3× thinking it hadn't worked).
        let store = try makeStore()
        try store.registerSubscriptionSource(source: "claude")
        try store.markSubscriptionStale(source: "claude", reason: "needs reconnect")
        try store.clearSubscriptionStale(source: "claude")
        let row = try store.subscriptionSources().first
        XCTAssertEqual(row?.stale, false)
        XCTAssertNil(row?.staleReason)
    }

    func testStaleMarkAndRecovery() throws {
        let store = try makeStore()
        try store.registerSubscriptionSource(source: "claude")
        try store.markSubscriptionStale(source: "claude", reason: "open Claude Code to refresh sign-in")
        var row = try store.subscriptionSources().first
        XCTAssertEqual(row?.stale, true)
        XCTAssertEqual(row?.staleReason, "open Claude Code to refresh sign-in")
        try store.upsertSubscriptionSnapshot(
            snap(observed: "2026-07-20T10:00:00Z", windows: [SubscriptionWindow(windowID: "seven_day", usedPercent: 61)]),
            now: date("2026-07-20T10:00:00Z"))
        row = try store.subscriptionSources().first
        XCTAssertEqual(row?.stale, false)
        XCTAssertNil(row?.staleReason)
        XCTAssertEqual(row?.planType, "max_5x")
    }

    func testAlertEventLifecycle() throws {
        let store = try makeStore()
        try store.insertAlertEvent(rule: "sub-threshold:claude:seven_day_opus",
                                   message: "Claude 7-day Opus at 87%")
        var pending = try store.undeliveredAlertEvents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].rule, "sub-threshold:claude:seven_day_opus")
        try store.markAlertDelivered(id: pending[0].id)
        pending = try store.undeliveredAlertEvents()
        XCTAssertTrue(pending.isEmpty)
    }

    func testWindowClampAndLabels() {
        XCTAssertEqual(SubscriptionWindow(windowID: "five_hour", usedPercent: 140).usedPercent, 100)
        XCTAssertEqual(SubscriptionWindow(windowID: "five_hour", usedPercent: -5).usedPercent, 0)
        XCTAssertEqual(SubscriptionWindow(windowID: "five_hour", usedPercent: 1).label, "5-hour")
        XCTAssertEqual(SubscriptionWindow(windowID: "seven_day_opus", usedPercent: 1).label, "7-day Opus")
        XCTAssertEqual(SubscriptionWindow(windowID: "primary", usedPercent: 1, windowMinutes: 10080).label, "Weekly")
        XCTAssertEqual(SubscriptionWindow(windowID: "secondary", usedPercent: 1, windowMinutes: 300).label, "5-hour")
        XCTAssertEqual(SubscriptionWindow(windowID: "primary", usedPercent: 1).label, "Primary")
    }
}
