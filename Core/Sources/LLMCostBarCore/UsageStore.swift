import Foundation
import GRDB

public struct Summary: Equatable, Sendable {
    public var todayUSD: Double
    public var monthUSD: Double
    public init(todayUSD: Double, monthUSD: Double) { self.todayUSD = todayUSD; self.monthUSD = monthUSD }
}

public struct KeySpend: Equatable, Hashable, Sendable {
    public var accountID: String
    public var apiKeyID: String
    public var todayUSD: Double
}

public struct VendorSummary: Equatable, Sendable {
    public var vendor: String
    public var todayUSD: Double
    public var monthUSD: Double
    public var balanceUSD: Double?
    public var topKeys: [KeySpend]
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
    private let db: any DatabaseWriter
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

    public func upsertBalance(vendor: String, accountID: String, balanceUSD: Double, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO balances (vendor, account_id, balance_usd, fetched_at)
                VALUES (?,?,?,?)
                """, arguments: [vendor, accountID, balanceUSD, ISO8601DateFormatter().string(from: now)])
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

    public func summary(today: String, monthPrefix: String) throws -> Summary {
        try db.read { db in
            let t = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_daily WHERE day = ?",
                                        arguments: [today]) ?? 0
            let m = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_daily WHERE day LIKE ? || '%'",
                                        arguments: [monthPrefix]) ?? 0
            return Summary(todayUSD: t, monthUSD: m)
        }
    }

    public func vendorSummaries(today: String, monthPrefix: String) throws -> [VendorSummary] {
        try db.read { db in
            let vendors = try String.fetchAll(db, sql: "SELECT DISTINCT vendor FROM accounts ORDER BY vendor")
            return try vendors.map { vendor in
                let t = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_daily WHERE vendor = ? AND day = ?",
                                            arguments: [vendor, today]) ?? 0
                let m = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(cost_usd),0) FROM usage_daily WHERE vendor = ? AND day LIKE ? || '%'",
                                            arguments: [vendor, monthPrefix]) ?? 0
                let bal = try Double.fetchOne(db, sql: "SELECT SUM(balance_usd) FROM balances WHERE vendor = ?",
                                              arguments: [vendor])
                let keys = try Row.fetchAll(db, sql: """
                    SELECT account_id, api_key_id, COALESCE(SUM(cost_usd),0) AS c FROM usage_daily
                    WHERE vendor = ? AND day = ? GROUP BY account_id, api_key_id ORDER BY c DESC LIMIT 5
                    """, arguments: [vendor, today])
                    .map { KeySpend(accountID: $0["account_id"], apiKeyID: $0["api_key_id"], todayUSD: $0["c"]) }
                return VendorSummary(vendor: vendor, todayUSD: t, monthUSD: m, balanceUSD: bal, topKeys: keys)
            }
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
