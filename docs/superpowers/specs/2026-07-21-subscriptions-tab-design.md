# Subscriptions tab — Claude Pro/Max + Codex/ChatGPT usage & limits

**Date:** 2026-07-21
**Status:** approved (brainstormed with visual mockups; supersedes the
"API spend only / no subscriptions" non-goal in
`2026-07-19-llm-cost-bar-design.md` — that scope line is deliberately revised
by this spec, the same way the OpenRouter addendum revised per-key scope.)

## Problem

Subscribers to Claude Pro/Max and ChatGPT Plus/Pro don't care about API keys —
they care about rolling limit windows (Claude: 5-hour session + 7-day +
per-model weekly; Codex: weekly primary + shorter secondary), reset times, and
how close they are to the cap. Both vendors' CLIs (Claude Code, Codex) are
installed locally and already hold the credentials/data needed to show this.

## Decisions

- **Scope v1:** Claude + Codex subscription sources. Popover only; the menu
  bar title stays dollar-spend.
- **UI:** segmented control "API Spend | Subscriptions" atop the 440 px
  popover. Per-source card: name + plan badge ("Max 5×" / "ChatGPT Plus") +
  freshness stamp; one labeled bar per window, tinted green <60 / yellow
  60–85 / red >85, captioned "X% — resets Tue 14:00 · in 2d 3h"; red alert
  strip on the card when any window ≥ threshold; 7-day sparkline of the
  weekly window (6-hour MAX buckets).
- **Settings:** General → "Popover opens to" (default API Spend) and
  "Subscription alert at" (70/80/90/95 % used, default 80). Accounts →
  "Subscriptions (auto-detected)" with enable toggles (default on); no
  add/remove — detection is the daemon's job.
- **Alerts:** daemon detects threshold crossings (edge-triggered; a
  below-threshold snapshot re-arms; first sight of a hot window fires once)
  and writes `alert_events`; the app's 30 s refresh pump posts
  `UNUserNotification`s and marks them delivered. llmcostd is a bare tool —
  it cannot request notification permission itself.
- **Architecture:** separate `SubscriptionProvider` protocol +
  `SubscriptionSyncEngine`, NOT bolted onto the dollar-denominated
  `VendorProvider`/`SyncEngine` (those are keyed off accounts rows and
  per-account Keychain credentials; subscriptions have neither, and a dead
  borrowed CLI token must never trip `needs_reauth`).

## Data sources (undocumented endpoints — verify against current binaries)

- **Claude:** read-only Keychain read of Claude Code's item
  `Claude Code-credentials` (JSON key `claudeAiOauth.accessToken`; detection
  is an attributes-only query so it never prompts; file fallback
  `~/.claude/.credentials.json`). Then
  `GET https://api.anthropic.com/api/oauth/usage` with
  `anthropic-beta: oauth-2025-04-20` and `User-Agent: claude-code/<ver>`
  (load-bearing: other UAs hit an aggressive 429 bucket). **Never refresh or
  rotate the token** — rotating could log the user out of Claude Code. 401 or
  Keychain denial → source marked stale with an actionable reason.
- **Codex:** `~/.codex/auth.json` (may be absent in keyring mode) →
  `GET https://chatgpt.com/backend-api/wham/usage` with
  `ChatGPT-Account-Id` header. Fallback on any API failure: newest
  `rate_limits` event in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
  (bounded scan, tail-read; origin-tagged `jsonl` so the UI shows its age).
- All fetch attempts land in `sync_log` as vendor `claude-sub` / `codex-sub`,
  account `-`.

## Schema (migration v6)

- `subscription_sources(source PK, enabled, plan_type, detected_at, last_ok,
  stale, stale_reason)` — registration preserves the user's toggle.
- `subscription_snapshots(source, window_id, observed_at, captured_at,
  used_percent, resets_at, window_minutes, origin,
  PK(source, window_id, observed_at))` — INSERT OR IGNORE makes JSONL
  re-parses idempotent; 14-day retention pruned on write.

## Attribution

Keychain-read, endpoint, and defensive-decoding approach adapted from
**steipete/CodexBar** (MIT, © 2026 Peter Steinberger) —
https://github.com/steipete/CodexBar. This project deviates deliberately in
one place: bars are tinted by utilization (green/yellow/red), not brand color.

## Verification

`cd Core && swift test` (113 tests incl. provider fixtures, engine
edge-trigger cases, store bucketing/retention, AppConfig regression);
`xcodegen generate && xcodebuild -scheme LLMCostBar build`. Manual smoke:
first Claude poll shows the macOS consent prompt once (Always Allow), tab
matches `claude /usage` / `codex /status`, renaming `~/.codex/auth.json`
falls back to JSONL marked "from CLI session".
