# Changelog

All notable changes to LLM Cost Bar are documented here. Each GitHub release
carries its version's section as release notes.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [1.3.14] - 2026-07-22

### Fixed
- **Critical: the background service could still show a Keychain dialog.**
  Caught live while testing the reconnect flow: the daemon's "no-UI" probe
  of Claude Code's sign-in relied on `kSecUseAuthenticationUIFail`, which
  only suppresses LocalAuthentication (Touch ID-style) UI — the legacy
  file-keychain ACL dialog is governed by
  `SecKeychainSetUserInteractionAllowed`, so once consent was missing the
  probe threw the full password prompt from the background, every poll.
  The probe now disables keychain UI for exactly that one call (and
  restores it), so a blocked probe fails silently into the "needs
  reconnect" card state — the behavior 1.3.9 promised.

## [1.3.13] - 2026-07-22

### Fixed
- Settings no longer shows an alarming orange "not responding" during the
  normal post-update window: while the service is being re-armed (first
  ~2 min after app launch) it now reads "starting…" in grey, matching the
  popover's existing grace period. Orange is reserved for an actually dead
  service.
- The legacy-BTM purge from 1.3.12 could be skipped by SMAppService's
  status reporting (the record stayed "enabled" in dumpbtm); the unregister
  now runs unconditionally at every launch and logs its outcome either way.

## [1.3.12] - 2026-07-22

### Fixed
- Root cause of the recurring ~30 s "daemon not responding" window after
  updates: a legacy SMAppService/BTM registration for llmcostd (from before
  the switch to a classic LaunchAgent) was still enabled and re-submitted
  the daemon at every login/update — with a launch constraint — racing the
  LaunchAgent for the same launchd label. The app now unregisters that
  record on every launch until it is gone, and logs the outcome.
- "Repair background service" no longer freezes the Settings window: the
  launchctl cycle runs in the background with a progress state, and the
  button reports success by the daemon's own heartbeat (or a clear failure
  message after 12 s) instead of silently returning.

## [1.3.11] - 2026-07-22

### Added
- Test hook for the reconnect flow: creating the file
  `debug-drop-claude-cache` in `~/Library/Application Support/LLMCostBar/`
  makes the background service forget its cached Claude token on the next
  poll — the same state a real overnight token rotation leaves behind. With
  Keychain access intact the silent probe recovers invisibly; with access
  revoked the Claude card shows Reconnect. Lets the quiet-keychain promise
  be verified on demand instead of waiting ~8-12 h for a real rotation.

## [1.3.10] - 2026-07-22

### Removed
- The "connect with a token instead" (`claude setup-token`) option: verified
  live that Anthropic's usage endpoint rejects setup-tokens (403, missing
  `user:profile` scope), so the path cannot work. The quiet-keychain flow
  from 1.3.9 (silent background + click-gated Reconnect) is the supported
  way to connect Claude. The vault-side plumbing stays parked in Core in
  case Anthropic ever opens the scope.

### Fixed
- A connect/token error shown in Settings no longer lingers after the
  Claude source is healthy again — failure text now clears as soon as a
  reconnect is no longer needed.

## [1.3.9] - 2026-07-21

### Changed
- **Keychain dialogs can no longer appear out of nowhere.** Claude Code
  rotates its sign-in token every few hours, and macOS resets Keychain
  consent each time — so the background service used to trigger a "llmcostd
  wants to access…" dialog roughly daily, and "Always Allow" couldn't stick.
  Now the background service is incapable of prompting: it reads a copy of
  the token cached in the app's own Keychain item, silently re-reads Claude
  Code's item only in no-prompt mode, and when that fails it just marks the
  Claude card "needs reconnect" while keeping last-known data on screen.
  A Keychain dialog appears only right after you click Connect or Reconnect.
- New optional zero-prompt path: connect Claude with a long-lived
  `claude setup-token` (Settings → Accounts → "connect with a token
  instead"). The token is tested live before it's stored and takes
  precedence over Keychain reads.
- Upgrades from 1.3.8 usually need no action: if the background service
  still holds a valid Keychain grant, the first silent probe seeds the cache
  automatically.

## [1.3.8] - 2026-07-21

### Fixed
- Rare post-update hang of the background service: if it hasn't come up
  within 20 seconds of app launch, the app now repairs it automatically
  (previously the "Repair background service" button in Settings was needed).

## [1.3.7] - 2026-07-21

### Changed
- Installing an update from Settings now shows the same live progress as the
  popover row: download percentage, "installing — restarting…", success and
  retry states.

## [1.3.6] - 2026-07-21

### Fixed
- The subscriptions sparkline no longer renders as an odd flat line when only
  a few hours of history exist: it now waits for ≥12 h of data, pins its
  x-axis to the true 7-day window (young data grows in from the right), and
  gains a subtle area fill.

## [1.3.5] - 2026-07-21

### Changed
- "Copy diagnostics" now includes the app version and timestamp — handy when
  reporting an issue.

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
