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

    func testLast30DaysDisplayRoundTrips() throws {
        var cfg = AppConfig()
        cfg.menuBarDisplay = .last30Days
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try cfg.save(to: url)
        XCTAssertEqual(AppConfig.load(from: url).menuBarDisplay, .last30Days)
    }
}
