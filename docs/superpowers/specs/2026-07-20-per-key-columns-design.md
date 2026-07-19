# Per-key Today + MTD + 30d columns — design

Date: 2026-07-20. Approved via brainstorming with visual mockups
(`.superpowers/brainstorm/86859-1784498926/content/key-columns-v5.html` is the
approved layout; color treatment "A — color-coded").

## Goal

The dropdown's per-API-key rows currently show a single number (`key_totals`:
30-day window for Anthropic/OpenAI, lifetime for OpenRouter). Replace with
three right-aligned columns per key — **today | MTD | 30d** — and show the
same three totals in each vendor card header, on one shared column grid.
Additionally, the "Menu bar shows" setting gains a **Last 30 days** option.

## UI (App/DropdownView.swift, App/LLMCostBarApp.swift, App/SettingsView.swift)

- Dropdown width: 380 → 440 pt.
- **Vendor card header** (visible collapsed and expanded): vendor icon + name
  on the left; three totals right-aligned in fixed-width numeric columns
  (~72 pt each, trailing-aligned), with small tertiary labels
  `today` / `MTD` / `30d` beneath. These labels double as the key-table column
  headers — no second header row above the key list.
  - Column colors, used consistently for totals and key rows:
    **today = `.blue`** (same hue as chart bars), **MTD = `.primary` bold**
    (the anchor), **30d = `.secondary`**.
  - Replaces: the collapsed-state inline "today $X" text and the static
    "today $0.00" line above the chart. The chart-hover readout remains,
    shown only while hovering.
- **Key table**: one row per key — name (flexible width, truncating tail) then
  the three numeric columns using the same fixed widths as the header, so all
  columns align without a shared Grid. Sorted by MTD descending (OpenRouter:
  by total descending). Zero values in the today column render dimmed
  (opacity ~0.45).
- **OpenRouter card**: header gets all three totals (computable vendor-wide),
  but the key list keeps a single "total spend" column — its `/keys` API only
  reports per-key lifetime totals.
- Section labels: "API keys · est. spend" (Anthropic), "API keys" (OpenAI),
  "API keys · total spend" (OpenRouter).
- **Settings**: `Picker("Menu bar shows")` gains `Text("Last 30 days")`
  with new `MenuBarDisplay.last30Days` case; `StoreModel.menuBarTitle`
  formats `summary.last30USD` for it.

## Data model & DB (Core)

- `KeyTotal` gains `todayUSD: Double?` and `mtdUSD: Double?` (nil when the
  vendor can't provide them — OpenRouter). `totalUSD` keeps its current
  meaning (30-day window for Anthropic/OpenAI, lifetime for OpenRouter) and
  feeds the 30d column.
- Migration `v5-key-daily`: `ALTER TABLE key_totals ADD COLUMN today_usd REAL;
  ADD COLUMN mtd_usd REAL;` (nullable). `upsertKeyTotals` writes them;
  `KeySpend` carries `todayUSD`/`mtdUSD` optionals through to the app.
- `VendorSummary` gains `last30USD: Double`; `Summary` gains
  `last30USD: Double`.
- `usage_daily` and its idempotent upsert rules are untouched; `key_totals`
  remains a delete-and-reinsert snapshot per vendor sync.

## Vendor-level 30d total (UsageStore)

Computed like MTD, so the header/menu-bar number is live-corrected:
`last30 = SUM(usage_daily.cost_usd WHERE day > today−30d AND day < today)
+ todayUSD` where `todayUSD` is the existing per-account
`max(activity, live-delta)` value. `Summary.last30USD` = sum over vendors.

## Providers

- **Anthropic** (`fetchKeyTotals`): keep the existing 30-day fetch window and
  weight-allocation math, but preserve the per-day dimension both APIs already
  return (1d buckets): allocate each day's per-model cost by that day's
  per-key token weights → per-key per-day estimated dollars. Then
  `totalUSD` = sum over the window (unchanged semantics), `mtdUSD` = sum over
  days ≥ 1st of current UTC month, `todayUSD` = today's bucket. Unattributed
  cost (rows with no usage weights, incl. negative refunds) is spread by
  per-day weight share as before, day by day; a day with cost but zero usage
  weights falls back to spreading by the window-wide key weights.
- **OpenAI** (`fetchKeyTotals`): same reshaping with real dollars — the costs
  endpoint already returns daily buckets grouped by `api_key_id`; keep the
  per-day values, compute the three sums. Key-id → name mapping unchanged.
- Both providers fetch a ~31-day bucket range (today through today−30) so
  per-day allocation always has a full trailing day to look back on, but the
  shared `KeyTotal.aggregate` helper clips `totalUSD` to the same trailing
  30-day window as the vendor header (`Day.last30Start`, today−29 through
  today) before summing — otherwise a key's 30d cell could carry one more
  day of cost than the header total above it and systematically exceed it.
- **OpenRouter**: unchanged; `todayUSD`/`mtdUSD` = nil.
- UTC day boundaries throughout, matching the rest of the app (`Day.utcToday`).

## Edge cases

- Day 1 of month: MTD == today. Fine.
- Per-key columns won't always sum exactly to the header totals (header today
  uses max(activity, live-delta); Anthropic per-key is estimated; feeds lag).
  Accepted — same situation as the current 30-day column.
- Old daemon + new app: `today_usd`/`mtd_usd` are NULL → app shows the
  single-column layout for that vendor (same rendering path as OpenRouter).
  New daemon + old app: extra columns ignored. No crash either direction.
- Config wrote `last30Days` then opened by an older build: `AppConfig.load`
  falls back to defaults on decode failure (existing behavior, acceptable).

## Testing (Core — `cd Core && swift test` must stay green)

- Provider fixture tests (recorded JSON): per-day allocation correctness,
  today/MTD/30d split with fixed `now`, month-boundary case (e.g. now = 1st,
  MTD == today only), unattributed-cost spreading per day, zero-weight day
  fallback.
- UsageStore: round-trip of new `key_totals` columns incl. NULLs;
  `last30USD` calculation (30-day window edges, today max-correction).
- Migration test: v4 → v5 upgrade preserves existing rows.
- Menu bar title formatting for `.last30Days` lives in the App target (thin,
  not unit-tested) but the `Summary.last30USD` number it displays is
  Core-tested.
