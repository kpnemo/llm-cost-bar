# LLM Cost Bar — Design

**Date:** 2026-07-19
**Status:** Approved design, pre-implementation

## Overview

A macOS menu bar app that aggregates LLM API usage and cost across vendors (OpenRouter, OpenAI, Anthropic, Gemini) into one glanceable place, with configurable alerts. Personal tool, single user, single machine.

## Goals

- One click from the menu bar to see spend across all connected vendors: today, month-to-date, balances, top API keys.
- Breakdown by account and by API key; multiple accounts per vendor supported by design.
- Alerts (post-MVP): daily/monthly budget thresholds, spike detection vs. recent average, low prepaid balance — delivered as macOS notifications.
- Dead-simple pairing UX: click "Add account" → browser opens → approve → done.
- Errors are always visible and debuggable, never silent.
- Open source under MIT: shareable repo with LICENSE, README, architecture docs, and an agent guide (CLAUDE.md) — "AI-ready" for contributors using coding agents.

## Non-Goals

- Subscription products (Claude Max, ChatGPT Plus): API-billed spend only.
- Multi-user, multi-machine sync, or any cloud backend.
- Real-time (sub-minute) cost tracking — vendors expose daily-granularity billing data.

## Phasing

1. **MVP:** installable signed app + daemon; OpenRouter pairing via browser; dropdown showing usage basics (today, MTD, balance, per-key breakdown); Settings (Accounts + General).
2. **Phase 2:** alerts (rules UI + notification delivery), polish.
3. **Phase 3+:** OpenAI, Anthropic, Gemini providers — one at a time. Gemini last (cost data lives in Google Cloud Billing; hardest access model).

Developer signing identity is available on the dev machine; app and daemon are signed and notarizable.

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

## Vendor Provider Protocol

```swift
protocol VendorProvider {
    var vendorID: String { get }                      // "openrouter"
    func validateCredentials(_ creds: Credential) async throws -> AccountInfo
    func fetchUsage(range: DateInterval) async throws -> [UsageRecord]
    func fetchBalance() async throws -> Balance?      // nil if no prepaid balance
}
```

### OpenRouter (MVP)

- Balance: `GET /api/v1/credits`.
- Usage: `GET /api/v1/activity` — daily usage per model/key.
- Key list/names: key-management endpoint.
- **Pairing:** OAuth-style PKCE flow (`openrouter.ai/auth?callback_url=llmcostbar://callback`): app opens the browser, user approves, callback returns a code, app exchanges it for an API key stored in Keychain. No copy-pasting.
- **Open question (verify at implementation start):** whether the PKCE-provisioned key can read account-wide activity and key lists, or whether a provisioning key is required. Fallback either way: "paste an API/provisioning key instead" link in the pairing UI. That paste flow is also the future path for vendors without OAuth (OpenAI/Anthropic admin keys).

## UI

### Menu bar item

Configurable in Settings: icon only / **today's spend (default)** / month-to-date. Icon is a monochrome template image (concept selection in progress via generated SVG candidates; decision does not block implementation — ship with a placeholder glyph until chosen).

### Dropdown panel (chosen: stacked vendor cards)

- Header row: **Today $X** · MTD $Y (all vendors combined).
- One card per connected vendor: vendor name, today's cost, balance + MTD line, top API keys by spend inline.
- Unconnected vendors shown greyed ("not connected").
- Footer: ⚙ Settings · last-sync indicator ("↻ 2 min ago", turns into "⚠ synced 3 h ago" on sync trouble).
- Scales by scrolling as vendors grow; a tabbed drill-down (by key / by account) can be layered on later over the same SQL.

### Settings window

- **Accounts tab (default):** list of connected accounts (name, key count, last sync, Remove), "＋ Add account…" → vendor picker (OpenRouter enabled; others greyed "coming soon") → pairing flow: name the account → browser approval → `llmcostbar://callback` → Keychain → immediate first sync → "✓ Connected".
- **General tab:** menu bar display mode; refresh interval 5/15 (default)/30/60 min; launch at login (default on, via SMAppService).
- **Alerts tab:** visible but disabled until phase 2.
- **Diagnostics view:** recent `sync_log` entries rendered readably + "Copy diagnostics" button.

## Error Handling & Diagnostics

Requirement from user: errors must be easy to debug. Concretely:

- **Transient vendor failures** (network, 429, 5xx): exponential backoff, keep serving last-known data, card shows "⚠ synced N h ago". Stale beats blank.
- **Auth failures** (401/403): distinct state — account marked `needs_reauth`, card shows a "reconnect" action that reruns pairing. No retry-hammering dead keys.
- **Daemon down:** launchd restarts it; app watches a heartbeat timestamp the daemon writes each cycle and shows "sync paused" if stale.
- **App down:** daemon watchdog relaunches it.
- **Today's partial data:** daily upsert model makes mid-day re-polls overwrite cleanly; no special casing.
- **Nothing silent:** every sync attempt outcome (including endpoint, HTTP status, error class, response snippet) goes to `sync_log`, surfaced in the Diagnostics view. Both processes log structured messages via `os.log` (subsystem `com.mikeb.llmcostbar`) so `log stream` and Console.app work for live debugging.

## Testing

- **Providers:** unit tests against recorded JSON fixtures — response parsing and normalization to `UsageRecord`.
- **Scheduler:** upsert/backfill logic tested with a fake provider and in-memory SQLite.
- **AlertEngine (phase 2):** pure-logic tests over seeded SQLite data.
- **UI:** kept thin (renders SQL results); manual testing for MVP, no UI automation rig.

## Security

- API keys only in macOS Keychain; never in config.json, SQLite, or logs (`sync_log` snippets must be scrubbed of Authorization headers).
- All vendor traffic HTTPS; no third-party servers involved.

## Decisions Log

| Decision | Choice |
|---|---|
| Scope | API spend only (no subscriptions) |
| Accounts | One per vendor today, schema supports many |
| Stack | Native Swift/SwiftUI, MenuBarExtra |
| Architecture | Daemon + app (B), supervised both directions |
| First vendor | OpenRouter |
| Menu bar display | Configurable; default = today's spend |
| Dropdown layout | Stacked vendor cards |
| Alerts | Threshold + spike + low balance; phase 2 |

## Open Items

- OpenRouter PKCE key scope vs. provisioning key (verify first; fallback designed).
- Menu bar icon: pick from generated monochrome SVG concepts (in progress); placeholder glyph until then.
