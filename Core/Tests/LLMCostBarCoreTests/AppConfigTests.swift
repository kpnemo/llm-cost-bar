import XCTest
@testable import LLMCostBarCore

final class AppConfigTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        var cfg = AppConfig.load(from: url)              // missing file → defaults
        XCTAssertEqual(cfg.refreshMinutes, 15)
        XCTAssertEqual(cfg.menuBarDisplay, .monthToDate)
        XCTAssertTrue(cfg.keepAppAlive)
        cfg.refreshMinutes = 30
        cfg.menuBarDisplay = .today
        try cfg.save(to: url)
        XCTAssertEqual(AppConfig.load(from: url).refreshMinutes, 30)
        XCTAssertEqual(AppConfig.load(from: url).menuBarDisplay, .today)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try "not json".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(AppConfig.load(from: url).refreshMinutes, 15)
    }

    /// Regression: a config.json written before the subscription fields existed
    /// must keep the user's prefs and pick up defaults for the new fields —
    /// synthesized Codable would throw keyNotFound and reset everything.
    func testOldConfigPreservesPrefsAndGetsNewDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try #"{"keepAppAlive":false,"menuBarDisplay":"today","refreshMinutes":45}"#
            .data(using: .utf8)!.write(to: url)
        let cfg = AppConfig.load(from: url)
        XCTAssertEqual(cfg.refreshMinutes, 45)
        XCTAssertEqual(cfg.menuBarDisplay, .today)
        XCTAssertFalse(cfg.keepAppAlive)
        XCTAssertEqual(cfg.defaultTab, .apiSpend)
        XCTAssertEqual(cfg.subscriptionAlertThreshold, 80)
    }

    func testSubscriptionFieldsRoundTrip() throws {
        var cfg = AppConfig()
        cfg.defaultTab = .subscriptions
        cfg.subscriptionAlertThreshold = 70
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try cfg.save(to: url)
        let loaded = AppConfig.load(from: url)
        XCTAssertEqual(loaded.defaultTab, .subscriptions)
        XCTAssertEqual(loaded.subscriptionAlertThreshold, 70)
    }

    func testUnknownEnumValueFallsBackPerField() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try #"{"refreshMinutes":45,"menuBarDisplay":"hologram"}"#
            .data(using: .utf8)!.write(to: url)
        let cfg = AppConfig.load(from: url)
        XCTAssertEqual(cfg.refreshMinutes, 45)              // survives the bad sibling
        XCTAssertEqual(cfg.menuBarDisplay, .monthToDate)    // bad value → its default only
    }

    func testLast30DaysDisplayRoundTrips() throws {
        var cfg = AppConfig()
        cfg.menuBarDisplay = .last30Days
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try cfg.save(to: url)
        XCTAssertEqual(AppConfig.load(from: url).menuBarDisplay, .last30Days)
    }
}
