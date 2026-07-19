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
            // Both have 5.0 MTD (July), but key_A carries extra cost from June
            // (outside the MTD window) that inflates its total.
            "key_A": ["2026-07-05": 5.0, "2026-06-15": 100.0],
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
}
