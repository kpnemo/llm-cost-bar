import XCTest
import GRDB
@testable import LLMCostBarCore

final class UsageStoreTests: XCTestCase {
    func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()          // in-memory
        try Database.migrator.migrate(dbq)
        return dbq
    }

    func testMigrationCreatesAllTables() throws {
        let dbq = try makeDB()
        try dbq.read { db in
            for table in ["usage_daily", "balances", "accounts", "alert_events", "sync_log"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
        }
    }
}
