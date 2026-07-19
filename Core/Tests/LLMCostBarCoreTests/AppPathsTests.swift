import XCTest
@testable import LLMCostBarCore

final class AppPathsTests: XCTestCase {
    func testEnvOverrideControlsBaseDirectory() throws {
        let tmp = NSTemporaryDirectory() + "llmcostbar-test-\(UUID().uuidString)"
        setenv("LLMCOSTBAR_HOME", tmp, 1)
        defer { unsetenv("LLMCOSTBAR_HOME") }
        let paths = AppPaths.resolve()
        XCTAssertEqual(paths.base.path, tmp)
        XCTAssertEqual(paths.database.lastPathComponent, "db.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp)) // resolve() creates it
    }
}
