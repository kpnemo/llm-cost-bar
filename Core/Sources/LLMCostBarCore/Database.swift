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
        m.registerMigration("v4-usage-snapshots") { db in
            try db.execute(sql: """
            CREATE TABLE usage_snapshots (
                vendor TEXT NOT NULL, account_id TEXT NOT NULL, day TEXT NOT NULL,
                baseline_usage_usd REAL NOT NULL,
                PRIMARY KEY (vendor, account_id, day)
            );
            """)
        }
        m.registerMigration("v5-key-daily") { db in
            try db.execute(sql: """
            ALTER TABLE key_totals ADD COLUMN today_usd REAL;
            ALTER TABLE key_totals ADD COLUMN mtd_usd REAL;
            """)
        }
        m.registerMigration("v6-subscriptions") { db in
            try db.execute(sql: """
            CREATE TABLE subscription_sources (
                source TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL DEFAULT 1,
                plan_type TEXT,
                detected_at TEXT NOT NULL,
                last_ok TEXT,
                stale INTEGER NOT NULL DEFAULT 0,
                stale_reason TEXT
            );
            CREATE TABLE subscription_snapshots (
                source TEXT NOT NULL, window_id TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                captured_at TEXT NOT NULL,
                used_percent REAL NOT NULL,
                resets_at TEXT, window_minutes INTEGER,
                origin TEXT NOT NULL,
                PRIMARY KEY (source, window_id, observed_at)
            );
            CREATE INDEX idx_sub_snapshots_lookup
                ON subscription_snapshots(source, window_id, observed_at DESC);
            """)
        }
        m.registerMigration("v7-subscription-credit") { db in
            try db.execute(sql: """
            CREATE TABLE subscription_credit (
                source TEXT PRIMARY KEY,
                spent_minor INTEGER NOT NULL DEFAULT 0,
                limit_minor INTEGER NOT NULL DEFAULT 0,
                currency TEXT NOT NULL DEFAULT 'USD',
                resets_at TEXT,
                free_credits_minor INTEGER NOT NULL DEFAULT 0,
                observed_at TEXT NOT NULL
            );
            """)
        }
        m.registerMigration("v8-key-limits") { db in
            try db.execute(sql: """
            ALTER TABLE key_totals ADD COLUMN limit_usd REAL;
            ALTER TABLE key_totals ADD COLUMN limit_remaining_usd REAL;
            ALTER TABLE key_totals ADD COLUMN limit_reset TEXT;
            ALTER TABLE key_totals ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0;
            """)
        }
        m.registerMigration("v9-key-lifetime") { db in
            try db.execute(sql: "ALTER TABLE key_totals ADD COLUMN lifetime_usd REAL;")
        }
        return m
    }
}
