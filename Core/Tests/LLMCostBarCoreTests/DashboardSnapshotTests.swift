import XCTest
import GRDB
@testable import LLMCostBarCore

final class DashboardSnapshotTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-01T00:00:01Z")!

    private func makeStore() throws -> UsageStore {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        return UsageStore(db: db)
    }

    func testEmptyDashboardHasNoInventedCardsOrAmounts() throws {
        let snapshot = try DashboardSnapshot.load(from: makeStore(), now: now)
        XCTAssertEqual(snapshot.summary, Summary(todayUSD: 0, monthUSD: 0, last30USD: 0))
        XCTAssertTrue(snapshot.vendors.isEmpty)
        XCTAssertTrue(snapshot.charts.isEmpty)
        XCTAssertTrue(snapshot.subscriptionSeries.isEmpty)
    }

    func testHeaderMatchesDisplayedVendorsIncludingLiveSpendAtMonthBoundary() throws {
        let store = try makeStore()
        try store.addAccount(id: "a", vendor: "openrouter", displayName: "Test")
        try store.upsertUsage([
            UsageRecord(vendor: "openrouter", accountID: "a", apiKeyID: "key", model: "model", day: "2026-08-31", requests: 0, tokensIn: 0, tokensOut: 0, costUSD: 3),
            UsageRecord(vendor: "openrouter", accountID: "a", apiKeyID: "key", model: "model", day: "2026-09-01", requests: 0, tokensIn: 0, tokensOut: 0, costUSD: 1),
        ])
        try store.recordDailyBaseline(vendor: "openrouter", accountID: "a", day: "2026-09-01", totalUsageUSD: 10)
        try store.upsertBalance(vendor: "openrouter", accountID: "a", balance: Balance(balanceUSD: 5, totalUsageUSD: 12))
        let snapshot = try DashboardSnapshot.load(from: store, now: now)
        XCTAssertEqual(snapshot.summary.todayUSD, 2)
        XCTAssertEqual(snapshot.summary.monthUSD, 2)
        XCTAssertEqual(snapshot.summary.last30USD, 5)
        XCTAssertEqual(snapshot.summary.todayUSD, snapshot.vendors.reduce(0) { $0 + $1.todayUSD })
        let chart = try XCTUnwrap(snapshot.charts["openrouter"])
        XCTAssertEqual(chart.points.count, 30)
        XCTAssertEqual(chart.points.last, DayCost(day: "2026-09-01", costUSD: 2))
        XCTAssertTrue(chart.todayIsLiveEstimate)
    }

    func testChartHasStableDaysAndRollsForwardAtUTCMidnight() {
        let before = now.addingTimeInterval(-2)
        let series = [DayCost(day: "2026-08-31", costUSD: 3)]
        let first = SpendChart(series: series, todayUSD: 3, now: before)
        let second = SpendChart(series: series, todayUSD: 0, now: now)
        XCTAssertEqual(first.points.count, 30)
        XCTAssertEqual(Set(first.points.map(\.day)).count, 30)
        XCTAssertEqual(first.points.last?.day, "2026-08-31")
        XCTAssertEqual(second.points.last, DayCost(day: "2026-09-01", costUSD: 0))
        XCTAssertEqual(second.points.dropLast().last?.costUSD, 3)
        XCTAssertFalse(first.todayIsLiveEstimate)
        XCTAssertEqual(second, SpendChart(series: series, todayUSD: 0, now: now.addingTimeInterval(60)))
    }

    func testSubscriptionHistoryKeepsCorrectWeeklyWindows() throws {
        let store = try makeStore()
        for source in [SubscriptionSource.claude, SubscriptionSource.codex] {
            try store.registerSubscriptionSource(source: source, now: now)
            try store.upsertSubscriptionSnapshot(SubscriptionSnapshot(source: source, planType: nil,
                observedAt: now, origin: "api", windows: [
                    SubscriptionWindow(windowID: source == "claude" ? "seven_day" : "primary", usedPercent: 40),
                    SubscriptionWindow(windowID: source == "claude" ? "five_hour" : "secondary", usedPercent: 90)
                ]), now: now)
        }
        let snapshot = try DashboardSnapshot.load(from: store, now: now)
        XCTAssertEqual(snapshot.subscriptionWindows.count, 4)
        XCTAssertEqual(snapshot.subscriptionSeries["claude"]?.first?.usedPercent, 40)
        XCTAssertEqual(snapshot.subscriptionSeries["codex"]?.first?.usedPercent, 40)
    }
}
