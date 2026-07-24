# Claude subscription via claude.ai session cookie — design

Date: 2026-07-24
Status: approved-by-direction (user: "investigate ClaudeUsageBar, let's do the same —
same functionality and same UI for the Claude subscription panel")

## Problem

Claude subscription limits are fetched with Claude Code's OAuth access token,
read from a keychain item **we don't own** (`Claude Code-credentials`). macOS
therefore demands per-binary consent, the token expires/rotates roughly daily,
and the `claude setup-token` escape hatch is dead (usage endpoint 403s
setup-tokens — missing `user:profile` scope). Net effect: a "Reconnect" click
(= keychain prompt) almost every day. The user is done with that.

## How ClaudeUsageBar (github.com/Artzainnn/ClaudeUsageBar) solves it

It never touches the keychain or OAuth at all. The user pastes their claude.ai
**browser session cookie** once (from DevTools → Network → `usage` request →
`Cookie` header). The app then calls claude.ai's internal web API with
browser-like headers (Chrome UA, `Origin`/`Referer: https://claude.ai`):

- org id: `lastActiveOrg` cookie value, else `GET /api/bootstrap` →
  `account.lastActiveOrgId`
- `GET /api/organizations/{org}/usage` → `five_hour`, `seven_day`,
  `seven_day_sonnet` objects (`utilization` %, `resets_at`), plus a `limits`
  array of model-scoped weekly limits (e.g. Fable: `scope.model.display_name`,
  `percent`, `resets_at`)
- `GET /api/organizations/{org}/overage_spend_limit` → `used_credits`,
  `monthly_credit_limit`, `currency`, `disabled_until` (extra-usage spend)
- `GET /api/organizations/{org}/prepaid/credits` → `amount` (or sum of
  `tranches[].remaining_amount_minor_units`) — free/promo credit balance

Browser session cookies live for months, so setup is one paste. (They store it
in UserDefaults in plain text; we will NOT copy that part.)

## Design

### Approach chosen (of 3)

- A. Replace OAuth path with cookie path — loses zero-setup auto-detection.
- **B. Cookie path preferred, existing OAuth path as fallback — chosen.**
  Cookie present in our vault → web API (zero prompts, richer data). No cookie
  → today's behavior, unchanged. Non-destructive, nothing to migrate.
- C. Auto-read the cookie from the browser's cookie store — rejected: reading
  Chrome/Safari cookie jars is its own permission/security quagmire.

### Core (`LLMCostBarCore`)

1. **`ClaudeWebSession`** (new file `ClaudeWebUsage.swift`): vault-backed
   record `{cookie, orgID?}`, JSON-encoded at vault key
   `__claude_web_session__` in our existing `KeychainStore` item (complies
   with "API keys: Keychain only"; our item is already ACL'd to app+daemon so
   reads never prompt). Helper: parse `lastActiveOrg` out of the cookie
   string. Constant `cookieExpiredReason` ("claude.ai cookie expired —
   re-paste it in Settings"), machine-checked by the app like
   `reconnectReason` is today.
2. **Web fetch + parsers** (same file): pure static `parseUsage` /
   `parseOverage` / `parseCredits` functions (testable on fixtures), and a
   small fetch layer over the existing `HTTPClient` sending the full cookie +
   Chrome UA + Origin/Referer headers. `usage` windows map to the existing
   windowIDs (`five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`);
   `limits[]` model entries become `seven_day_<display_name lowercased>`
   (e.g. `seven_day_fable`, label "7-day Fable").
3. **`ClaudeSubscriptionProvider`** gains a strategy switch at the top of
   `fetchSnapshot`: if a web session exists in the vault → web path (usage +
   overage + prepaid, overage/prepaid failures non-fatal); else → current
   OAuth path, untouched. `isDetected()` also returns true when a cookie is
   stored. 401/403 on the web path → `ProviderError.auth` with
   `cookieExpiredReason` (no retry loop; user re-pastes).
4. **Credit model + storage**: `SubscriptionSnapshot.credit:
   SubscriptionCredit?` (`spentMinor`, `limitMinor`, `currency`, `resetsAt?`,
   `freeCreditsMinor`). Migration `v7-subscription-credit`: table
   `subscription_credit(source PK, spent_minor, limit_minor, currency,
   resets_at, free_credits_minor, observed_at)`; upsert inside
   `upsertSubscriptionSnapshot`, read via `subscriptionCredits()`.

### App

5. **Settings → Subscriptions → Claude**: new cookie rows under the toggle —
   status line ("✓ using claude.ai cookie — no Keychain involved" vs "using
   Claude Code sign-in — paste a claude.ai cookie to stop Keychain prompts"),
   numbered how-to (open claude.ai/settings/usage, DevTools → Network →
   `usage` → copy `Cookie` header), "Open claude.ai usage page ↗", **"Paste
   cookie from clipboard & Test"** (live-fetch first, store to vault only on
   success, clear stale, refresh — same pattern as provider pairing), and
   "Remove cookie". Reuses a new `ClaudeCookieController` (mirrors
   `PairingController` phases).
6. **SubscriptionCard** (panel — mirrors ClaudeUsageBar's popover): existing
   per-window bars already match (colored progress + reset text); add the
   model-scoped windows automatically (ordering rank for `seven_day_opus`,
   `seven_day_sonnet`, then other model windows), plus for Claude an **Extra
   usage** block when credit data exists: progress bar spent/limit with the
   same color ramp, "$x.xx of $y.yy · z%" (">limit" → "over limit"),
   "Resets MMM d", "Manage →" opening
   `https://claude.ai/new#settings/usage`, and a "$n.nn free credits left"
   caption when balance > 0. Nothing shown for Codex.
7. **StoreModel** loads the credit row alongside windows. Legacy
   `ClaudeConnectController` untouched (fallback path still needs it).

### Daemon

No changes — provider list and poll loop are already in place.

### Testing

Recorded-style JSON fixtures (`claude-web-usage.json` incl. `limits` Fable
entry, `claude-web-overage.json`, `claude-web-prepaid.json`); parser unit
tests; provider tests with the fake `HTTPClient` (cookie precedence over
OAuth, org-from-cookie vs bootstrap fallback, 401 → auth reason, overage
failure non-fatal); store tests for the credit table + migration.

### Risks / notes

- Internal claude.ai API — may change without notice (accepted; the OAuth
  fallback and stale-marking already handle vendor breakage gracefully).
- Cloudflare may some day challenge non-browser clients; ClaudeUsageBar
  demonstrates plain URLSession + Chrome UA works today.
- Cookie is a full-account credential — vault-only storage, never logged,
  never in config.json (project rule upheld; deviation from ClaudeUsageBar's
  UserDefaults storage is deliberate).
