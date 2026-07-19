import XCTest
import GRDB
@testable import LLMCostBarCore

final class FakeProvider: VendorProvider, @unchecked Sendable {
    let vendorID = "openrouter"
    var usage: [UsageRecord] = []
    var balance: Balance? = Balance(balanceUSD: 10)
    var error: ProviderError?
    func validateCredentials() async throws -> AccountInfo { AccountInfo(label: "fake") }
    func fetchUsage(sinceDaysAgo: Int, now: Date) async throws -> [UsageRecord] {
        if let error { throw error }; return usage
    }
    func fetchBalance() async throws -> Balance? {
        if let error { throw error }; return balance
    }
}

final class SyncEngineTests: XCTestCase {
    var store: UsageStore!
    var provider: FakeProvider!
    var engine: SyncEngine!
    var tmpHome: String!

    override func setUpWithError() throws {
        tmpHome = NSTemporaryDirectory() + "sync-test-\(UUID().uuidString)"
        setenv("LLMCOSTBAR_HOME", tmpHome, 1)
        let dbq = try DatabaseQueue()
        try Database.migrator.migrate(dbq)
        store = UsageStore(db: dbq)
        try store.addAccount(id: "acc1", vendor: "openrouter", displayName: "personal")
        provider = FakeProvider()
        engine = SyncEngine(store: store, paths: AppPaths.resolve(),
                            providerFactory: { _, _ in self.provider },
                            credentialLookup: { _ in Credential(apiKey: "k") },
                            sleeper: { _ in })
    }
    override func tearDown() { unsetenv("LLMCOSTBAR_HOME") }

    func testSuccessfulSyncWritesDataAndMarksOK() async throws {
        provider.usage = [UsageRecord(vendor: "openrouter", accountID: "acc1", apiKeyID: "k1",
                                      model: "m", day: Day.utcToday(), requests: 1,
                                      tokensIn: 10, tokensOut: 5, costUSD: 0.5)]
        await engine.syncAll()
        let s = try store.summary(today: Day.utcToday(), monthPrefix: Day.utcMonthPrefix())
        XCTAssertEqual(s.todayUSD, 0.5, accuracy: 0.001)
        XCTAssertNotNil(try store.accounts()[0].lastSyncOK)
        XCTAssertEqual(try store.recentSyncLog(limit: 1).first?.errorClass, "ok")
        // heartbeat written
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.resolve().heartbeat.path))
    }

    func testAuthErrorSetsNeedsReauthAndLogs() async throws {
        provider.error = .auth(401, "invalid key")
        await engine.syncAll()
        XCTAssertTrue(try store.accounts()[0].needsReauth)
        let log = try store.recentSyncLog(limit: 5)
        XCTAssertEqual(log.first?.errorClass, "auth")
        XCTAssertEqual(log.first?.httpStatus, 401)
    }

    func testTransientErrorLogsButKeepsLastSyncNil() async throws {
        provider.error = .transient("timeout")
        await engine.syncAll()
        XCTAssertNil(try store.accounts()[0].lastSyncOK)
        XCTAssertFalse(try store.accounts()[0].needsReauth)   // transient ≠ reauth
        XCTAssertEqual(try store.recentSyncLog(limit: 5).first?.errorClass, "transient")
    }

    func testMissingCredentialLogsAuth() async throws {
        engine = SyncEngine(store: store, paths: AppPaths.resolve(),
                            providerFactory: { _, _ in self.provider },
                            credentialLookup: { _ in nil },
                            sleeper: { _ in })
        await engine.syncAll()
        XCTAssertEqual(try store.recentSyncLog(limit: 5).first?.errorClass, "auth")
        XCTAssertTrue(try store.accounts()[0].needsReauth)
    }
}
