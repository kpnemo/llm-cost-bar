import XCTest
import AppKit
import Observation
import GRDB
import LLMCostBarCore

@MainActor
final class StoreModelTests: XCTestCase {
    private func fixture() throws -> (StoreModel, DatabaseQueue, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let store = UsageStore(db: db)
        try store.addAccount(id: "test", vendor: "openai", displayName: "Test")
        let model = StoreModel(store: store, paths: AppPaths(base: directory), startPolling: false)
        return (model, db, directory)
    }

    func testUnchangedRefreshDoesNotInvalidateDashboard() async throws {
        let (model, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.refresh().value
        let changed = expectation(description: "unchanged dashboard should not be invalidated")
        changed.isInverted = true
        withObservationTracking {
            _ = model.summary
            _ = model.vendors
            _ = model.charts
            _ = model.subscriptionWindows
        } onChange: { changed.fulfill() }
        await model.refresh().value
        await fulfillment(of: [changed], timeout: 0.03)
    }

    func testBlockedDatabaseDoesNotBlockMainActorAndCannotUndoConfigEdit() async throws {
        let (model, db, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.refresh().value
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                try! db.write { _ in
                    entered.resume()
                    _ = release.wait(timeout: .now() + 1)
                }
            }
        }
        let began = ProcessInfo.processInfo.systemUptime
        let refresh = model.refresh()
        // MainActor must be free while the worker waits for the database queue.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
        model.config.defaultTab = .subscriptions
        let saved = model.saveConfig()
        release.signal()
        await refresh.value
        await saved?.value
        XCTAssertEqual(model.config.defaultTab, .subscriptions)
        XCTAssertEqual(AppConfig.load(from: model.paths.config).defaultTab, .subscriptions)
    }

    func testRapidConfigEditsPersistLatestValue() async throws {
        let (model, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.config.menuBarDisplay = .today
        model.saveConfig()
        model.config.menuBarDisplay = .last30Days
        model.saveConfig()
        model.config.menuBarDisplay = .today
        await model.saveConfig()?.value
        await model.refresh().value
        XCTAssertEqual(model.config.menuBarDisplay, .today)
        XCTAssertEqual(AppConfig.load(from: model.paths.config).menuBarDisplay, .today)
    }

    func testDaemonHealthExpiresEvenWhenHeartbeatFileStopsChanging() throws {
        let (model, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        model.lastHeartbeat = now
        model.statusDate = now
        XCTAssertTrue(model.daemonHealthy)
        model.statusDate = now.addingTimeInterval(61)
        XCTAssertFalse(model.daemonHealthy)
    }

    func testCachedPopupStillRequestsADrawingMeasurementOnReopen() {
        let monitor = PerformanceMonitor()
        // A detached NSView can discard display requests because it has no
        // drawable window; observe the request without creating a test window.
        let probe = RedrawSpy()
        monitor.registerPopup(probe)
        probe.needsDisplay = false
        monitor.popupAppeared()
        XCTAssertTrue(probe.needsDisplay)
        monitor.popupClosed()
    }

    func testFailedRefreshKeepsLastGoodScreen() async throws {
        let (model, db, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.refresh().value
        let accounts = model.accounts
        XCTAssertEqual(accounts.count, 1)
        try await db.write { try $0.execute(sql: "DROP TABLE subscription_snapshots") }
        await model.refresh().value
        XCTAssertEqual(model.accounts, accounts)
    }
}

@MainActor
private final class RedrawSpy: NSView {
    private var requested = false
    override var needsDisplay: Bool {
        get { requested }
        set { requested = newValue }
    }
}
