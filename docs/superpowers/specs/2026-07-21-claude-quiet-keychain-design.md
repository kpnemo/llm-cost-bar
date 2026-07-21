# Quiet Claude keychain — design & handoff (target: v1.3.9)

Date: 2026-07-21. Status: design approved by user; implementation not started.
This doc is a session handoff: it contains everything needed to build, test,
and release the feature in a fresh session.

## Problem

The daemon reads Claude Code's keychain item ("Claude Code-credentials") every
subscriptions poll to fetch Pro/Max limits. Claude Code rewrites that item on
every OAuth token refresh (~every 8–12 h), and macOS invalidates third-party
consent on each rewrite — so the user gets a keychain dialog roughly once per
wake/day, and "Always Allow" cannot stick. Verified live on 2026-07-21:
item `mdat` changed at 03:53Z and again 11:49Z; each was followed by a prompt
at the next daemon read after wake. Our own vault item (all vendor API keys,
service `com.mikeb.llmcostbar`, account `__vault__`) never re-prompted through
five app updates — the problem is exclusively the *foreign* item.

Root cause of the ambush: the daemon performs **interactive** keychain reads
from the background. That is the bug to remove.

## Research (verified sources)

- steipete/CodexBar hit the identical issue (#340 "Keychain password prompt
  repeats every few hours despite 'Always Allow'", also #485) and documented
  the fix architecture in `docs/KEYCHAIN_FIX.md`: own-keychain cache →
  non-interactive (no-UI) probes → interactive read only with pre-alert →
  denial cooldown → env/manual token override.
- anthropics/claude-code#22144 (open): asks Anthropic to stop resetting
  consent / provide a usage cache file. Until fixed upstream, NO app can fully
  eliminate re-prompts; state of the art = never prompt from the background.
- `~/.claude/.credentials.json` is NOT written on macOS (checked on this
  machine and confirmed in #22144) — no file-based bypass exists.
- `claude setup-token` (official) mints a long-lived `sk-ant-oat…` OAuth token
  (~1 year) — candidate for a zero-prompt manual path. **Unverified whether
  `api.anthropic.com/api/oauth/usage` accepts it — verify before building
  that part** (see Step 0).

## Approved design (four pillars)

1. **First consent is click-gated and explained.** The Claude card / Settings
   shows "Connect Claude — macOS will ask once…" and the interactive keychain
   read happens only on that click, **in the App process** (never the daemon).
   The fetched OAuth blob (accessToken + expiresAt, whatever else the blob
   holds under `claudeAiOauth`) is cached as a JSON string in OUR vault
   (`KeychainStore`, e.g. vault key `__claude_oauth_cache__` — pick a name
   that cannot collide with account IDs).
2. **The daemon never prompts — by construction.** Daemon reads the cached
   token from the vault (silent forever). When it's expired/401s, it attempts
   a **non-interactive** re-read of Claude Code's item using
   `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` (returns
   `errSecInteractionNotAllowed` instead of showing a dialog). Success →
   silently refresh the vault cache and continue. Failure → mark the source
   stale with a distinct reason (e.g. `reconnect_needed`), keep showing
   last-known data. NO interactive fallback in the daemon path.
3. **Reconnect is click-gated with cooldown.** Claude card shows last-known
   limits + "updated Xh ago · ↻ reconnect" when stale. Click → App does the
   interactive read (one prompt, user-initiated) → writes vault cache →
   requests sync. If the user denies, cool down (don't re-attempt in
   background; a fresh click clears the cooldown).
4. **Optional zero-prompt path:** Settings → Accounts, Claude row: "connect
   with a token instead" → instructions (`claude setup-token` in Terminal,
   browser approve, copy token) + "Paste token from clipboard" button (same
   pattern as provider pairing in `PairingController.addProviderFromClipboard`).
   Token stored in the vault; when present it takes precedence over both cache
   and keychain reads. On 401 → stale with "run claude setup-token again".

User-facing promise after this ships: one approval at connect time; the app
never interrupts afterwards — at most a "reconnect" button appears.

## Step 0 — verify setup-token feasibility (2 min, BEFORE building pillar 4)

User runs `claude setup-token` in their own Terminal (interactive browser
flow), copies the `sk-ant-oat…` token to clipboard, then run (token must
never be echoed into the transcript):

```bash
T=$(pbpaste | grep -oE 'sk-ant-oat[0-9A-Za-z_-]+' | head -1)
curl -s -o /tmp/oat-test.json -w "HTTP %{http_code}\n" \
  "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $T" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-code/2.0.0"
head -c 300 /tmp/oat-test.json   # usage windows JSON = success; then rm the file
```

If 401/403 → drop pillar 4 (or park it), ship pillars 1–3 alone; they already
solve the ambush.

## Current architecture pointers

- `Core/Sources/LLMCostBarCore/ClaudeCodeCredentials.swift` — reads Claude
  Code's keychain item (service "Claude Code-credentials", blob key
  `claudeAiOauth.accessToken`). Detection is attributes-only (no prompt) —
  keep that for discovery. This is where the no-UI query variant goes.
- `Core/Sources/LLMCostBarCore/SubscriptionProvider.swift` (~line 40-56) —
  Claude usage fetch. Headers are load-bearing: `anthropic-beta:
  oauth-2025-04-20` AND `User-Agent: claude-code/2.0.0` (other UAs hit a
  hostile 429 bucket). 401 → `ProviderError.auth`. NEVER use/refresh Claude
  Code's refresh token (would log the user out of Claude Code).
- `Core/Sources/LLMCostBarCore/SubscriptionSyncEngine.swift` — daemon-side
  orchestration; stale reasons flow into `subscription_sources` and the card.
- `Core/Sources/LLMCostBarCore/KeychainStore.swift` — the single-item vault
  (`__vault__` JSON map). `getKey/setKey/deleteKey` + `migrateLegacyKeys`.
  Vault reads/writes never prompt (both app + daemon already ACL'd).
- `App/SubscriptionsView.swift` — Claude card UI (stale label exists; add
  reconnect button + connect flow).
- `App/SettingsView.swift` — AccountsTab subscriptions section + the
  "About Keychain prompts" caption (UPDATE ITS WORDING: currently promises
  "at most two prompts, ever" — revise to the new promise; same for
  `docs/LANDING.md` FAQ "Why does macOS ask about Keychain access?").
- `App/StoreModel.swift` — app-side model; `saveConfig`, `requestSync()`
  (writes sync-request file; daemon picks up within ~5 s).
- Daemon polls subscriptions every 5 min (`Daemon/main.swift`); app and daemon
  communicate only via files/SQLite in `~/Library/Application Support/LLMCostBar/`.

## Project rules that apply (CLAUDE.md + hard lessons)

- Logic in Core with tests (`cd Core && swift test`); App/Daemon stay thin.
- TDD; fixture-style tests (see `SubscriptionProviderTests`, `FakeHTTP`).
- Every sync attempt lands in `sync_log`; errors use the ProviderError
  taxonomy (transient/auth/http/decode).
- Secrets: Keychain only, never in files/logs; never echo tokens into the
  chat transcript.
- `AppConfig` new fields must use the per-field `decodeIfPresent` pattern.
- Work on `develop` (branch from it if desired); `main` is release-only.

## Release flow (v1.3.9)

1. Bump `CFBundleShortVersionString` in `project.yml` → `xcodegen generate`
   (commits the regenerated `App/Info.plist` too — publish script reads the
   PLIST, not project.yml).
2. CHANGELOG.md entry; commit on develop; push; merge `--no-ff` develop→main;
   **push main BEFORE publishing** (gh tags remote main HEAD).
3. `RELEASE_NOTES="…" bash scripts/publish_release.sh` (Developer ID team
   R5QHA2A8Z9, notary profile `pmw-notary`; takes ~5 min; run in background).
4. User tests by self-updating from the installed v1.3.8 (popover row or
   Settings → Check for Updates…). Zero keychain prompts expected during the
   update itself (vault identity stable).

## Verification checklist

- Core tests green (incl. new: no-UI read fallback ordering — vault token
  preferred; expired cache → no-UI probe; probe failure → stale
  `reconnect_needed`, NOT an interactive read; setup-token precedence).
- Manual: revoke the daemon's grant (Keychain Access → "Claude
  Code-credentials" → Access Control → remove llmcostd, or just wait for the
  next Claude Code token rotation) → confirm NO dialog appears on wake/poll;
  card shows reconnect; click → single prompt → healthy again.
- Confirm `sync_log` rows for claude-sub during stale period (no silent
  failures) and that Codex subscription path is untouched.
- Settings + LANDING.md wording updated to the new promise.

## Context from today (for continuity)

Installed app: v1.3.8 (self-update pipeline battle-tested; 8 releases shipped
2026-07-20→21). The keychain vault (v1.3.4) works — vendor keys never
re-prompt. The user's exact words on the goal: "ideally i need to be prompted
in the beginning and thats it."
