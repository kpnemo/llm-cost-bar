import XCTest
import GRDB
@testable import LLMCostBarCore

/// Scriptable provider: each fetch pops the next result (snapshot or error).
final class FakeSubscriptionProvider: SubscriptionProvider, @unchecked Sendable {
    let sourceID: String
    var detected = true
    var results: [Result<SubscriptionSnapshot, ProviderError>] = []
    var fetchCount = 0
    init(sourceID: String) { self.sourceID = sourceID }
    func isDetected() -> Bool { detected }
    func fetchSnapshot(now: Date) async throws -> SubscriptionSnapshot {
        fetchCount += 1
        guard !results.isEmpty else { throw ProviderError.transient("script exhausted") }
        return try results.removeFirst().get()
    }
}

final class SubscriptionSyncEngineTests: XCTestCase {
    let iso = ISO8601DateFormatter()
    var t0: Date { iso.date(from: "2026-07-20T10:00:00Z")! }

    func makeStore() throws -> UsageStore {
        let dbq = try DatabaseQueue()
        try Database.migrator.migrate(dbq)
        return UsageStore(db: dbq)
    }

    func snap(pct: Double, source: String = "claude", window: String = "seven_day",
              observed: Date) -> SubscriptionSnapshot {
        SubscriptionSnapshot(source: source, planType: "max_5x", observedAt: observed, origin: "api",
                             windows: [SubscriptionWindow(windowID: window, usedPercent: pct)])
    }

    func makeEngine(_ store: UsageStore, _ provider: FakeSubscriptionProvider,
                    threshold: Int = 80) -> SubscriptionSyncEngine {
        SubscriptionSyncEngine(store: store, providers: [provider],
                               alertThreshold: { threshold }, sleeper: { _ in })
    }

    func testSuccessWritesSnapshotAndSyncLog() async throws {
        let store = try makeStore()
        let p = FakeSubscriptionProvider(sourceID: "claude")
        p.results = [.success(snap(pct: 42, observed: t0))]
        await makeEngine(store, p).syncAll(now: t0)
        XCTAssertEqual(try store.latestSubscriptionWindows().first?.usedPercent, 42)
        let logRow = try store.recentSyncLog(limit: 1).first
        XCTAssertEqual(logRow?.vendor, "claude-sub")
        XCTAssertEqual(logRow?.errorClass, "ok")
        XCTAssertEqual(try store.subscriptionSources().first?.stale, false)
    }

    func testAuthMarksStaleWithoutTouchingAccounts() async throws {
        let store = try makeStore()
        try store.addAccount(id: "acc1", vendor: "anthropic", displayName: "api")
        let p = FakeSubscriptionProvider(sourceID: "claude")
        p.results = [.failure(.auth(401, "open Claude Code to refresh sign-in"))]
        await makeEngine(store, p).syncAll(now: t0)
        let source = try store.subscriptionSources().first
        XCTAssertEqual(source?.stale, true)
        XCTAssertEqual(source?.staleReason, "open Claude Code to refresh sign-in")
        XCTAssertEqual(try store.accounts().first?.needsReauth, false)   // never coupled
        XCTAssertEqual(try store.recentSyncLog(limit: 1).first?.errorClass, "auth")
    }

    func testTransientIsRetriedThenLogged() async throws {
        let store = try makeStore()
        let p = FakeSubscriptionProvider(sourceID: "codex")
        p.results = [.failure(.transient("net")), .failure(.transient("net")),
                     .success(snap(pct: 10, source: "codex", window: "primary", observed: t0))]
        await makeEngine(store, p).syncAll(now: t0)
        XCTAssertEqual(p.fetchCount, 3)   // withRetry default attempts
        XCTAssertEqual(try store.latestSubscriptionWindows().first?.usedPercent, 10)
    }

    func testDisabledAndUndetectedAreSkipped() async throws {
        let store = try makeStore()
        let disabled = FakeSubscriptionProvider(sourceID: "claude")
        disabled.results = [.success(snap(pct: 42, observed: t0))]
        try store.registerSubscriptionSource(source: "claude", now: t0)
        try store.setSubscriptionSourceEnabled(source: "claude", enabled: false)
        let undetected = FakeSubscriptionProvider(sourceID: "codex")
        undetected.detected = false
        let engine = SubscriptionSyncEngine(store: store, providers: [disabled, undetected],
                                            alertThreshold: { 80 }, sleeper: { _ in })
        await engine.syncAll(now: t0)
        XCTAssertEqual(disabled.fetchCount, 0)
        XCTAssertEqual(undetected.fetchCount, 0)
        XCTAssertEqual(try store.subscriptionSources().count, 1)   // undetected never registered
        XCTAssertTrue(try store.latestSubscriptionWindows().isEmpty)
    }

    func testThresholdAlertFiresOnCrossingOnly() async throws {
        let store = try makeStore()
        let p = FakeSubscriptionProvider(sourceID: "claude")
        p.results = [
            .success(snap(pct: 79, observed: t0)),
            .success(snap(pct: 85, observed: t0.addingTimeInterval(300))),   // 79→85: fires
            .success(snap(pct: 90, observed: t0.addingTimeInterval(600))),   // 85→90: silent
        ]
        let engine = makeEngine(store, p)
        await engine.syncAll(now: t0)
        await engine.syncAll(now: t0.addingTimeInterval(300))
        await engine.syncAll(now: t0.addingTimeInterval(600))
        let alerts = try store.undeliveredAlertEvents()
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].rule, "sub-threshold:claude:seven_day")
        XCTAssertTrue(alerts[0].message.contains("85%"))
    }

    func testAlertRearmsAfterWindowReset() async throws {
        let store = try makeStore()
        let p = FakeSubscriptionProvider(sourceID: "claude")
        p.results = [
            .success(snap(pct: 90, observed: t0)),                            // first sight hot: fires
            .success(snap(pct: 20, observed: t0.addingTimeInterval(300))),    // reset: re-arms
            .success(snap(pct: 85, observed: t0.addingTimeInterval(600))),    // crosses again: fires
        ]
        let engine = makeEngine(store, p)
        for dt in [0.0, 300, 600] { await engine.syncAll(now: t0.addingTimeInterval(dt)) }
        XCTAssertEqual(try store.undeliveredAlertEvents().count, 2)
    }
}
