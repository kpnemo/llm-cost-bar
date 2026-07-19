import Foundation
import GRDB

public enum Database {
    /// Opens (and migrates) the shared on-disk DB in WAL mode.
    public static func open(at url: URL) throws -> DatabasePool {
        var cfg = Configuration()
        cfg.busyMode = .timeout(5)
        let pool = try DatabasePool(path: url.path, configuration: cfg) // DatabasePool => WAL
        try migrator.migrate(pool)
        return pool
    }

    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE usage_daily (
                vendor TEXT NOT NULL, account_id TEXT NOT NULL, api_key_id TEXT NOT NULL,
                model TEXT NOT NULL, day TEXT NOT NULL,
                requests INTEGER NOT NULL DEFAULT 0,
                tokens_in INTEGER NOT NULL DEFAULT 0, tokens_out INTEGER NOT NULL DEFAULT 0,
                cost_usd REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (vendor, account_id, api_key_id, model, day)
            );
            CREATE TABLE balances (
                vendor TEXT NOT NULL, account_id TEXT NOT NULL,
                balance_usd REAL NOT NULL, fetched_at TEXT NOT NULL,
                PRIMARY KEY (vendor, account_id)
            );
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY, vendor TEXT NOT NULL, display_name TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                last_sync_ok TEXT, needs_reauth INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE alert_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL,
                rule TEXT NOT NULL, message TEXT NOT NULL, delivered INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE sync_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL,
                vendor TEXT NOT NULL, account_id TEXT NOT NULL, endpoint TEXT NOT NULL,
                http_status INTEGER, error_class TEXT NOT NULL, message TEXT NOT NULL,
                response_snippet TEXT
            );
            CREATE INDEX idx_usage_day ON usage_daily(day);
            CREATE INDEX idx_synclog_ts ON sync_log(ts DESC);
            """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: """
            CREATE TABLE key_totals (
                vendor TEXT NOT NULL, account_id TEXT NOT NULL, api_key_id TEXT NOT NULL,
                total_usd REAL NOT NULL, fetched_at TEXT NOT NULL,
                PRIMARY KEY (vendor, account_id, api_key_id)
            );
            """)
        }
        m.registerMigration("v3-credit-totals") { db in
            try db.execute(sql: """
            ALTER TABLE balances ADD COLUMN total_credits REAL;
            ALTER TABLE balances ADD COLUMN total_usage REAL;
            """)
        }
        return m
    }
}
