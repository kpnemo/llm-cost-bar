# Per-key Today/MTD/30d Columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-API-key rows in the dropdown show three colored columns (today | MTD | 30d) aligned under three matching vendor-header totals; the menu bar gains a "Last 30 days" display option.

**Architecture:** Providers keep their single 30-day fetch but stop flattening the per-day dimension, returning `KeyTotal` with new optional `todayUSD`/`mtdUSD`. A v5 migration adds nullable columns to `key_totals`. `UsageStore` computes a new vendor-level `last30USD` the same live-corrected way MTD is computed. The App renders fixed-width numeric columns so header totals and key rows align without a shared grid.

**Tech Stack:** Swift 5.9+, SwiftPM (Core), GRDB/SQLite, SwiftUI MenuBarExtra, XCTest with `FakeHTTP` recorded-JSON fixtures.

**Spec:** `docs/superpowers/specs/2026-07-20-per-key-columns-design.md`

Working dir for all `swift` commands: `Core/`. Run tests with `cd Core && swift test`.

---

### Task 1: KeyTotal fields + protocol signature (plumbing)

`fetchKeyTotals` needs an injectable `now` for month-boundary tests. Default-arg
witnesses satisfy Swift protocols, so concrete types use `now: Date = Date()`.

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/Models.swift:25-29` (KeyTotal)
- Modify: `Core/Sources/LLMCostBarCore/VendorProvider.swift:8,12`
- Modify: `Core/Sources/LLMCostBarCore/OpenRouterProvider.swift:71`
- Modify: `Core/Sources/LLMCostBarCore/AnthropicProvider.swift:134-136`
- Modify: `Core/Sources/LLMCostBarCore/OpenAIProvider.swift:145`
- Modify: `Core/Sources/LLMCostBarCore/SyncEngine.swift:93`
- Modify: any fake providers in `Core/Tests/LLMCostBarCoreTests/SyncEngineTests.swift` that implement `fetchKeyTotals`

- [ ] **Step 1: Extend KeyTotal** (Models.swift)

```swift
/// One API key's spend. totalUSD window depends on the vendor: OpenRouter
/// lifetime, OpenAI real 30-day dollars, Anthropic 30-day estimates.
/// todayUSD/mtdUSD are nil when the vendor has no per-day key data (OpenRouter).
public struct KeyTotal: Equatable, Sendable {
    public var apiKeyID: String
    public var totalUSD: Double
    public var todayUSD: Double?
    public var mtdUSD: Double?
    public init(apiKeyID: String, totalUSD: Double, todayUSD: Double? = nil, mtdUSD: Double? = nil) {
        self.apiKeyID = apiKeyID; self.totalUSD = totalUSD
        self.todayUSD = todayUSD; self.mtdUSD = mtdUSD
    }
}
```

- [ ] **Step 2: Change protocol signature** (VendorProvider.swift)

```swift
    func fetchKeyTotals(now: Date) async throws -> [KeyTotal]  // per-key spend windows; [] if unsupported
```
and the default implementation:
```swift
public extension VendorProvider {
    func fetchKeyTotals(now: Date) async throws -> [KeyTotal] { [] }
}
```

- [ ] **Step 3: Update conformances.** OpenRouterProvider: `public func fetchKeyTotals(now: Date = Date()) async throws -> [KeyTotal]` (body unchanged — lifetime totals, nil today/mtd via default init args). AnthropicProvider: change `public func fetchKeyTotals() async throws` to `public func fetchKeyTotals(now: Date = Date()) async throws` and delete the local `let now = Date()` line. OpenAIProvider: same signature change; replace its internal `Date()` in `costs(startingDaysAgo: 30, now: Date(), ...)` with `now`.

- [ ] **Step 4: Update SyncEngine call site** (SyncEngine.swift:93):

```swift
            let totals = try await withRetry(sleeper: sleeper) { try await provider.fetchKeyTotals(now: Date()) }
```

- [ ] **Step 5: Fix any test fakes.** In SyncEngineTests.swift, if a fake provider implements `fetchKeyTotals()`, change it to `fetchKeyTotals(now: Date)`.

- [ ] **Step 6: Run tests**

Run: `cd Core && swift test`
Expected: PASS (behavior unchanged; existing key-total tests still call with the default `now`).

- [ ] **Step 7: Commit** — `git add -A && git commit -m "refactor: KeyTotal gains today/MTD windows; fetchKeyTotals takes now"`

---

### Task 2: DB migration v5 + store write/read of new columns

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/Database.swift` (add migration after v4)
- Modify: `Core/Sources/LLMCostBarCore/UsageStore.swift:10-14` (KeySpend), `:97-109` (upsertKeyTotals), `:226-230` (keys query)
- Test: `Core/Tests/LLMCostBarCoreTests/UsageStoreTests.swift`

- [ ] **Step 1: Write failing tests** (UsageStoreTests.swift — follow the file's existing setup helper for creating an in-memory store)

```swift
    func testKeyTotalWindowsRoundTripAndMTDOrdering() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q)
        let store = UsageStore(db: q)
        try store.upsertKeyTotals(vendor: "anthropic", accountID: "a", totals: [
            KeyTotal(apiKeyID: "small-total-big-mtd", totalUSD: 5, todayUSD: 1, mtdUSD: 4),
            KeyTotal(apiKeyID: "big-total-small-mtd", totalUSD: 9, todayUSD: 0, mtdUSD: 2),
        ])
        // OpenRouter-style: no windows → NULLs round-trip as nil
        try store.upsertKeyTotals(vendor: "openrouter", accountID: "o", totals: [
            KeyTotal(apiKeyID: "or-key", totalUSD: 7),
        ])
        let vendors = try store.vendorSummaries(today: "2026-07-20", monthPrefix: "2026-07",
                                                last30Start: "2026-06-21")
        let anth = vendors.first { $0.vendor == "anthropic" }!.topKeys
        XCTAssertEqual(anth.map(\.apiKeyID), ["small-total-big-mtd", "big-total-small-mtd"],
                       "ordering must be by MTD desc, not total")
        XCTAssertEqual(anth[0].todayUSD, 1); XCTAssertEqual(anth[0].mtdUSD, 4)
        let or = vendors.first { $0.vendor == "openrouter" }!.topKeys
        XCTAssertNil(or[0].todayUSD); XCTAssertNil(or[0].mtdUSD)
        XCTAssertEqual(or[0].totalUSD, 7)
    }

    func testV5MigrationPreservesExistingKeyTotals() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q, upTo: "v4-usage-snapshots")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO key_totals (vendor, account_id, api_key_id, total_usd, fetched_at)
                VALUES ('openrouter','a','k',5.0,'2026-07-19T00:00:00Z')
                """)
        }
        try Database.migrator.migrate(q)
        let row = try q.read { try Row.fetchOne($0, sql: "SELECT * FROM key_totals")! }
        XCTAssertEqual(row["total_usd"] as Double, 5.0)
        XCTAssertNil(row["today_usd"] as Double?)
        XCTAssertNil(row["mtd_usd"] as Double?)
    }
```
Note: `vendorSummaries` gains the `last30Start:` argument in Task 3 — for THIS task write the test calls WITHOUT it (`vendorSummaries(today:monthPrefix:)`) and add the argument in Task 3 when the signature changes. `import GRDB` is needed for `DatabaseQueue`/`Row` if the test file doesn't already have it.

- [ ] **Step 2: Run to verify failure** — `cd Core && swift test --filter UsageStoreTests`
Expected: FAIL (no such column today_usd / no KeySpend fields / extra args).

- [ ] **Step 3: Implement.** Database.swift, after the v4 block:

```swift
        m.registerMigration("v5-key-daily") { db in
            try db.execute(sql: """
            ALTER TABLE key_totals ADD COLUMN today_usd REAL;
            ALTER TABLE key_totals ADD COLUMN mtd_usd REAL;
            """)
        }
```

UsageStore.swift — KeySpend:

```swift
public struct KeySpend: Equatable, Hashable, Sendable {
    public var accountID: String
    public var apiKeyID: String
    public var totalUSD: Double   // 30-day (Anthropic/OpenAI) or lifetime (OpenRouter)
    public var todayUSD: Double?  // nil when the vendor has no per-day key data
    public var mtdUSD: Double?
}
```

upsertKeyTotals insert:

```swift
                try db.execute(sql: """
                    INSERT OR REPLACE INTO key_totals
                    (vendor, account_id, api_key_id, total_usd, today_usd, mtd_usd, fetched_at)
                    VALUES (?,?,?,?,?,?,?)
                    """, arguments: [vendor, accountID, t.apiKeyID, t.totalUSD, t.todayUSD, t.mtdUSD,
                                     ISO8601DateFormatter().string(from: now)])
```

keys query in vendorSummaries (order by MTD when present, else total):

```swift
                let keys = try Row.fetchAll(db, sql: """
                    SELECT account_id, api_key_id, total_usd, today_usd, mtd_usd FROM key_totals
                    WHERE vendor = ? AND total_usd > 0
                    ORDER BY COALESCE(mtd_usd, total_usd) DESC LIMIT 5
                    """, arguments: [vendor])
                    .map { KeySpend(accountID: $0["account_id"], apiKeyID: $0["api_key_id"],
                                    totalUSD: $0["total_usd"], todayUSD: $0["today_usd"], mtdUSD: $0["mtd_usd"]) }
```

- [ ] **Step 4: Run tests** — `cd Core && swift test`
Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: key_totals stores per-key today/MTD (v5 migration)"`

---

### Task 3: Vendor-level last30USD in UsageStore + Summary

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/UsageStore.swift:4-8` (Summary), `:16-24` (VendorSummary), `:171-180` (summary), `:192-235` (vendorSummaries)
- Test: `Core/Tests/LLMCostBarCoreTests/UsageStoreTests.swift`

- [ ] **Step 1: Write failing test**

```swift
    func testLast30SumIsLiveCorrectedAndWindowed() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q)
        let store = UsageStore(db: q)
        try store.upsertUsage([
            // inside window (== last30Start, inclusive)
            UsageRecord(vendor: "openrouter", accountID: "a", apiKeyID: "k", model: "m",
                        day: "2026-06-21", requests: 0, tokensIn: 0, tokensOut: 0, costUSD: 3),
            // outside window (day before last30Start)
            UsageRecord(vendor: "openrouter", accountID: "a", apiKeyID: "k", model: "m",
                        day: "2026-06-20", requests: 0, tokensIn: 0, tokensOut: 0, costUSD: 100),
            // today — must NOT be double counted: excluded from the SUM, added via todayUSD
            UsageRecord(vendor: "openrouter", accountID: "a", apiKeyID: "k", model: "m",
                        day: "2026-07-20", requests: 0, tokensIn: 0, tokensOut: 0, costUSD: 2),
        ])
        let vendors = try store.vendorSummaries(today: "2026-07-20", monthPrefix: "2026-07",
                                                last30Start: "2026-06-21")
        let v = vendors.first { $0.vendor == "openrouter" }!
        XCTAssertEqual(v.todayUSD, 2, accuracy: 0.001)
        XCTAssertEqual(v.last30USD, 5, accuracy: 0.001)   // 3 (window) + 2 (today)
        let s = try store.summary(today: "2026-07-20", monthPrefix: "2026-07", last30Start: "2026-06-21")
        XCTAssertEqual(s.last30USD, 5, accuracy: 0.001)
    }
```
Also NOW add `last30Start: "2026-06-21"` to the Task 2 test's `vendorSummaries` call.

- [ ] **Step 2: Run to verify failure** — `swift test --filter UsageStoreTests`. Expected: FAIL (no last30Start / last30USD).

- [ ] **Step 3: Implement.**

```swift
public struct Summary: Equatable, Sendable {
    public var todayUSD: Double
    public var monthUSD: Double
    public var last30USD: Double
    public init(todayUSD: Double, monthUSD: Double, last30USD: Double) {
        self.todayUSD = todayUSD; self.monthUSD = monthUSD; self.last30USD = last30USD
    }
}
```

`VendorSummary` gains `public var last30USD: Double` (insert after `monthUSD`).

`summary(today:monthPrefix:last30Start:)` — add the parameter, pass through, and:

```swift
        return Summary(todayUSD: vendors.reduce(0) { $0 + $1.todayUSD },
                       monthUSD: vendors.reduce(0) { $0 + $1.monthUSD },
                       last30USD: vendors.reduce(0) { $0 + $1.last30USD })
```

`vendorSummaries(today:monthPrefix:last30Start:)` — after the `monthBeforeToday` query add:

```swift
                let last30BeforeToday = try Double.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(cost_usd),0) FROM usage_daily
                    WHERE vendor = ? AND day >= ? AND day < ?
                    """, arguments: [vendor, last30Start, today]) ?? 0
```

and include `last30USD: last30BeforeToday + t` in the returned `VendorSummary`. Fix all other construction/call sites the compiler flags (StoreModel is App-side — Task 7; Daemon if it calls these).

- [ ] **Step 4: Run tests** — `cd Core && swift test`. Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: vendor + summary last30USD (live-corrected 30-day window)"`

---

### Task 4: Anthropic per-day allocation → today/MTD/30d per key

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/AnthropicProvider.swift:134-209` (fetchKeyTotals)
- Test: `Core/Tests/LLMCostBarCoreTests/AnthropicProviderTests.swift`

- [ ] **Step 1: Write failing tests.** Add a shared helper at the top of the test class:

```swift
    /// Fixed clock: 2026-07-01T12:00:00Z — makes MTD/today assertions month-boundary-proof.
    let julyFirstNoon = Date(timeIntervalSince1970: 1_782_907_200)
```

```swift
    // Month boundary: usage/cost on 06-30 (key A) and 07-01 (key B), now = 07-01.
    // Day-scoped allocation: 06-30's $10 must go to A only (B has zero weight that
    // day despite a bigger window weight), 07-01's $20 to B only.
    let boundaryUsageJSON = #"""
    {"data":[
      {"starting_at":"2026-06-30T00:00:00Z","ending_at":"2026-07-01T00:00:00Z","results":[
        {"api_key_id":"apikey_A","model":"claude-opus-4-8","uncached_input_tokens":1000}
      ]},
      {"starting_at":"2026-07-01T00:00:00Z","ending_at":"2026-07-02T00:00:00Z","results":[
        {"api_key_id":"apikey_B","model":"claude-opus-4-8","uncached_input_tokens":2000}
      ]}
    ],"has_more":false,"next_page":null}
    """#
    let boundaryCostJSON = #"""
    {"data":[
      {"starting_at":"2026-06-30T00:00:00Z","ending_at":"2026-07-01T00:00:00Z","results":[
        {"currency":"USD","amount":"1000","model":"claude-opus-4-8","description":"opus"}
      ]},
      {"starting_at":"2026-07-01T00:00:00Z","ending_at":"2026-07-02T00:00:00Z","results":[
        {"currency":"USD","amount":"2000","model":"claude-opus-4-8","description":"opus"}
      ]}
    ],"has_more":false,"next_page":null}
    """#

    func testKeyTotalsSplitTodayMTDAcrossMonthBoundary() async throws {
        let http = FakeHTTP()
        http.responses["usage_report"] = (boundaryUsageJSON, 200)
        http.responses["cost_report"] = (boundaryCostJSON, 200)
        http.responses["api_keys"] = (keysListJSON, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: julyFirstNoon)
        XCTAssertEqual(totals.count, 2)
        let a = totals.first { $0.apiKeyID == "prod" }!        // apikey_A, named
        XCTAssertEqual(a.totalUSD, 10.0, accuracy: 0.01)
        XCTAssertEqual(a.mtdUSD ?? -1, 0.0, accuracy: 0.01)    // 06-30 is last month
        XCTAssertEqual(a.todayUSD ?? -1, 0.0, accuracy: 0.01)
        let b = totals.first { $0.apiKeyID == "apikey_B" }!
        XCTAssertEqual(b.totalUSD, 20.0, accuracy: 0.01)
        XCTAssertEqual(b.mtdUSD ?? -1, 20.0, accuracy: 0.01)   // MTD == today on the 1st
        XCTAssertEqual(b.todayUSD ?? -1, 20.0, accuracy: 0.01)
        XCTAssertEqual(totals[0].apiKeyID, "apikey_B", "sorted by MTD desc")
    }

    // A day with cost but no usage rows at all falls back to window-wide weights.
    func testZeroWeightDayFallsBackToWindowWeights() async throws {
        let usageOnly0630 = #"""
        {"data":[
          {"starting_at":"2026-06-30T00:00:00Z","ending_at":"2026-07-01T00:00:00Z","results":[
            {"api_key_id":"apikey_A","model":"claude-opus-4-8","uncached_input_tokens":1000}
          ]}
        ],"has_more":false,"next_page":null}
        """#
        let http = FakeHTTP()
        http.responses["usage_report"] = (usageOnly0630, 200)
        http.responses["cost_report"] = (boundaryCostJSON, 200)   // cost on both days
        http.responses["api_keys"] = (keysListJSON, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: julyFirstNoon)
        let a = totals.first { $0.apiKeyID == "prod" }!
        XCTAssertEqual(a.totalUSD, 30.0, accuracy: 0.01)   // both days land on A
        XCTAssertEqual(a.mtdUSD ?? -1, 20.0, accuracy: 0.01)
        XCTAssertEqual(a.todayUSD ?? -1, 20.0, accuracy: 0.01)
    }
```

Also update the three existing key-total tests (`testKeyTotalsAllocateCostByWeightedTokens`, `testKeyTotalsEmptyWhenNoUsage`, `testKeyNamesFailureFallsBackToIDs`) to call `fetchKeyTotals(now: Date(timeIntervalSince1970: 1_784_548_800))` (= 2026-07-20T12:00:00Z, same month as their 07-18 fixtures) and extend the first with:

```swift
        XCTAssertEqual(totals[0].mtdUSD ?? -1, 16.5, accuracy: 0.01)  // whole window in-month
        XCTAssertEqual(totals[0].todayUSD ?? -1, 0.0, accuracy: 0.01) // fixtures are 07-18, now is 07-20
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter AnthropicProviderTests`. Expected: FAIL (extra arg / nil mtd).

- [ ] **Step 3: Implement.** Replace the body of `fetchKeyTotals` (keep steps 1-2 fetch loops, restructure aggregation; `weight(_:)`, `normalizeModel`, `fetchKeyNames` unchanged):

```swift
    public func fetchKeyTotals(now: Date = Date()) async throws -> [KeyTotal] {
        let days = 30
        let startDay = Day.utcToday(now: now.addingTimeInterval(-Double(days) * 86400))
        let endDay = Day.utcToday(now: now.addingTimeInterval(86400))

        // 1) weighted tokens per (day, normalized model, api_key_id)
        var weights: [String: [String: [String: Double]]] = [:]   // day → model → key → weight
        // ... same pagination loop as today, but keyed by bucket day:
        //     let day = String(bucket.starting_at.prefix(10))
        //     weights[day, default: [:]][model, default: [:]][row.api_key_id ?? "workbench", default: 0] += w

        // 2) real dollars per (day, normalized model)
        var costByDayModel: [String: [String: Double]] = [:]
        for r in try await fetchUsage(sinceDaysAgo: days, now: now) {
            costByDayModel[r.day, default: [:]][Self.normalizeModel(r.model), default: 0] += r.costUSD
        }

        // window-wide per-key weights: fallback pool for days with cost but no usage rows
        var windowKeyWeights: [String: Double] = [:]
        for dayWeights in weights.values {
            for keyWeights in dayWeights.values {
                for (key, w) in keyWeights { windowKeyWeights[key, default: 0] += w }
            }
        }

        // 3) allocate day by day; != 0 so negative refunds are spread too
        var perKeyDay: [String: [String: Double]] = [:]           // key → day → usd
        for (day, models) in costByDayModel {
            var unattributed = 0.0
            for (model, cost) in models {
                if let keyWeights = weights[day]?[model], !keyWeights.isEmpty {
                    let total = keyWeights.values.reduce(0, +)
                    for (key, w) in keyWeights { perKeyDay[key, default: [:]][day, default: 0] += cost * w / total }
                } else {
                    unattributed += cost
                }
            }
            if unattributed != 0 {
                var dayKeyWeights: [String: Double] = [:]
                for keyWeights in (weights[day] ?? [:]).values {
                    for (key, w) in keyWeights { dayKeyWeights[key, default: 0] += w }
                }
                let pool = dayKeyWeights.isEmpty ? windowKeyWeights : dayKeyWeights
                let total = pool.values.reduce(0, +)
                if total > 0 {
                    for (key, w) in pool { perKeyDay[key, default: [:]][day, default: 0] += unattributed * w / total }
                }
            }
        }
        guard !perKeyDay.isEmpty else { return [] }

        // 4) window sums + id → name mapping (merge same-named keys)
        let today = Day.utcToday(now: now)
        let monthStart = Day.utcMonthPrefix(now: now) + "-01"
        let names = (try? await fetchKeyNames()) ?? [:]
        var byName: [String: (total: Double, mtd: Double, today: Double)] = [:]
        for (id, dayMap) in perKeyDay {
            let name = names[id] ?? id
            var agg = byName[name] ?? (0, 0, 0)
            for (day, usd) in dayMap {
                agg.total += usd
                if day >= monthStart { agg.mtd += usd }
                if day == today { agg.today += usd }
            }
            byName[name] = agg
        }
        return byName.map { KeyTotal(apiKeyID: $0.key, totalUSD: $0.value.total,
                                     todayUSD: $0.value.today, mtdUSD: $0.value.mtd) }
            .sorted { ($0.mtdUSD ?? 0) > ($1.mtdUSD ?? 0) }
    }
```
(The `// ...` in step 1 keeps the existing repeat/while pagination code — only the accumulation line changes to the day-keyed form shown.)

- [ ] **Step 4: Run tests** — `swift test --filter AnthropicProviderTests`, then full `swift test`. Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: Anthropic per-key estimates split by day (today/MTD/30d)"`

---

### Task 5: OpenAI per-day → today/MTD/30d per key

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/OpenAIProvider.swift:145-157`
- Test: `Core/Tests/LLMCostBarCoreTests/OpenAIProviderTests.swift`

- [ ] **Step 1: Write failing test** (mirror the existing key-totals test style in that file; buckets use unix start_time)

```swift
    // 1782777600 = 2026-06-30T00:00Z, 1782864000 = 2026-07-01T00:00Z.
    // now = 2026-07-01T12:00Z → key_B is all-MTD/all-today; key_A splits.
    func testKeyTotalsSplitTodayMTDAcrossMonthBoundary() async throws {
        let json = #"""
        {"data":[
          {"start_time":1782777600,"results":[
            {"amount":{"value":3.0,"currency":"usd"},"api_key_id":"key_A"}
          ]},
          {"start_time":1782864000,"results":[
            {"amount":{"value":2.0,"currency":"usd"},"api_key_id":"key_A"},
            {"amount":{"value":5.0,"currency":"usd"},"api_key_id":"key_B"}
          ]}
        ],"has_more":false,"next_page":null}
        """#
        let http = FakeHTTP()
        http.responses["organization/costs"] = (json, 200)
        // name lookups fail-soft → raw ids (match existing tests' pattern for projects/keys fixtures)
        http.responses["organization/projects"] = (#"{"error":"nope"}"#, 500)
        let totals = try await makeProvider(http).fetchKeyTotals(now: Date(timeIntervalSince1970: 1_782_907_200))
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].apiKeyID, "key_B", "sorted by MTD desc")
        XCTAssertEqual(totals[0].totalUSD, 5.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].mtdUSD ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].todayUSD ?? -1, 5.0, accuracy: 0.001)
        let a = totals.first { $0.apiKeyID == "key_A" }!
        XCTAssertEqual(a.totalUSD, 5.0, accuracy: 0.001)
        XCTAssertEqual(a.mtdUSD ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(a.todayUSD ?? -1, 2.0, accuracy: 0.001)
    }
```
Adjust the fake-name-lookup fixture keys to whatever the existing OpenAI key-total tests already stub (keep consistent with `FakeHTTP` most-specific-substring matching). Update existing `fetchKeyTotals()` calls in this file to pass a fixed `now` consistent with their fixtures, and extend one with mtd/today assertions the same way as Task 4 did.

- [ ] **Step 2: Run to verify failure** — `swift test --filter OpenAIProviderTests`. Expected: FAIL.

- [ ] **Step 3: Implement** — replace `fetchKeyTotals`:

```swift
    /// Real per-day per-key dollars over the last 30 days (group_by=api_key_id).
    /// Rows without a key (dashboard/playground) are skipped, not shown as a phantom key.
    public func fetchKeyTotals(now: Date = Date()) async throws -> [KeyTotal] {
        var perKeyDay: [String: [String: Double]] = [:]           // key → day → usd
        try await costs(startingDaysAgo: 30, now: now, groupBy: "api_key_id") { day, row in
            guard let keyID = row.api_key_id, let usd = row.amount?.value?.double, usd != 0 else { return }
            perKeyDay[keyID, default: [:]][day, default: 0] += usd
        }
        guard !perKeyDay.isEmpty else { return [] }
        let today = Day.utcToday(now: now)
        let monthStart = Day.utcMonthPrefix(now: now) + "-01"
        let names = (try? await fetchKeyNames()) ?? [:]
        var byName: [String: (total: Double, mtd: Double, today: Double)] = [:]
        for (id, dayMap) in perKeyDay {
            let name = names[id] ?? id
            var agg = byName[name] ?? (0, 0, 0)
            for (day, usd) in dayMap {
                agg.total += usd
                if day >= monthStart { agg.mtd += usd }
                if day == today { agg.today += usd }
            }
            byName[name] = agg
        }
        return byName.map { KeyTotal(apiKeyID: $0.key, totalUSD: $0.value.total,
                                     todayUSD: $0.value.today, mtdUSD: $0.value.mtd) }
            .sorted { ($0.mtdUSD ?? 0) > ($1.mtdUSD ?? 0) }
    }
```

- [ ] **Step 4: Run tests** — `swift test`. Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: OpenAI per-key real dollars split by day (today/MTD/30d)"`

---

### Task 6: MenuBarDisplay.last30Days config case

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/AppConfig.swift:3-5`
- Test: `Core/Tests/LLMCostBarCoreTests/AppConfigTests.swift`

- [ ] **Step 1: Write failing test**

```swift
    func testLast30DaysDisplayRoundTrips() throws {
        var cfg = AppConfig()
        cfg.menuBarDisplay = .last30Days
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try cfg.save(to: url)
        XCTAssertEqual(AppConfig.load(from: url).menuBarDisplay, .last30Days)
    }
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter AppConfigTests`. Expected: FAIL (no member last30Days).

- [ ] **Step 3: Implement**

```swift
public enum MenuBarDisplay: String, Codable, CaseIterable, Sendable {
    case iconOnly, today, monthToDate, last30Days
}
```

- [ ] **Step 4: Run tests** — `swift test`. Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: menu bar display option — last 30 days"`

---

### Task 7: App UI — header totals grid, three-column key table, settings option

No unit tests (App target has none — Core-tested logic only); verified by build + manual run.

**Files:**
- Modify: `App/StoreModel.swift:50-52` (refresh), `:69-75` (menuBarTitle)
- Modify: `App/SettingsView.swift:153-157` (picker)
- Modify: `App/DropdownView.swift` (width, VendorCard header, expandedContent)

- [ ] **Step 1: StoreModel.** In `refresh()`:

```swift
        let today = Day.utcToday(), month = Day.utcMonthPrefix()
        let last30Start = Day.utcToday(now: Date().addingTimeInterval(-29 * 86400))
        summary = (try? store.summary(today: today, monthPrefix: month, last30Start: last30Start)) ?? summary
        vendors = (try? store.vendorSummaries(today: today, monthPrefix: month, last30Start: last30Start)) ?? vendors
```
(`summary` default value at the top of the class becomes `Summary(todayUSD: 0, monthUSD: 0, last30USD: 0)`.) In `menuBarTitle` add:

```swift
        case .last30Days: String(format: "$%.2f", summary.last30USD)
```

- [ ] **Step 2: SettingsView picker** — add after the MTD option:

```swift
                Text("Last 30 days").tag(MenuBarDisplay.last30Days)
```

- [ ] **Step 3: DropdownView — width and top summary.** `.frame(width: 380)` → `.frame(width: 440)`.

- [ ] **Step 4: DropdownView — VendorCard header.** Replace the header `HStack` (lines 92-111) with:

```swift
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption).foregroundStyle(.tertiary)
                if let icon = Self.vendorIcon(vendor.vendor) {
                    Image(nsImage: icon)
                        .resizable().interpolation(.high)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 7 }
                }
                Text(vendorDisplayName).font(.title3).bold()
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                statColumn(usd(vendor.todayUSD), label: "today", color: .blue,
                           dim: vendor.todayUSD == 0)
                statColumn(usd(vendor.monthUSD), label: "MTD", color: .primary)
                statColumn(usd(vendor.last30USD), label: "30d", color: .secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
```

with helpers on `VendorCard`:

```swift
    static let statWidth: CGFloat = 76

    private func statColumn(_ amount: String, label: String, color: Color, dim: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(amount).font(.body.weight(.bold)).monospacedDigit()
                .foregroundStyle(color).opacity(dim ? 0.45 : 1)
            Text(label).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(width: Self.statWidth, alignment: .trailing)
    }
```
(`Color` needs `import SwiftUI` — already imported.) The collapsed-state `Text("today …")` is gone: collapsed and expanded share this header.

- [ ] **Step 5: DropdownView — expandedContent.** Replace the today/hover block (lines 125-131) with a hover-only readout in a fixed-height slot so the chart doesn't jump:

```swift
            Group {
                if let day = hoverDay, let point = filledSeries.first(where: { $0.day == day }) {
                    Text("\(prettyDay(day)) · \(usd(point.costUSD))")
                        .font(.subheadline).foregroundStyle(.primary)
                } else {
                    Text(" ").font(.subheadline)
                }
            }
```

Replace the key-list caption + rows (lines 196-212) with:

```swift
            // OpenRouter reports lifetime per-key totals only (no daily data) →
            // single column; OpenAI real per-day dollars; Anthropic per-day
            // estimates allocated from org cost by token share.
            if !vendor.topKeys.isEmpty {
                Text(vendor.vendor == "anthropic" ? "API keys · est. spend"
                     : vendor.vendor == "openai" ? "API keys"
                     : "API keys · total spend")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            let hasWindows = vendor.topKeys.contains { $0.mtdUSD != nil }
            ForEach(vendor.topKeys, id: \.self) { k in
                HStack {
                    Text(k.apiKeyID).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if hasWindows {
                        keyCell(k.todayUSD, color: .blue)
                        keyCell(k.mtdUSD, color: .primary)
                        keyCell(k.totalUSD, color: .secondary)
                    } else {
                        Text(usd(k.totalUSD)).font(.subheadline).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
```

with helper:

```swift
    /// nil → "—" (old daemon rows mixed with new); zero todays render dim.
    private func keyCell(_ value: Double?, color: Color) -> some View {
        Text(value.map(usd) ?? "—")
            .font(.subheadline).monospacedDigit()
            .foregroundStyle(color)
            .opacity((value ?? 1) == 0 ? 0.45 : 1)
            .frame(width: Self.statWidth, alignment: .trailing)
    }
```

- [ ] **Step 6: Build**

Run: `xcodegen generate && xcodebuild -scheme LLMCostBar build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`. Fix any missed call sites (e.g. Daemon if it calls `summary`/`vendorSummaries`).

- [ ] **Step 7: Core regression** — `cd Core && swift test`. Expected: PASS.

- [ ] **Step 8: Commit** — `git commit -am "feat: dropdown shows per-key today/MTD/30d columns + header totals; menu bar 30d option"`

---

### Task 8: Final verification

- [ ] **Step 1:** `cd Core && swift test` → all green (report count).
- [ ] **Step 2:** `xcodegen generate && xcodebuild -scheme LLMCostBar build` → BUILD SUCCEEDED.
- [ ] **Step 3:** Install locally for the user's visual check: `scripts/install_local.sh`, then open the dropdown — verify: three aligned columns on Anthropic/OpenAI, single column on OpenRouter, three header totals per card, Settings shows "Last 30 days" and the menu bar number follows it.
- [ ] **Step 4:** Update `Models.swift`/`UsageStore.swift` doc comments if any still say "lifetime" ambiguously (KeyTotal comment was updated in Task 1 — confirm).
- [ ] **Step 5:** Final commit if anything changed; keep branch `feature/per-key-columns` for the user's review/merge decision (superpowers:finishing-a-development-branch).
