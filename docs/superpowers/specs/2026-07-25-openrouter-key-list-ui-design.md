# OpenRouter key list UI — aligned columns, inspector line, pinnable detail

**Date:** 2026-07-25
**Status:** approved (brainstormed with visual companion; option G + H2; revised after Codex review)
**Baseline:** v1.3.20 (live per-key today/MTD, limit fields in `key_totals`)

## Problem

v1.3.20 shows per-key limits as a progress bar + caption under every key row.
This doubles row height, the long caption misaligns with the money columns,
and the red key bar visually competes with the red credits bar above it. Key
rows also show today/MTD/30d while the caption interleaves unrelated text, so
the columns no longer read as a table under the vendor header.

## Design

### Layout (all vendors)

- Key rows are single-line: `▸ name · today · MTD · 30d`. The three money
  columns use the same fixed column widths as the vendor header line so they
  align exactly.
- A faint uppercase column-header line (`API KEYS · TODAY · MTD · 30D`)
  replaces the current "API keys" label for vendors whose keys report
  windowed data (`hasWindows == true`). Anthropic's header carries its
  "· EST. SPEND" qualifier.
- Legacy fallback preserved: when no key has windowed data
  (`hasWindows == false`, pre-v1.3.x daemon rows), keep today's single-total
  row format and the plain "API keys" label — no column-header line.
- The per-key ProgressView bar, caption line, and "disabled" text badge from
  v1.3.20 are removed.

### Status signaling (at rest)

- Key name red when the limit is exhausted: `limitRemainingUSD != nil` and
  `limitRemainingUSD <= 0.01`. Unknown remaining (nil) is never shown as
  exhausted.
- Disabled keys: row dimmed (~55% opacity), name struck through.
- Healthy and unlimited keys carry no decoration and look identical at rest.

### Interactivity gate

Chevron, hover inspector, and click-to-pin appear only when
`hasWindows && hasKeyMetadata`:

- `hasWindows` — at least one displayed key row has `mtdUSD != nil` (the
  existing UI rule; legacy single-total data therefore never gets
  interactivity).
- `hasKeyMetadata` — at least one DISPLAYED key row (the top 5, not all
  stored rows) has `limitUSD != nil || lifetimeUSD != nil || disabled ==
  true`. Computing over displayed rows avoids phantom chevrons when only a
  hidden sixth key carries metadata.

`VendorSummary.hasKeyMetadata` is derived in `vendorSummaries` from the rows
it returns as `topKeys`. OpenAI/Anthropic cards keep their current static
rows until those providers supply metadata.

### Hover — fixed inspector line (H2)

- One fixed-height line under the key list; reserved space, so hover never
  moves layout. Only rendered when `hasKeyMetadata`.
- Idle content: summary, e.g. `4 keys · 3 limited · 1 unlimited · 1 disabled`
  (only non-zero segments; "limited" = has a budget limit, regardless of how
  much is used; counts cover the displayed rows).
- Hovering a key row highlights it (subtle background) and fills the
  inspector with that key's detail (see "Detail text" below).

### Click — pinned detail strip (G)

- Clicking a row toggles an inline detail strip directly under that row
  (chevron rotates ▸/▾). Content mirrors the inspector line.
- At most ONE pinned key per vendor card: clicking another row moves the pin;
  clicking the pinned row clears it. This bounds dropdown height (the popover
  does not scroll).
- Pin lifecycle: cleared whenever the card's key list disappears — vendor
  card collapse, tab switch (API Spend ↔ Subscriptions), dropdown close.
  Never persisted.
- Layout shifts only on explicit click, never on hover.
- Pins and hover state are keyed by stable row identity
  `(accountID, apiKeyID)` — NOT by the row's value. `ForEach(id: \.self)`
  must be replaced accordingly, since `KeySpend` values change on every poll.
  A vendor-side rename produces a new identity: the old pin silently clears
  (pins are ephemeral, so this is acceptable). A pinned row evicted from the
  top 5 likewise drops its pin.

### Detail text (Core-composed)

A pure Core function on `KeySpend` returns a structured value so SwiftUI
renders without wording logic:

```swift
struct KeyDetail { let leading: String; let trailing: String? }
func detail() -> KeyDetail
```

- leading examples:
  - `limit $20.00 · $0.00 left · resets weekly`
  - `limit $20.00 · resets weekly` (remaining unknown/nil)
  - `limit $20.00 · $12.00 left` (no reset interval)
  - `no limit`
  - `disabled · limit $20.00 · $4.00 left · resets weekly` — disabled is a
    prefix; known limit segments still render per the normal rules (they are
    suppressed only when unknown, never because of disabled status)
- trailing: `lifetime $84.04`, or nil when lifetime is unknown.
- The inspector prefixes the key name; the pinned strip omits it (context is
  the row above). Multi-account vendors can show the same name twice — the
  rows stay separate and unlabeled (accepted limitation; multi-account
  OpenRouter is rare).
- Rendering: single line; `leading` tail-truncates first, `trailing` never
  truncates.
- The idle inspector summary is also Core-composed
  (`KeySpend.summaryLine(for: [KeySpend]) -> String` or equivalent) and
  unit-tested alongside `detail()`.

## Data changes (Core)

- `KeyTotal.lifetimeUSD: Double? = nil` — from `/keys` `usage` field (decoded
  today, currently dropped). Defaulted optional so existing OpenAI/Anthropic
  construction sites compile unchanged.
- `KeySpend.lifetimeUSD: Double? = nil` — read back from store.
- `key_totals.lifetime_usd REAL` — migration `v9-key-lifetime` (nullable; v8
  rows migrate with NULL).
- `OpenRouterProvider.fetchKeyTotals` ordering fix: build a row for EVERY
  hashed key, run `mergedByName` FIRST, then apply the visibility filter
  (`total > 0 || today > 0 || mtd > 0`) to the merged rows — so a zero-spend
  same-name sibling still contributes lifetime/limit metadata before
  filtering. Intentional exclusions: keys without a hash cannot be fetched
  per-key and stay out entirely; a merged group with zero spend in every
  window stays hidden even if it carries metadata (visibility requires
  spend).

### Merge semantics (same display name, single account)

Merging is account-local (one `fetchKeyTotals` call). Rows from different
accounts never merge; UI identity is `(accountID, apiKeyID)`.

| Field | Rule |
| --- | --- |
| totalUSD | sum |
| todayUSD / mtdUSD | sum of non-nil; nil only if ALL nil — never coerce all-nil legacy windows to 0, which would falsely activate `hasWindows` |
| lifetimeUSD | sum only if ALL non-nil; else nil (a partial sum would render as an exact `lifetime $X`) |
| limitUSD | sum if ALL have limits; else nil (any unlimited → unlimited) |
| limitRemainingUSD | coupled to limitUSD: nil whenever limitUSD is nil; otherwise sum if ALL non-nil, else nil. A row can never read "no limit" while carrying a remaining value, and nil is never coerced to 0 (which would fake "exhausted") |
| limitReset | coupled to limitUSD: nil whenever limitUSD is nil; otherwise keep if identical across all merged keys, else nil |
| disabled | true only if ALL merged keys disabled |

## Accessibility

- Each key row keeps a single consolidated `accessibilityLabel` extended with
  the detail text (limit, remaining, reset, disabled, lifetime) — hover is
  never the only path to the information.
- The pinned strip is part of the pinned row's accessibility element; the
  inspector line is `accessibilityHidden` (redundant with row labels).
- Interactive rows expose an accessibility action ("expand details" /
  "collapse details") and announce expanded state via
  `accessibilityValue`, so VoiceOver can pin without hover or a pointer.
- Keyboard navigation for pinning is out of scope (the dropdown has no
  keyboard focus model today).

## Freshness

Key metadata is best-effort per the existing SyncEngine contract (key-total
fetch failures don't fail the sync). Inspector data may be stale until the
next SUCCESSFUL key fetch — repeated failures extend the window unboundedly;
no staleness indicator in this iteration (noted as future work).

## Testing

- Provider: `/keys` fixture with `usage` → `lifetimeUSD` populated; merge
  fixtures for every rule in the table above, including
  zero-spend-sibling-contributes-metadata, nil-remaining never becoming 0,
  remaining/reset forced nil when any sibling is unlimited, partial lifetime
  → nil, and all-nil windows staying nil.
- Store: `lifetime_usd` round-trip; `hasKeyMetadata` true/false per vendor,
  including metadata ONLY on a key outside the top 5 → gate stays false;
  migration test: v8 DB with rows → v9 keeps rows, `lifetime_usd` NULL.
- Core: `detail()` cases — capped, healthy, unknown remaining, no reset
  interval, no limit, disabled (prefix with full known segments), missing
  lifetime; `summaryLine` cases — all limited, mixed, all unlimited, with
  disabled.
- UI: manual verification via dropdown (SwiftUI not unit-tested in this repo).

## Edge cases

| Case | Behavior |
| --- | --- |
| Key without limit | No decoration; detail says "no limit" |
| Limit but remaining unknown (nil) | Not red; detail omits "left" segment |
| Disabled key | Dimmed row, struck name; detail notes it |
| Limit but no reset interval | "$X left", no "resets" segment |
| Merged same-name keys | Per merge-semantics table above |
| Same name in two accounts | Two separate rows (no cross-account merge) |
| Long key name | Name truncates with ellipsis before columns compress |
| New key, today-only spend | Already visible (v1.3.20 visibility rule) |
| >5 keys | LIMIT 5 ranking unchanged; summary counts cover shown rows; `hasKeyMetadata` scans only the shown rows (metadata hidden on key #6 does not enable chevrons) |
| Legacy daemon data (no windows) | Old single-total layout, no headers; interactivity off via the `hasWindows && hasKeyMetadata` gate |
| Aggregate height | ≤1 pin per vendor × small vendor count keeps the popover within bounds; inspector is a single truncating line |

## Out of scope

- Key expiry (`expires_at` not decoded yet).
- H3 floating hover cards.
- Per-model breakdown inside the detail strip (future: tokens, BYOK).
- Staleness indicator for key metadata.
- Keyboard navigation / focus model for the dropdown.
