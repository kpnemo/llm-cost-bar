import XCTest
@testable import LLMCostBarCore

final class AppConfigTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        var cfg = AppConfig.load(from: url)              // missing file → defaults
        XCTAssertEqual(cfg.refreshMinutes, 15)
        XCTAssertEqual(cfg.menuBarDisplay, .today)
        XCTAssertTrue(cfg.keepAppAlive)
        cfg.refreshMinutes = 30
        cfg.menuBarDisplay = .monthToDate
        try cfg.save(to: url)
        XCTAssertEqual(AppConfig.load(from: url).refreshMinutes, 30)
        XCTAssertEqual(AppConfig.load(from: url).menuBarDisplay, .monthToDate)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try "not json".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(AppConfig.load(from: url).refreshMinutes, 15)
    }
}
