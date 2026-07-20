import Foundation
import GRDB

/// Subscription reads/writes. Same store, separate tables — subscription data is
/// window utilization snapshots, never joined with the dollar tables.
extension UsageStore {
    private static let iso = ISO8601DateFormatter()
    /// Snapshots older than this are useless (sparkline shows 7 days).
    private static let retentionDays = 14.0

    // MARK: writes (daemon)

    /// INSERT OR IGNORE on (source, window_id, observed_at): re-reading the same
    /// JSONL event every poll dedupes on its own timestamp; API polls are distinct.
    public func upsertSubscriptionSnapshot(_ snap: SubscriptionSnapshot, now: Date = Date()) throws {
        try db.write { db in
            let nowISO = Self.iso.string(from: now)
            let observedISO = Self.iso.string(from: snap.observedAt)
            for w in snap.windows {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO subscription_snapshots
                    (source, window_id, observed_at, captured_at, used_percent, resets_at, window_minutes, origin)
                    VALUES (?,?,?,?,?,?,?,?)
                    """, arguments: [snap.source, w.windowID, observedISO, nowISO, w.usedPercent,
                                     w.resetsAt.map(Self.iso.string(from:)), w.windowMinutes, snap.origin])
            }
            try db.execute(sql: """
                UPDATE subscription_sources SET plan_type = COALESCE(?, plan_type),
                    last_ok = ?, stale = 0, stale_reason = NULL WHERE source = ?
                """, arguments: [snap.planType, nowISO, snap.source])
            let cutoff = Self.iso.string(from: now.addingTimeInterval(-Self.retentionDays * 86400))
            try db.execute(sql: "DELETE FROM subscription_snapshots WHERE observed_at < ?",
                           arguments: [cutoff])
        }
    }

    /// INSERT OR IGNORE preserves the user's enabled toggle across re-detection.
    public func registerSubscriptionSource(source: String, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO subscription_sources (source, enabled, detected_at) VALUES (?, 1, ?)
                """, arguments: [source, Self.iso.string(from: now)])
        }
    }

    public func setSubscriptionSourceEnabled(source: String, enabled: Bool) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE subscription_sources SET enabled = ? WHERE source = ?",
                           arguments: [enabled, source])
        }
    }

    public func markSubscriptionStale(source: String, reason: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE subscription_sources SET stale = 1, stale_reason = ? WHERE source = ?",
                           arguments: [reason, source])
        }
    }

    // MARK: alert_events (daemon writes, app delivers)

    public func insertAlertEvent(rule: String, message: String, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO alert_events (ts, rule, message, delivered) VALUES (?,?,?,0)",
                           arguments: [Self.iso.string(from: now), rule, message])
        }
    }

    public func undeliveredAlertEvents() throws -> [AlertEventRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, ts, rule, message FROM alert_events WHERE delivered = 0 ORDER BY id")
                .map { AlertEventRow(id: $0["id"], ts: $0["ts"], rule: $0["rule"], message: $0["message"]) }
        }
    }

    public func markAlertDelivered(id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE alert_events SET delivered = 1 WHERE id = ?", arguments: [id])
        }
    }

    // MARK: reads (app + engine)

    public func subscriptionSources() throws -> [SubscriptionSourceRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source, enabled, plan_type, last_ok, stale, stale_reason
                FROM subscription_sources ORDER BY source
                """)
                .map { SubscriptionSourceRow(source: $0["source"], enabled: $0["enabled"],
                                             planType: $0["plan_type"], lastOK: $0["last_ok"],
                                             stale: $0["stale"], staleReason: $0["stale_reason"]) }
        }
    }

    /// Newest snapshot per (source, window).
    public func latestSubscriptionWindows() throws -> [SubscriptionWindowRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.source, s.window_id, s.observed_at, s.used_percent, s.resets_at, s.window_minutes, s.origin
                FROM subscription_snapshots s
                JOIN (SELECT source, window_id, MAX(observed_at) m
                      FROM subscription_snapshots GROUP BY source, window_id) t
                  ON s.source = t.source AND s.window_id = t.window_id AND s.observed_at = t.m
                ORDER BY s.source, s.window_id
                """)
                .map { SubscriptionWindowRow(source: $0["source"], windowID: $0["window_id"],
                                             observedAt: $0["observed_at"], usedPercent: $0["used_percent"],
                                             resetsAt: $0["resets_at"], windowMinutes: $0["window_minutes"],
                                             origin: $0["origin"]) }
        }
    }

    /// 6-hour buckets over the trailing window; MAX per bucket keeps the sawtooth
    /// peaks visible (utilization resets to 0 mid-bucket would otherwise hide them).
    public func subscriptionSeries(source: String, windowID: String, sinceDaysAgo: Int = 7,
                                   now: Date = Date()) throws -> [SubscriptionPoint] {
        try db.read { db in
            let since = Self.iso.string(from: now.addingTimeInterval(-Double(sinceDaysAgo) * 86400))
            return try Row.fetchAll(db, sql: """
                SELECT (CAST(strftime('%s', observed_at) AS INTEGER) / 21600) * 21600 AS bucket,
                       MAX(used_percent) AS pct
                FROM subscription_snapshots
                WHERE source = ? AND window_id = ? AND observed_at >= ?
                GROUP BY bucket ORDER BY bucket
                """, arguments: [source, windowID, since])
                .map { SubscriptionPoint(bucketStart: Date(timeIntervalSince1970: Double($0["bucket"] as Int64)),
                                         usedPercent: $0["pct"]) }
        }
    }
}
