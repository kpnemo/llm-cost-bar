import Foundation
import os

/// One subscription poll over all detected sources. Parallel to SyncEngine but
/// never touches accounts/needs_reauth: a dead borrowed CLI credential is the
/// source's stale state, not an account reauth flow.
public final class SubscriptionSyncEngine: @unchecked Sendable {
    private let store: UsageStore
    private let providers: [any SubscriptionProvider]
    private let alertThreshold: @Sendable () -> Int
    private let sleeper: @Sendable (Double) async -> Void
    private let log = Logger(subsystem: AppIDs.subsystem, category: "sub-sync")

    public init(store: UsageStore, providers: [any SubscriptionProvider],
                alertThreshold: @escaping @Sendable () -> Int = { 80 },
                sleeper: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.store = store; self.providers = providers
        self.alertThreshold = alertThreshold; self.sleeper = sleeper
    }

    public func syncAll(now: Date = Date()) async {
        for provider in providers {
            guard provider.isDetected() else { continue }   // silent: not installed is not an error
            try? store.registerSubscriptionSource(source: provider.sourceID, now: now)
            let enabled = (try? store.subscriptionSources())?
                .first { $0.source == provider.sourceID }?.enabled ?? false
            guard enabled else { continue }
            await sync(provider, now: now)
        }
    }

    private func sync(_ provider: any SubscriptionProvider, now: Date) async {
        let vendor = "\(provider.sourceID)-sub"
        // Previous latest per window, read before the write: threshold alerts are
        // edge-triggered on the transition, and a below-threshold snapshot re-arms.
        let previous = ((try? store.latestSubscriptionWindows()) ?? [])
            .filter { $0.source == provider.sourceID }
        do {
            let snap = try await withRetry(sleeper: sleeper) { try await provider.fetchSnapshot(now: now) }
            try store.upsertSubscriptionSnapshot(snap, now: now)
            try store.logSync(vendor: vendor, accountID: "-", endpoint: "subscription",
                              httpStatus: 200, errorClass: "ok",
                              message: "\(snap.windows.count) windows (\(snap.origin))", snippet: nil)
            emitThresholdAlerts(source: provider.sourceID, snap: snap, previous: previous, now: now)
            log.info("subscription \(provider.sourceID, privacy: .public): \(snap.windows.count) windows via \(snap.origin, privacy: .public)")
        } catch let e as ProviderError {
            handle(e, vendor: vendor, source: provider.sourceID)
        } catch {
            handle(.transient(String(String(describing: error).prefix(300))), vendor: vendor, source: provider.sourceID)
        }
    }

    private func emitThresholdAlerts(source: String, snap: SubscriptionSnapshot,
                                     previous: [SubscriptionWindowRow], now: Date) {
        let threshold = Double(alertThreshold())
        for w in snap.windows where w.usedPercent >= threshold {
            let prev = previous.first { $0.windowID == w.windowID }?.usedPercent
            // Fire on the crossing only — prev already over threshold means the
            // notification for this climb was sent. First sight of a hot window
            // (prev == nil) alerts too: that's exactly when the user wants to know.
            guard prev == nil || prev! < threshold else { continue }
            let name = source == SubscriptionSource.claude ? "Claude" : "Codex"
            try? store.insertAlertEvent(
                rule: "sub-threshold:\(source):\(w.windowID)",
                message: "\(name) \(w.label) window at \(Int(w.usedPercent))% of limit",
                now: now)
        }
    }

    private func handle(_ e: ProviderError, vendor: String, source: String) {
        var status: Int? = nil
        var message = ""
        var snippet: String? = nil
        switch e {
        case .transient(let m): message = m
        case .auth(let s, let reason):
            status = s == 0 ? nil : s; message = "auth failure"; snippet = reason
            try? store.markSubscriptionStale(source: source,
                                             reason: reason.isEmpty ? "sign-in required" : reason)
        case .http(let s, let snip): status = s; message = "unexpected status"; snippet = snip
        case .decode(let m): message = m
        }
        log.error("subscription \(source, privacy: .public) failed [\(e.errorClass, privacy: .public)]: \(message, privacy: .public)")
        try? store.logSync(vendor: vendor, accountID: "-", endpoint: "subscription",
                           httpStatus: status, errorClass: e.errorClass, message: message, snippet: snippet)
    }
}
