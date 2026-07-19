import XCTest
@testable import LLMCostBarCore

final class KeyTotalAggregateTests: XCTestCase {
    /// now = 2026-07-25T12:00:00Z → "today" is 2026-07-25, MTD floor is 2026-07-01.
    private let now = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!

    func testSortsByMTDDescendingWhenMTDDiffers() {
        let perKeyDay = [
            "key_A": ["2026-07-01": 10.0],
            "key_B": ["2026-07-01": 20.0],
        ]
        let totals = KeyTotal.aggregate(perKeyDay: perKeyDay, names: [:], now: now)
        XCTAssertEqual(totals.map(\.apiKeyID), ["key_B", "key_A"])
    }

    /// Equal MTD → tie-break on total descending.
    func testTiesOnMTDBreakByTotalDescending() {
        let perKeyDay = [
            // Both have 5.0 MTD (July), but key_A carries extra cost from late
            // June — inside the trailing-30-day window (windowStart 2026-06-26
            // for this fixed `now`) but outside the MTD window — that inflates
            // its total without touching mtd.
            "key_A": ["2026-07-05": 5.0, "2026-06-28": 100.0],
            "key_B": ["2026-07-05": 5.0],
        ]
        let totals = KeyTotal.aggregate(perKeyDay: perKeyDay, names: [:], now: now)
        XCTAssertEqual(totals.first?.mtdUSD, totals.last?.mtdUSD, "precondition: MTD must tie")
        XCTAssertEqual(totals.map(\.apiKeyID), ["key_A", "key_B"], "higher total wins the tie")
    }

    /// Equal MTD and total → tie-break on apiKeyID ascending, so ordering is
    /// stable across refreshes instead of reshuffling with dictionary iteration order.
    func testTiesOnMTDAndTotalBreakByIDAscending() {
        let perKeyDay = [
            "key_Z": ["2026-07-05": 3.0],
            "key_A": ["2026-07-05": 3.0],
            "key_M": ["2026-07-05": 3.0],
        ]
        let totals = KeyTotal.aggregate(perKeyDay: perKeyDay, names: [:], now: now)
        XCTAssertEqual(totals.map(\.apiKeyID), ["key_A", "key_M", "key_Z"])
    }

    /// Two distinct key ids resolving to the same display name must be summed
    /// into a single row, not kept as separate entries.
    func testMergesDistinctIDsSharingADisplayName() {
        let perKeyDay = [
            "key_A": ["2026-07-01": 4.0, "2026-07-25": 1.0],
            "key_B": ["2026-07-02": 6.0],
        ]
        let names = ["key_A": "prod", "key_B": "prod"]
        let totals = KeyTotal.aggregate(perKeyDay: perKeyDay, names: names, now: now)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].apiKeyID, "prod")
        XCTAssertEqual(totals[0].totalUSD, 11.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].mtdUSD ?? -1, 11.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].todayUSD ?? -1, 1.0, accuracy: 0.001, "only key_A's 07-25 row lands on today")
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(KeyTotal.aggregate(perKeyDay: [:], names: [:], now: now), [])
    }

    /// Providers fetch ~31 days of buckets (today through today−30) so their
    /// perKeyDay maps can carry one day older than the header's trailing
    /// 30-day window (Day.last30Start). aggregate() must clip that extra day
    /// out of totalUSD so a key's 30d cell can never exceed the header total.
    func testDayOutsideThirtyDayWindowExcludedFromTotal() {
        let windowStart = Day.last30Start(now: now)
        let dayJustOutside = Day.utcToday(now: now.addingTimeInterval(-30 * 86400))
        XCTAssertLessThan(dayJustOutside, windowStart, "precondition: this day must fall outside the window")
        let perKeyDay = ["key_A": [dayJustOutside: 50.0, windowStart: 7.0]]
        let totals = KeyTotal.aggregate(perKeyDay: perKeyDay, names: [:], now: now)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].totalUSD, 7.0, accuracy: 0.001, "day older than the 30-day window must be dropped")
    }

    /// Regression: on the 31st of a 31-day month, Day.last30Start (today−29)
    /// falls AFTER the 1st of the month, so clipping mtd/today to windowStart
    /// the same way total is clipped would wrongly drop day-1 spend from MTD
    /// even though the header's MTD still includes it. Only totalUSD is
    /// clipped to the 30-day window; mtd/today are not.
    func testMonthFirstDaySpendCountsTowardMTDButNotTotalOn31stOfMonth() {
        let july31Noon = Date(timeIntervalSince1970: 1_785_499_200)   // 2026-07-31T12:00:00Z
        let windowStart = Day.last30Start(now: july31Noon)
        XCTAssertEqual(windowStart, "2026-07-02", "precondition: windowStart falls after the 1st in a 31-day month")
        let perKeyDay = ["key_A": ["2026-07-01": 9.0, "2026-07-31": 3.0]]
        let totals = KeyTotal.aggregate(perKeyDay: perKeyDay, names: [:], now: july31Noon)
        XCTAssertEqual(totals.count, 1)
        // 07-01 is before windowStart → excluded from total; 07-31 is today → total = 3.
        XCTAssertEqual(totals[0].totalUSD, 3.0, accuracy: 0.001, "day-01 must be clipped out of the 30d total")
        // Both days are >= monthStart (07-01) → mtd includes day-01's spend, unlike total.
        XCTAssertEqual(totals[0].mtdUSD ?? -1, 12.0, accuracy: 0.001, "day-01 spend must still count toward MTD")
        XCTAssertEqual(totals[0].todayUSD ?? -1, 3.0, accuracy: 0.001)
    }
}
