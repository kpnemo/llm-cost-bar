# OpenRouter key list UI — aligned columns, inspector line, pinnable detail

**Date:** 2026-07-25
**Status:** approved (brainstormed with visual companion; option G + H2)
**Baseline:** v1.3.20 (live per-key today/MTD, limit fields in `key_totals`)

## Problem

v1.3.20 shows per-key limits as a progress bar + caption under every key row.
This doubles row height, the long caption misaligns with the money columns,
and the red key bar visually competes with the red credits bar above it. Key
rows also show today/MTD/30d while the caption interleaves unrelated text, so
the columns no longer read as a table under the vendor header.

## Design

### Layout

- Key rows are single-line: `▸ name · today · MTD · 30d`. The three money
  columns use the same fixed column widths as the vendor header line so they
  align exactly.
- A faint uppercase column-header line (`API KEYS · TODAY · MTD · 30D`)
  separates the list from the credits section, replacing the current
  "API keys" label (Anthropic keeps its "· est. spend" suffix).
- The per-key ProgressView bar, caption line, and "disabled" text badge from
  v1.3.20 are removed.

### Status signaling (at rest)

- Key name red when the limit is exhausted: `limitRemainingUSD <= 0.01`.
- Disabled keys: row dimmed (~55% opacity), name struck through.
- Healthy and unlimited keys carry no decoration and look identical at rest.

### Hover — fixed inspector line (H2)

- One fixed-height line under the key list; reserved space, so hover never
  moves layout.
- Idle content: summary, e.g. `4 keys · 3 limited · 1 unlimited · 1 disabled`
  (only non-zero segments shown; "limited" = has a budget limit, regardless
  of how much is used).
- Hovering a key row highlights the row (subtle background) and fills the
  inspector: `erik · limit $20.00 · $0.00 left · resets weekly`, with
  `lifetime $84.04` right-aligned.
  - No limit → `name · no limit`.
  - Limit without reset interval → omit the "resets …" segment.
  - Disabled → `name · disabled · limit $X`.

### Click — pinned detail strip (G)

- Clicking a row toggles an inline detail strip directly under that row
  (chevron rotates ▸/▾). Content mirrors the inspector line. Multiple keys
  may be pinned; pins are session-local (not persisted).
- Layout shifts only on explicit click, never on hover.

### Vendors without key metadata

OpenAI/Anthropic rows have no limit/lifetime data: no chevron, no hover
inspector, no click behavior — their cards are unchanged. Gate: show the
interactive treatment only when at least one key of the vendor has
`limitUSD != nil || lifetimeUSD != nil`.

## Data changes (Core)

- `KeyTotal.lifetimeUSD: Double?` — from `/keys` `usage` field (decoded
  today, currently dropped). Same-name merge sums it.
- `KeySpend.lifetimeUSD: Double?` — read back from store.
- `key_totals.lifetime_usd REAL` — migration `v9-key-lifetime`.
- Inspector/detail line text composed by a pure Core function (e.g.
  `KeySpend.detailSummary`) so wording is unit-tested; SwiftUI renders only.

## Testing

- Provider: `/keys` fixture with `usage` → `lifetimeUSD` populated; merge
  case sums lifetime.
- Store: `lifetime_usd` round-trip through upsert + vendorSummaries.
- Core: `detailSummary` cases — capped, healthy, no limit, no reset interval,
  disabled, missing lifetime.
- UI: manual verification via dropdown (SwiftUI not unit-tested in this repo).

## Edge cases

| Case | Behavior |
| --- | --- |
| Key without limit | No decoration; inspector says "no limit" |
| Disabled key | Dimmed row, struck name; inspector notes it |
| Limit but no reset interval | "$X left", no "resets" segment |
| Merged same-name keys | Limits summed or dropped-to-unlimited (v1.3.20 rule); lifetime summed |
| Long key name | Name truncates with ellipsis before columns compress |
| New key, today-only spend | Already visible (v1.3.20 visibility rule) |
| >5 keys | Existing LIMIT 5 ranking unchanged; summary counts reflect shown rows |

## Out of scope

- Key expiry (`expires_at` not decoded yet).
- H3 floating hover cards.
- Per-model breakdown inside the detail strip (future: tokens, BYOK).
