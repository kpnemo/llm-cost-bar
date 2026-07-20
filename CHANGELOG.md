# Changelog

All notable changes to LLM Cost Bar are documented here. Each GitHub release
carries its version's section as release notes.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [1.3.4] - 2026-07-21

### Changed
- All vendor API keys now share a **single Keychain item**, so macOS asks for
  Keychain permission at most twice ever: once for your keys (no matter how
  many providers you add) and once, read-only, for Claude Code's sign-in if
  you use Subscriptions. Existing keys are carried over automatically — you
  may see one final "Always Allow" prompt after this update.
- Settings → Accounts now explains the Keychain prompts up front.

## [1.3.3] - 2026-07-21

### Fixed
- After an update (or app launch), the popover footer briefly showed a false
  "sync paused" warning while the background service was still starting; it
  now shows a calm "syncing…" during that window.
- The popover now refreshes every 5 seconds while open, so the sync status
  and amounts update live instead of requiring a close/reopen.

## [1.3.2] - 2026-07-21

### Added
- The popover footer shows the current app version.

## [1.3.1] - 2026-07-21

### Changed
- Vendor cards in the popover now start **collapsed** and remember which ones
  you expand — the choice persists across popover opens and app restarts.

## [1.3.0] - 2026-07-21

### Added
- **Self-update** — the app now checks GitHub Releases for new versions
  (quietly once a day, or on demand via Settings → General → Check for
  Updates…) and shows an unobtrusive "Update available" row in the popover.
  One click downloads the new version, verifies its Developer ID signature
  (pinned to this app's release team), swaps it into place, restarts the
  background service, and relaunches — no manual download needed again.
- Settings → General gains an **Updates** section: current version,
  automatic-check toggle, manual check button, and last-check status.

## [1.2.0] - 2026-07-21

### Added
- **Subscriptions tab** — the popover now has an "API Spend | Subscriptions"
  switcher showing subscription usage and limits for **Claude Pro/Max**
  (5-hour session, 7-day, and per-model weekly windows) and **Codex /
  ChatGPT** (weekly + secondary rate-limit windows): color-coded bars,
  reset countdowns, plan badge, and a 7-day burn-rate sparkline per tool.
- Zero-setup detection: signed-in Claude Code and Codex CLI installs are
  found automatically (Claude via a **read-only** Keychain read of Claude
  Code's own sign-in — approve the one-time "Always Allow" prompt; Codex via
  its local files, with a live-API primary path). Enable/disable per tool in
  Settings → Accounts.
- Near-limit **notifications**: a macOS alert fires when any window crosses
  the configurable threshold (Settings → General, default 80% used),
  re-arming after the window resets.
- New Settings: "Popover opens to" (API Spend or Subscriptions) and
  "Subscription alert at" (70/80/90/95%).
- Approach for reading CLI credentials/endpoints adapted from
  [CodexBar](https://github.com/steipete/CodexBar) (MIT) — thanks
  @steipete.

### Fixed
- Adding new preferences no longer risks resetting existing ones: config
  decoding is now per-field tolerant (an old `config.json` keeps every
  user-set value and picks up defaults for new fields only).

## [1.1.0] - 2026-07-21

### Added
- Per-API-key spend now shows **three columns — today | MTD | 30d** — for all
  vendors, color-coded (blue / white / gray) and aligned under matching totals
  in each vendor card header.
- Vendor card headers show all three totals (today, month-to-date, trailing
  30 days) in both collapsed and expanded states.
- **OpenRouter per-key daily data**: real per-key dollars via the
  `api_key_hash` activity filter — OpenRouter's key list now matches the
  other vendors instead of showing a single lifetime number.
- New menu bar display option: **Last 30 days** (Settings → Menu bar shows).
- VoiceOver labels for the per-key spend columns.

### Changed
- Dropdown widened 380 → 440 pt to fit the three-column layout.
- Per-key totals for OpenRouter now cover the trailing 30 days (previously
  lifetime). Keys with no spend in the last 30 days no longer appear in the
  key list.
- Anthropic per-key figures remain estimates (allocated from org cost by
  token share, now day-by-day) and are labeled "est. spend"; OpenAI and
  OpenRouter per-key figures are real dollars.

### Fixed
- Per-key 30-day totals are clipped to the same 30-day window as the header,
  so a key row can no longer exceed the vendor total above it.
- Key rows keep a stable order between refreshes when spend values tie.

## [1.0.0] - 2026-07-19

Initial public release.

- macOS menu bar app + background daemon tracking LLM API spend across
  **OpenRouter, Anthropic, and OpenAI**.
- Today / month-to-date totals, 30-day per-vendor bar charts, per-key spend,
  credits/balance display where the vendor exposes it.
- API keys stored in the macOS Keychain only; all data stays on device.
- Notarized DMG distribution.

[1.2.0]: https://github.com/kpnemo/llm-cost-bar/releases/tag/v1.2.0
[1.1.0]: https://github.com/kpnemo/llm-cost-bar/releases/tag/v1.1.0
[1.0.0]: https://github.com/kpnemo/llm-cost-bar/releases/tag/v1.0.0
