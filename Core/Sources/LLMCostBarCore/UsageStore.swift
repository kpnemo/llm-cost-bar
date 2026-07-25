import Foundation
import GRDB

public struct Summary: Equatable, Sendable {
    public var todayUSD: Double
    public var monthUSD: Double
    public var last30USD: Double
    public init(todayUSD: Double, monthUSD: Double, last30USD: Double) {
        self.todayUSD = todayUSD; self.monthUSD = monthUSD; self.last30USD = last30USD
    }
}

public struct KeySpend: Equatable, Hashable, Sendable {
    public var accountID: String
    public var apiKeyID: String
    public var totalUSD: Double   // trailing 30-day dollars, all vendors
    public var todayUSD: Double?  // nil when the vendor has no per-day key data
    public var mtdUSD: Double?
    public var limitUSD: Double? = nil     // key budget; nil = unlimited
    public var limitRemainingUSD: Double? = nil
    public var limitReset: String? = nil   // "daily" / "weekly" / "monthly"
    public var disabled: Bool = false
    public var lifetimeUSD: Double? = nil  // vendor-reported lifetime spend
}

public struct VendorSummary: Equatable, Sendable {
    public var vendor: String
    public var todayUSD: Double
    public var monthUSD: Double
    public var last30USD: Double
    public var balanceUSD: Double?
    public var creditsTotalUSD: Double?
    public var creditsUsedUSD: Double?
    public var topKeys: [KeySpend]
    /// True when any DISPLAYED key row carries limit/lifetime/disabled
    /// metadata — the UI's gate for chevron + inspector interactivity.
    public var hasKeyMetadata: Bool = false
}

public struct DayCost: Equatable, Hashable, Sendable {
    public var day: String
    public var costUSD: Double
    public init(day: String, costUSD: Double) { self.day = day; self.costUSD = costUSD }
}

public struct AccountRow: Equatable, Sendable {
    public var id: String
    public var vendor: String
    public var displayName: String
    public var lastSyncOK: String?
    public var needsReauth: Bool
}

public struct SyncLogRow: Equatable, Sendable {
    /// sync_log.id — always populated when read via recentSyncLog(); optional only so
    /// tests/callers that don't have a DB row id can still construct one.
    public var rowID: Int64?
    public var ts: String
    public var vendor: String
    public var accountID: String
    public var endpoint: String
    public var httpStatus: Int?
    public var errorClass: String
    public var message: String
    public var snippet: String?

    public init(rowID: Int64? = nil, ts: String, vendor: String, accountID: String, endpoint: String,
                httpStatus: Int?, errorClass: String, message: String, snippet: String?) {
        self.rowID = rowID; self.ts = ts; self.vendor = vendor; self.accountID = accountID
        self.endpoint = endpoint; self.httpStatus = httpStatus; self.errorClass = errorClass
        self.message = message; self.snippet = snippet
    }
}

extension SyncLogRow: Identifiable {
    public var id: Int64 { rowID ?? Int64(truncatingIfNeeded: (ts + endpoint + message).hashValue) }
}

/// All reads/writes both processes perform. `DatabaseWriter` covers DatabasePool (disk) and DatabaseQueue (tests).
public final class UsageStore: Sendable {
    let db: any DatabaseWriter   // internal: UsageStore+Subscriptions.swift shares it
    public init(db: any DatabaseWriter) { self.db = db }

    // MARK: writes (daemon + pairing)

    public func upsertUsage(_ records: [UsageRecord]) throws {
        try db.write { db in
            for r in records {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO usage_daily
                    (vendor, account_id, api_key_id, model, day, requests, tokens_in, tokens_out, cost_usd)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """, arguments: [r.vendor, r.accountID, r.apiKeyID, r.model, r.day,
                                     r.requests, r.tokensIn, r.tokensOut, r.costUSD])
            }
        }
    }

    /// First-sync-of-the-day baseline of the vendor's lifetime usage counter.
    /// INSERT OR IGNORE: only the first value of each UTC day sticks. Live "today"
    /// spend = current lifetime usage − this baseline, immune to activity-feed lag.
    public func recordDailyBaseline(vendor: String, accountID: String, day: String, totalUsageUSD: Double) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO usage_snapshots (vendor, account_id, day, baseline_usage_usd)
                VALUES (?,?,?,?)
                """, arguments: [vendor, accountID, day, totalUsageUSD])
        }
    }

    public func upsertKeyTotals(vendor: String, accountID: String, totals: [KeyTotal], now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM key_totals WHERE vendor = ? AND account_id = ?",
                           arguments: [vendor, accountID])
            for t in totals {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO key_totals
                    (vendor, account_id, api_key_id, total_usd, today_usd, mtd_usd,
                     limit_usd, limit_remaining_usd, limit_reset, disabled, lifetime_usd, fetched_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [vendor, accountID, t.apiKeyID, t.totalUSD, t.todayUSD, t.mtdUSD,
                                     t.limitUSD, t.limitRemainingUSD, t.limitReset, t.disabled, t.lifetimeUSD,
                                     ISO8601DateFormatter().string(from: now)])
            }
        }
    }

    public func upsertBalance(vendor: String, accountID: String, balance: Balance, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO balances (vendor, account_id, balance_usd, total_credits, total_usage, fetched_at)
                VALUES (?,?,?,?,?,?)
                """, arguments: [vendor, accountID, balance.balanceUSD, balance.totalCreditsUSD,
                                 balance.totalUsageUSD, ISO8601DateFormatter().string(from: now)])
        }
    }

    public func addAccount(id: String, vendor: String, displayName: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO accounts (id, vendor, display_name) VALUES (?,?,?)",
                           arguments: [id, vendor, displayName])
        }
    }

    public func removeAccount(id: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM usage_daily WHERE account_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM balances WHERE account_id = ?", arguments: [id])
            // Orphans here are user-visible: key_totals pools per vendor across
            // account ids (stale rows would double the per-key list after a
            // remove-and-repair), and usage_snapshots would seed a bogus live
            // "today" delta if the same account id ever came back.
            try db.execute(sql: "DELETE FROM key_totals WHERE account_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM usage_snapshots WHERE account_id = ?", arguments: [id])
        }
    }

    public func markSyncOK(accountID: String, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE accounts SET last_sync_ok = ?, needs_reauth = 0 WHERE id = ?",
                           arguments: [ISO8601DateFormatter().string(from: now), accountID])
        }
    }

    public func setNeedsReauth(accountID: String, value: Bool) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE accounts SET needs_reauth = ? WHERE id = ?",
                           arguments: [value, accountID])
        }
    }

    public func logSync(vendor: String, accountID: String, endpoint: String, httpStatus: Int?,
                        errorClass: String, message: String, snippet: String?, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_log (ts, vendor, account_id, endpoint, http_status, error_class, message, response_snippet)
                VALUES (?,?,?,?,?,?,?,?)
                """, arguments: [ISO8601DateFormatter().string(from: now), vendor, accountID,
                                 endpoint, httpStatus, errorClass, message, snippet])
            // keep the log bounded
            try db.execute(sql: "DELETE FROM sync_log WHERE id NOT IN (SELECT id FROM sync_log ORDER BY id DESC LIMIT 500)")
        }
    }

    // MARK: reads (app)

    public func summary(today: String, monthPrefix: String, last30Start: String) throws -> Summary {
        // Today must equal the sum of the per-vendor cards. Each card takes
        // max(activityToday, liveDelta) for ITS vendor; taking a single max over
        // the pooled sums under-counts whenever one vendor's feed lags (live delta
        // wins) while another's is current (activity wins). So compute per-vendor
        // and sum, rather than a parallel pooled query.
        let vendors = try vendorSummaries(today: today, monthPrefix: monthPrefix, last30Start: last30Start)
        return Summary(todayUSD: vendors.reduce(0) { $0 + $1.todayUSD },
                       monthUSD: vendors.reduce(0) { $0 + $1.monthUSD },
                       last30USD: vendors.reduce(0) { $0 + $1.last30USD })
    }

    /// One account's (current lifetime usage − today's first-sync baseline), clamped ≥ 0.
    private static func liveTodayDelta(_ db: GRDB.Database, vendor: String, accountID: String, today: String) throws -> Double {
        try Double.fetchOne(db, sql: """
            SELECT COALESCE(SUM(MAX(b.total_usage - s.baseline_usage_usd, 0)), 0)
            FROM balances b
            JOIN usage_snapshots s ON s.vendor = b.vendor AND s.account_id = b.account_id AND s.day = ?
            WHERE b.total_usage IS NOT NULL AND b.vendor = ? AND b.account_id = ?
            """, arguments: [today, vendor, accountID]) ?? 0
    }

    /// last30Start is inclusive; pass today−29d so the window plus today spans 30 days.
    public func vendorSummaries(today: String, monthPrefix: String, last30Start: String) throws -> [VendorSummary] {
        try db.read { db in
            // UNION with usage_daily and key_totals so spend whose accounts row is
            // gone (e.g. a mid-poll remove re-created rows) — or whose only data so
            // far is a key_totals snapshot — still shows instead of silently
            // vanishing from Today/MTD.
            let vendors = try String.fetchAll(db, sql: """
                SELECT vendor FROM (
                    SELECT vendor FROM accounts
                    UNION SELECT vendor FROM usage_daily
                    UNION SELECT vendor FROM key_totals
                ) ORDER BY vendor
                """)
            return try vendors.map { vendor in
                // Today = per-ACCOUNT max(activity, live delta), summed. A max over
                // vendor-pooled sums under-counts when one account's feed lags
                // (live delta wins) while another's is current (activity wins) —
                // the same bug summary() had at the vendor level.
                let accountIDs = try String.fetchAll(db, sql: """
                    SELECT id FROM accounts WHERE vendor = ?
                    UNION SELECT DISTINCT account_id FROM usage_daily WHERE vendor = ?
                    """, arguments: [vendor, vendor])
                var t = 0.0
                for accountID in accountIDs {
                    let activityToday = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_daily WHERE vendor = ? AND account_id = ? AND day = ?",
                                                            arguments: [vendor, accountID, today]) ?? 0
                    let liveDelta = try Self.liveTodayDelta(db, vendor: vendor, accountID: accountID, today: today)
                    t += max(activityToday, liveDelta)
                }
                let monthBeforeToday = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_daily WHERE vendor = ? AND day LIKE ? || '%' AND day < ?",
                                                           arguments: [vendor, monthPrefix, today]) ?? 0
                let m = monthBeforeToday + t
                let last30BeforeToday = try Double.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(cost_usd),0) FROM usage_daily
                    WHERE vendor = ? AND day >= ? AND day < ?
                    """, arguments: [vendor, last30Start, today]) ?? 0
                let balRow = try Row.fetchOne(db, sql: """
                    SELECT SUM(balance_usd) AS b, SUM(total_credits) AS tc, SUM(total_usage) AS tu
                    FROM balances WHERE vendor = ?
                    """, arguments: [vendor])
                let bal: Double? = balRow?["b"]
                let credTotal: Double? = balRow?["tc"]
                let credUsed: Double? = balRow?["tu"]
                // total_usd is trailing-30d activity, which excludes today — a
                // brand-new key spending right now has total 0 but today > 0,
                // so visibility must consider every window, not just total.
                let keys = try Row.fetchAll(db, sql: """
                    SELECT account_id, api_key_id, total_usd, today_usd, mtd_usd,
                           limit_usd, limit_remaining_usd, limit_reset, disabled, lifetime_usd
                    FROM key_totals
                    WHERE vendor = ? AND (total_usd > 0 OR COALESCE(today_usd, 0) > 0 OR COALESCE(mtd_usd, 0) > 0)
                    ORDER BY COALESCE(mtd_usd, total_usd) DESC, total_usd DESC, api_key_id ASC LIMIT 5
                    """, arguments: [vendor])
                    .map { KeySpend(accountID: $0["account_id"], apiKeyID: $0["api_key_id"],
                                    totalUSD: $0["total_usd"], todayUSD: $0["today_usd"], mtdUSD: $0["mtd_usd"],
                                    limitUSD: $0["limit_usd"], limitRemainingUSD: $0["limit_remaining_usd"],
                                    limitReset: $0["limit_reset"], disabled: $0["disabled"],
                                    lifetimeUSD: $0["lifetime_usd"]) }
                let hasKeyMetadata = keys.contains { $0.limitUSD != nil || $0.lifetimeUSD != nil || $0.disabled }
                return VendorSummary(vendor: vendor, todayUSD: t, monthUSD: m, last30USD: last30BeforeToday + t,
                                     balanceUSD: bal, creditsTotalUSD: credTotal, creditsUsedUSD: credUsed,
                                     topKeys: keys, hasKeyMetadata: hasKeyMetadata)
            }
        }
    }

    /// Daily cost series for a vendor since `sinceDay` (inclusive), for charts.
    public func dailyCosts(vendor: String, sinceDay: String) throws -> [DayCost] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, COALESCE(SUM(cost_usd),0) AS c FROM usage_daily
                WHERE vendor = ? AND day >= ? GROUP BY day ORDER BY day
                """, arguments: [vendor, sinceDay])
                .map { DayCost(day: $0["day"], costUSD: $0["c"]) }
        }
    }

    public func accounts() throws -> [AccountRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, vendor, display_name, last_sync_ok, needs_reauth FROM accounts ORDER BY vendor, display_name")
                .map { AccountRow(id: $0["id"], vendor: $0["vendor"], displayName: $0["display_name"],
                                  lastSyncOK: $0["last_sync_ok"], needsReauth: $0["needs_reauth"]) }
        }
    }

    public func recentSyncLog(limit: Int) throws -> [SyncLogRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sync_log ORDER BY id DESC LIMIT ?", arguments: [limit])
                .map { SyncLogRow(rowID: $0["id"], ts: $0["ts"], vendor: $0["vendor"], accountID: $0["account_id"],
                                  endpoint: $0["endpoint"], httpStatus: $0["http_status"],
                                  errorClass: $0["error_class"], message: $0["message"],
                                  snippet: $0["response_snippet"]) }
        }
    }
}
