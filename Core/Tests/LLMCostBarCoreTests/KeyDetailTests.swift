import XCTest
@testable import LLMCostBarCore

final class KeyDetailTests: XCTestCase {
    private func spend(limit: Double? = nil, remaining: Double? = nil, reset: String? = nil,
                       disabled: Bool = false, lifetime: Double? = nil) -> KeySpend {
        KeySpend(accountID: "a", apiKeyID: "k", totalUSD: 1, todayUSD: 0, mtdUSD: 1,
                 limitUSD: limit, limitRemainingUSD: remaining, limitReset: reset,
                 disabled: disabled, lifetimeUSD: lifetime)
    }

    func testCappedKeyWithReset() {
        let d = spend(limit: 20, remaining: 0, reset: "weekly", lifetime: 84.04).detail()
        XCTAssertEqual(d.leading, "limit $20.00 · $0.00 left · resets weekly")
        XCTAssertEqual(d.trailing, "lifetime $84.04")
    }

    func testUnknownRemainingOmitsLeftSegment() {
        let d = spend(limit: 20, remaining: nil, reset: "weekly").detail()
        XCTAssertEqual(d.leading, "limit $20.00 · resets weekly")
    }

    func testNoResetIntervalOmitsResetsSegment() {
        let d = spend(limit: 20, remaining: 12).detail()
        XCTAssertEqual(d.leading, "limit $20.00 · $12.00 left")
    }

    func testNoLimit() {
        let d = spend(lifetime: 2.01).detail()
        XCTAssertEqual(d.leading, "no limit")
        XCTAssertEqual(d.trailing, "lifetime $2.01")
    }

    func testDisabledIsPrefixAndKeepsKnownSegments() {
        let d = spend(limit: 20, remaining: 4, reset: "weekly", disabled: true).detail()
        XCTAssertEqual(d.leading, "disabled · limit $20.00 · $4.00 left · resets weekly")
        let noLimit = spend(disabled: true).detail()
        XCTAssertEqual(noLimit.leading, "disabled · no limit")
    }

    func testMissingLifetimeGivesNilTrailing() {
        XCTAssertNil(spend(limit: 20, remaining: 4).detail().trailing)
    }

    func testSummaryLineCounts() {
        let keys = [
            spend(limit: 20, remaining: 0, reset: "weekly"),
            spend(limit: 20, remaining: 20, reset: "daily"),
            spend(),                       // unlimited
            spend(limit: 20, disabled: true),
        ]
        XCTAssertEqual(KeySpend.summaryLine(for: keys), "4 keys · 3 limited · 1 unlimited · 1 disabled")
        XCTAssertEqual(KeySpend.summaryLine(for: [spend(limit: 5, remaining: 5)]), "1 key · 1 limited")
        XCTAssertEqual(KeySpend.summaryLine(for: [spend(), spend()]), "2 keys · 2 unlimited")
    }
}
