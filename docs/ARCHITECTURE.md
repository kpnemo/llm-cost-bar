# Architecture

This is the living architecture overview for contributors: the two-process
design, the SQLite schema, and how errors are surfaced. It is extracted from
the full design record at
[`docs/superpowers/specs/2026-07-19-llm-cost-bar-design.md`](superpowers/specs/2026-07-19-llm-cost-bar-design.md),
which also covers goals, phasing, the vendor provider protocol, UI, and the
decisions log — read it for the "why" behind these choices.

## Architecture

Two supervised processes (approach chosen over app-only and cloud-backend alternatives):

```
Vendor APIs (HTTPS, pull)
        │  poll every N min + backfill on wake
        ▼
llmcostd — background daemon (launchd LaunchAgent, KeepAlive)
  • VendorProvider plugins (uniform protocol, one per vendor)
  • Scheduler: poll → normalize → upsert into SQLite
  • AlertEngine (phase 2): evaluates rules, writes alert_events
  • Watchdog: relaunches the menu bar app if it crashed
        │                          │
        ▼                          ▼
  SQLite (WAL)              Keychain + config.json
  usage_daily, balances,    API keys in Keychain only;
  alert_events, sync_log    accounts & rules in config.json
        │                          ▲
        ▼                          │ writes config
LLM Cost Bar — SwiftUI MenuBarExtra app
  reads SQLite · posts notifications for alert_events
```

- **Daemon owns all vendor I/O and history.** The app never calls vendor APIs; it renders SQLite contents. Either process can be rebuilt independently.
- **Supervision both directions:** launchd `KeepAlive` restarts the daemon on crash; the daemon watchdog relaunches the app.
- **Notifications are posted by the app** (macOS requires an app bundle for UNUserNotificationCenter). The daemon records alert events; the app delivers them within seconds.
- Daemon is embedded in the app bundle and registered via `SMAppService` (login item + agent), so install is drag-and-drop.
- App ↔ daemon coupling is through the shared SQLite database and config.json (daemon watches for config changes); no XPC for MVP.

## Data Model (SQLite, WAL mode)

Normalization to **daily granularity** is the core decision: it is the common denominator across all four vendors' billing APIs, makes every view vendor-agnostic SQL (`GROUP BY`), and makes re-polling idempotent (upsert on the natural key) — which is what makes backfill-after-sleep safe.

- `usage_daily(vendor, account_id, api_key_id, model, day, requests, tokens_in, tokens_out, cost_usd)` — PK: (vendor, account_id, api_key_id, model, day). Upsert on conflict.
- `balances(vendor, account_id, balance_usd, fetched_at)` — prepaid vendors (OpenRouter).
- `accounts(id, vendor, display_name, status, last_sync_ok, needs_reauth)` — credentials themselves live in Keychain, keyed by account id. Multiple rows per vendor = multiple accounts.
- `alert_events` — present in schema from day one, unused until phase 2. (Alert *rules* are user configuration and live in config.json, not SQLite.)
- `sync_log(ts, vendor, account_id, endpoint, http_status, error_class, message, response_snippet)` — every sync attempt's outcome, for diagnostics.

## Error Handling & Diagnostics

Requirement from user: errors must be easy to debug. Concretely:

- **Transient vendor failures** (network, 429, 5xx): exponential backoff, keep serving last-known data, card shows "⚠ synced N h ago". Stale beats blank.
- **Auth failures** (401/403): distinct state — account marked `needs_reauth`, card shows a "reconnect" action that reruns pairing. No retry-hammering dead keys.
- **Daemon down:** launchd restarts it; app watches a heartbeat timestamp the daemon writes each cycle and shows "sync paused" if stale.
- **App down:** daemon watchdog relaunches it.
- **Today's partial data:** daily upsert model makes mid-day re-polls overwrite cleanly; no special casing.
- **Nothing silent:** every sync attempt outcome (including endpoint, HTTP status, error class, response snippet) goes to `sync_log`, surfaced in the Diagnostics view. Both processes log structured messages via `os.log` (subsystem `com.mikeb.llmcostbar`) so `log stream` and Console.app work for live debugging.
