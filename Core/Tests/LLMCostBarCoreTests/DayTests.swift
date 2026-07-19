import XCTest
@testable import LLMCostBarCore

final class DayTests: XCTestCase {
    private func utcDate(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testUTCDayBoundaryAssignsToCorrectDay() {
        // Vendors report UTC days; the app must bucket the same way regardless of local TZ.
        XCTAssertEqual(Day.utcToday(now: utcDate("2026-07-19T23:59:59Z")), "2026-07-19")
        XCTAssertEqual(Day.utcToday(now: utcDate("2026-07-20T00:00:01Z")), "2026-07-20")
    }

    func testMonthPrefixBoundary() {
        XCTAssertEqual(Day.utcMonthPrefix(now: utcDate("2026-07-31T23:59:59Z")), "2026-07")
        XCTAssertEqual(Day.utcMonthPrefix(now: utcDate("2026-08-01T00:00:01Z")), "2026-08")
    }

    func testTodayAndMonthAreConsistent() {
        // monthPrefix must always be the 7-char prefix of that same instant's day,
        // otherwise summary() and vendorSummaries() would disagree on what "this month" is.
        for iso in ["2026-01-01T00:00:00Z", "2026-07-19T12:34:56Z", "2026-12-31T23:59:59Z"] {
            let d = utcDate(iso)
            XCTAssertTrue(Day.utcToday(now: d).hasPrefix(Day.utcMonthPrefix(now: d)), "\(iso) day/month mismatch")
        }
    }
}
