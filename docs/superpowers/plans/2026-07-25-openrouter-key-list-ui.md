# OpenRouter Key List UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-key progress-bar/caption UI with aligned single-line rows, a fixed hover inspector line, and click-to-pin detail strips, per `docs/superpowers/specs/2026-07-25-openrouter-key-list-ui-design.md`.

**Architecture:** All logic lives in the SwiftPM package `LLMCostBarCore` (merge semantics, lifetime field + migration, detail-text composition, metadata gate); `App/DropdownView.swift` only renders. Vendor I/O stays in `OpenRouterProvider`.

**Tech Stack:** Swift 5.9+, GRDB (SQLite), SwiftUI (macOS 14 MenuBarExtra), XCTest. Test with `cd Core && swift test`; full build `xcodegen generate && xcodebuild -scheme LLMCostBar build CODE_SIGNING_ALLOWED=NO`.

**Branch:** create `feature/key-list-ui` from `develop` before Task 1.

---

### Task 1: `lifetimeUSD` field + nil-correct merge semantics (Core models)

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/Models.swift` (KeyTotal struct + `mergedByName`)
- Test: `Core/Tests/LLMCostBarCoreTests/KeyTotalAggregateTests.swift` (append tests)

- [ ] **Step 1: Write failing tests** — append to `KeyTotalAggregateTests.swift`:

```swift
    // MARK: mergedByName semantics (spec 2026-07-25, merge table)

    func testMergePreservesNilWindowsAndSumsNonNil() {
        let merged = KeyTotal.mergedByName([
            KeyTotal(apiKeyID: "k", totalUSD: 1, todayUSD: nil, mtdUSD: nil),
            KeyTotal(apiKeyID: "k", totalUSD: 2, todayUSD: nil, mtdUSD: nil),
        ])
        XCTAssertNil(merged[0].todayUSD, "all-nil windows must stay nil, not become 0")
        XCTAssertNil(merged[0].mtdUSD)
        let mixed = KeyTotal.mergedByName([
            KeyTotal(apiKeyID: "k", totalUSD: 1, todayUSD: 2.0, mtdUSD: nil),
            KeyTotal(apiKeyID: "k", totalUSD: 2, todayUSD: nil, mtdUSD: 3.0),
        ])
        XCTAssertEqual(mixed[0].todayUSD ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(mixed[0].mtdUSD ?? -1, 3.0, accuracy: 0.001)
    }

    func testMergeLifetimeIsAllOrNothing() {
        let partial = KeyTotal.mergedByName([
            KeyTotal(apiKeyID: "k", totalUSD: 1, lifetimeUSD: 5.0),
            KeyTotal(apiKeyID: "k", totalUSD: 2, lifetimeUSD: nil),
        ])
        XCTAssertNil(partial[0].lifetimeUSD, "partial lifetime must not render as exact")
        let full = KeyTotal.mergedByName([
            KeyTotal(apiKeyID: "k", totalUSD: 1, lifetimeUSD: 5.0),
            KeyTotal(apiKeyID: "k", totalUSD: 2, lifetimeUSD: 7.0),
        ])
        XCTAssertEqual(full[0].lifetimeUSD ?? -1, 12.0, accuracy: 0.001)
    }

    func testMergeCouplesRemainingAndResetToLimit() {
        // Any unlimited sibling → whole group unlimited: remaining and reset must clear.
        let anyUnlimited = KeyTotal.mergedByName([
            KeyTotal(apiKeyID: "k", totalUSD: 1, limitUSD: 20, limitRemainingUSD: 5, limitReset: "weekly"),
            KeyTotal(apiKeyID: "k", totalUSD: 2),
        ])
        XCTAssertNil(anyUnlimited[0].limitUSD)
        XCTAssertNil(anyUnlimited[0].limitRemainingUSD, "no-limit row must never carry remaining")
        XCTAssertNil(anyUnlimited[0].limitReset)
        // Unknown remaining on one sibling → remaining nil (never coerced to 0), limit still sums.
        let unknownRemaining = KeyTotal.mergedByName([
            KeyTotal(apiKeyID: "k", totalUSD: 1, limitUSD: 20, limitRemainingUSD: nil, limitReset: "weekly"),
            KeyTotal(apiKeyID: "k", totalUSD: 2, limitUSD: 10, limitRemainingUSD: 4, limitReset: "weekly"),
        ])
        XCTAssertEqual(unknownRemaining[0].limitUSD ?? -1, 30.0, accuracy: 0.001)
        XCTAssertNil(unknownRemaining[0].limitRemainingUSD)
        XCTAssertEqual(unknownRemaining[0].limitReset, "weekly")
        // Differing reset intervals → reset nil.
        let mixedReset = KeyTotal.mergedByName([
            KeyTotal(apiKeyID: "k", totalUSD: 1, limitUSD: 20, limitRemainingUSD: 5, limitReset: "weekly"),
            KeyTotal(apiKeyID: "k", totalUSD: 2, limitUSD: 10, limitRemainingUSD: 4, limitReset: "daily"),
        ])
        XCTAssertEqual(mixedReset[0].limitRemainingUSD ?? -1, 9.0, accuracy: 0.001)
        XCTAssertNil(mixedReset[0].limitReset)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Core && swift test --filter KeyTotalAggregateTests 2>&1 | tail -5`
Expected: compile error — `lifetimeUSD` doesn't exist yet.

- [ ] **Step 3: Implement.** In `Models.swift`, add `lifetimeUSD` to `KeyTotal` (defaulted so all existing call sites — OpenAI/Anthropic providers, tests — compile unchanged):

```swift
public struct KeyTotal: Equatable, Sendable {
    public var apiKeyID: String
    public var totalUSD: Double
    public var todayUSD: Double?
    public var mtdUSD: Double?
    /// Key budget metadata (OpenRouter): nil limit = unlimited key.
    public var limitUSD: Double?
    public var limitRemainingUSD: Double?
    public var limitReset: String?   // "daily" / "weekly" / "monthly"
    public var disabled: Bool
    public var lifetimeUSD: Double?  // /keys `usage`; nil when vendor doesn't report it
    public init(apiKeyID: String, totalUSD: Double, todayUSD: Double? = nil, mtdUSD: Double? = nil,
                limitUSD: Double? = nil, limitRemainingUSD: Double? = nil, limitReset: String? = nil,
                disabled: Bool = false, lifetimeUSD: Double? = nil) {
        self.apiKeyID = apiKeyID; self.totalUSD = totalUSD
        self.todayUSD = todayUSD; self.mtdUSD = mtdUSD
        self.limitUSD = limitUSD; self.limitRemainingUSD = limitRemainingUSD
        self.limitReset = limitReset; self.disabled = disabled
        self.lifetimeUSD = lifetimeUSD
    }
}
```

Replace `mergedByName` body with the spec's merge table (keep the doc comment, update it):

```swift
    /// Merge rows that share a display name into one (account-local; rows from
    /// different accounts never meet here). Nil means "unknown", and unknown
    /// must never masquerade as a number:
    /// - today/mtd: sum of non-nil, nil only if all nil (0 would fake windows
    ///   onto legacy rows and flip the UI's hasWindows gate)
    /// - lifetime: sum only when every row has it (a partial sum would render
    ///   as an exact total)
    /// - limit: sum only when every row has one; any unlimited sibling makes
    ///   the group unlimited, which also clears remaining + reset
    /// - remaining: within a limited group, sum only when every row has it
    /// - reset: kept only when identical across the group
    /// - disabled: true only when every row is disabled
    static func mergedByName(_ rows: [KeyTotal]) -> [KeyTotal] {
        func sumKeepingNil(_ a: Double?, _ b: Double?) -> Double? {
            if a == nil && b == nil { return nil }
            return (a ?? 0) + (b ?? 0)
        }
        func sumIfBoth(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }
            return a + b
        }
        var byName: [String: KeyTotal] = [:]
        for row in rows {
            guard var agg = byName[row.apiKeyID] else { byName[row.apiKeyID] = row; continue }
            agg.totalUSD += row.totalUSD
            agg.todayUSD = sumKeepingNil(agg.todayUSD, row.todayUSD)
            agg.mtdUSD = sumKeepingNil(agg.mtdUSD, row.mtdUSD)
            agg.lifetimeUSD = sumIfBoth(agg.lifetimeUSD, row.lifetimeUSD)
            agg.limitUSD = sumIfBoth(agg.limitUSD, row.limitUSD)
            if agg.limitUSD == nil {
                agg.limitRemainingUSD = nil
                agg.limitReset = nil
            } else {
                agg.limitRemainingUSD = sumIfBoth(agg.limitRemainingUSD, row.limitRemainingUSD)
                agg.limitReset = agg.limitReset == row.limitReset ? agg.limitReset : nil
            }
            agg.disabled = agg.disabled && row.disabled
            byName[row.apiKeyID] = agg
        }
        return sortedForDisplay(Array(byName.values))
    }
```

- [ ] **Step 4: Run the full Core suite**

Run: `cd Core && swift test 2>&1 | tail -3`
Expected: all pass (existing merge test `testTwoKeysSameDisplayNameMergeIntoOneSummedRow` must still pass).

- [ ] **Step 5: Commit**

```bash
git add Core && git commit -m "core: KeyTotal.lifetimeUSD + nil-correct mergedByName semantics"
```

---

### Task 2: Provider — decode lifetime, merge before visibility filter

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/OpenRouterProvider.swift` (`fetchKeyTotals`)
- Test: `Core/Tests/LLMCostBarCoreTests/OpenRouterProviderTests.swift`

- [ ] **Step 1: Write failing tests** — append inside `OpenRouterProviderTests`:

```swift
    func testKeyTotalsCarryLifetimeUsage() async throws {
        let http = FakeHTTP()
        http.responses["keys"] = (#"""
        {"data":[{"name":"erik","label":"sk-1","hash":"hashLT0001","usage":84.04,
          "usage_daily":20.05,"usage_monthly":38.63,"disabled":false}]}
        """#, 200)
        http.responses["api_key_hash=hashLT0001"] = (#"{"data":[]}"#, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: Date(timeIntervalSince1970: 1_782_907_200))
        XCTAssertEqual(totals[0].lifetimeUSD ?? -1, 84.04, accuracy: 0.001)
    }

    // Spec: merge FIRST, then filter — a zero-spend same-name sibling must still
    // contribute its metadata (lifetime/limit) to the surviving merged row.
    func testZeroSpendSiblingContributesMetadataBeforeFiltering() async throws {
        let http = FakeHTTP()
        http.responses["keys"] = (#"""
        {"data":[
          {"name":"shared","label":"sk-1","hash":"hashMF0001","usage":10.0,
           "usage_daily":1.0,"usage_monthly":1.0,"limit":20.0,"limit_remaining":19.0,"limit_reset":"weekly","disabled":false},
          {"name":"shared","label":"sk-2","hash":"hashMF0002","usage":3.0,
           "usage_daily":0.0,"usage_monthly":0.0,"limit":10.0,"limit_remaining":10.0,"limit_reset":"weekly","disabled":false}
        ]}
        """#, 200)
        http.responses["api_key_hash="] = (#"{"data":[]}"#, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: Date(timeIntervalSince1970: 1_782_907_200))
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].lifetimeUSD ?? -1, 13.0, accuracy: 0.001, "zero-spend sibling's lifetime merged in")
        XCTAssertEqual(totals[0].limitUSD ?? -1, 30.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].limitRemainingUSD ?? -1, 29.0, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter OpenRouterProviderTests 2>&1 | tail -5`
Expected: `testKeyTotalsCarryLifetimeUsage` fails (lifetime nil); sibling test fails (sibling filtered pre-merge).

- [ ] **Step 3: Implement.** In `fetchKeyTotals`, delete the per-key `guard total > 0 || todayUSD > 0 || mtdUSD > 0 else { continue }`, add `lifetimeUSD: key.usage` to the `KeyTotal(...)` append, and filter AFTER merging. The end of the function becomes:

```swift
            rows.append(KeyTotal(apiKeyID: name, totalUSD: total, todayUSD: todayUSD, mtdUSD: mtdUSD,
                                 limitUSD: key.limit, limitRemainingUSD: key.limit_remaining,
                                 limitReset: key.limit_reset, disabled: key.disabled ?? false,
                                 lifetimeUSD: key.usage))
        }
        // Merge BEFORE the visibility filter so a zero-spend same-name sibling
        // still contributes lifetime/limit metadata to the surviving row. Keys
        // without a hash never get here (can't be fetched per-key); a merged
        // group with zero spend in every window stays hidden by design.
        return KeyTotal.mergedByName(rows).filter {
            $0.totalUSD > 0 || ($0.todayUSD ?? 0) > 0 || ($0.mtdUSD ?? 0) > 0
        }
    }
```

- [ ] **Step 4: Run the full Core suite**

Run: `cd Core && swift test 2>&1 | tail -3`
Expected: all pass — including the four pre-existing fetchKeyTotals tests (drop-out, empty, merge, live counters), whose behavior is unchanged by the reorder.

- [ ] **Step 5: Commit**

```bash
git add Core && git commit -m "core: OpenRouter lifetime usage per key; merge same-name keys before visibility filter"
```

---

### Task 3: Store — migration v9, lifetime round-trip, `hasKeyMetadata` gate

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/Database.swift` (append migration after `v8-key-limits`)
- Modify: `Core/Sources/LLMCostBarCore/UsageStore.swift` (KeySpend, VendorSummary, upsert, select)
- Test: `Core/Tests/LLMCostBarCoreTests/UsageStoreTests.swift`

- [ ] **Step 1: Write failing tests** — append to `UsageStoreTests`:

```swift
    func testLifetimeRoundTripAndMetadataGate() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q)
        let store = UsageStore(db: q)
        try store.upsertKeyTotals(vendor: "openrouter", accountID: "o", totals: [
            KeyTotal(apiKeyID: "erik", totalUSD: 18.58, todayUSD: 20.05, mtdUSD: 38.63,
                     limitUSD: 20, limitRemainingUSD: 0, limitReset: "weekly", lifetimeUSD: 84.04),
        ])
        try store.upsertKeyTotals(vendor: "openai", accountID: "a", totals: [
            KeyTotal(apiKeyID: "plain", totalUSD: 5, todayUSD: 1, mtdUSD: 2),
        ])
        let vendors = try store.vendorSummaries(today: "2026-07-25", monthPrefix: "2026-07", last30Start: "2026-06-26")
        let or = vendors.first { $0.vendor == "openrouter" }!
        XCTAssertEqual(or.topKeys[0].lifetimeUSD ?? -1, 84.04, accuracy: 0.001)
        XCTAssertTrue(or.hasKeyMetadata)
        let oa = vendors.first { $0.vendor == "openai" }!
        XCTAssertNil(oa.topKeys[0].lifetimeUSD)
        XCTAssertFalse(oa.hasKeyMetadata, "no limit/lifetime/disabled → gate off")
    }

    /// Metadata gate scans only the DISPLAYED rows: metadata on a key that
    /// ranks below the top 5 must not enable chevrons for the visible five.
    func testMetadataOnlyOutsideTopFiveKeepsGateOff() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q)
        let store = UsageStore(db: q)
        var totals = (1...5).map { KeyTotal(apiKeyID: "key\($0)", totalUSD: Double(10 + $0), todayUSD: 0, mtdUSD: Double(10 + $0)) }
        totals.append(KeyTotal(apiKeyID: "tiny-limited", totalUSD: 0.5, todayUSD: 0, mtdUSD: 0.5,
                               limitUSD: 20, limitRemainingUSD: 20, lifetimeUSD: 0.5))
        try store.upsertKeyTotals(vendor: "openrouter", accountID: "o", totals: totals)
        let or = try store.vendorSummaries(today: "2026-07-25", monthPrefix: "2026-07", last30Start: "2026-06-26")[0]
        XCTAssertEqual(or.topKeys.count, 5)
        XCTAssertFalse(or.topKeys.contains { $0.apiKeyID == "tiny-limited" })
        XCTAssertFalse(or.hasKeyMetadata)
    }

    /// v8 → v9: existing key_totals rows survive with lifetime_usd NULL.
    func testV9MigrationPreservesV8Rows() throws {
        let q = try DatabaseQueue()
        try Database.migrator.migrate(q, upTo: "v8-key-limits")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO key_totals (vendor, account_id, api_key_id, total_usd, today_usd, mtd_usd,
                                        limit_usd, limit_remaining_usd, limit_reset, disabled, fetched_at)
                VALUES ('openrouter','o','erik',18.58,20.05,38.63,20,0,'weekly',0,'2026-07-25T00:00:00Z')
                """)
        }
        try Database.migrator.migrate(q)
        let keys = try UsageStore(db: q).vendorSummaries(today: "2026-07-25", monthPrefix: "2026-07",
                                                         last30Start: "2026-06-26")[0].topKeys
        XCTAssertEqual(keys[0].apiKeyID, "erik")
        XCTAssertNil(keys[0].lifetimeUSD)
        XCTAssertEqual(keys[0].limitUSD ?? -1, 20, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter UsageStoreTests 2>&1 | tail -5`
Expected: compile errors (`lifetimeUSD` / `hasKeyMetadata` missing on KeySpend/VendorSummary).

- [ ] **Step 3: Implement.**

`Database.swift` — append AFTER the `v8-key-limits` registration (GRDB runs migrations in registration order):

```swift
        m.registerMigration("v9-key-lifetime") { db in
            try db.execute(sql: "ALTER TABLE key_totals ADD COLUMN lifetime_usd REAL;")
        }
```

`UsageStore.swift` — `KeySpend` gains (after `disabled`):

```swift
    public var lifetimeUSD: Double? = nil  // vendor-reported lifetime spend
```

`VendorSummary` gains (after `topKeys`):

```swift
    /// True when any DISPLAYED key row carries limit/lifetime/disabled
    /// metadata — the UI's gate for chevron + inspector interactivity.
    public var hasKeyMetadata: Bool = false
```

`upsertKeyTotals` INSERT gains the column (11 → 12 placeholders):

```swift
                try db.execute(sql: """
                    INSERT OR REPLACE INTO key_totals
                    (vendor, account_id, api_key_id, total_usd, today_usd, mtd_usd,
                     limit_usd, limit_remaining_usd, limit_reset, disabled, lifetime_usd, fetched_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [vendor, accountID, t.apiKeyID, t.totalUSD, t.todayUSD, t.mtdUSD,
                                     t.limitUSD, t.limitRemainingUSD, t.limitReset, t.disabled, t.lifetimeUSD,
                                     ISO8601DateFormatter().string(from: now)])
```

`vendorSummaries` key query: add `lifetime_usd` to the SELECT list, map it, and derive the gate; the `keys` binding and the `VendorSummary` return become:

```swift
                let keys = try Row.fetchAll(db, sql: """
                    SELECT account_id, api_key_id, total_usd, today_usd, mtd_usd,
                           limit_usd, limit_remaining_usd, limit_reset, disabled, lifetime_usd
                    FROM key_totals
                    WHERE vendor = ? AND (total_usd > 0 OR COALESCE(today_usd, 0) > 0 OR COALESCE(mtd_usd, 0) > 0)
                    ORDER BY COALESCE(mtd_usd, total_usd) DESC, total_usd DESC, api_key_id ASC LIMIT 5
                    """, arguments: [vendor])
                    .map { KeySpend(accountID: $0["account_id"], apiKeyID: $0["api_key_id"],
                                    totalUSD: $0["total_usd"], todayUSD: $0["today_usd"], mtdUSD: $0["mtd_usd"],
                                    limitUSD: $0["limit_usd"], limitRemainingUSD: $0["limit_remaining_usd"],
                                    limitReset: $0["limit_reset"], disabled: $0["disabled"],
                                    lifetimeUSD: $0["lifetime_usd"]) }
                let hasKeyMetadata = keys.contains { $0.limitUSD != nil || $0.lifetimeUSD != nil || $0.disabled }
                return VendorSummary(vendor: vendor, todayUSD: t, monthUSD: m, last30USD: last30BeforeToday + t,
                                     balanceUSD: bal, creditsTotalUSD: credTotal, creditsUsedUSD: credUsed,
                                     topKeys: keys, hasKeyMetadata: hasKeyMetadata)
```

- [ ] **Step 4: Run the full Core suite**

Run: `cd Core && swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core && git commit -m "core: key_totals lifetime_usd (v9) + VendorSummary.hasKeyMetadata gate"
```

---

### Task 4: `KeyDetail` — Core-composed inspector/pin text

**Files:**
- Create: `Core/Sources/LLMCostBarCore/KeyDetail.swift`
- Create: `Core/Tests/LLMCostBarCoreTests/KeyDetailTests.swift`

- [ ] **Step 1: Write failing tests** — new file `KeyDetailTests.swift`:

```swift
import XCTest
@testable import LLMCostBarCore

final class KeyDetailTests: XCTestCase {
    private func spend(limit: Double? = nil, remaining: Double? = nil, reset: String? = nil,
                       disabled: Bool = false, lifetime: Double? = nil) -> KeySpend {
        KeySpend(accountID: "a", apiKeyID: "k", totalUSD: 1, todayUSD: 0, mtdUSD: 1,
                 limitUSD: limit, limitRemainingUSD: remaining, limitReset: reset,
                 disabled: disabled, lifetimeUSD: lifetime)
    }

    func testCappedKeyWithReset() {
        let d = spend(limit: 20, remaining: 0, reset: "weekly", lifetime: 84.04).detail()
        XCTAssertEqual(d.leading, "limit $20.00 · $0.00 left · resets weekly")
        XCTAssertEqual(d.trailing, "lifetime $84.04")
    }

    func testUnknownRemainingOmitsLeftSegment() {
        let d = spend(limit: 20, remaining: nil, reset: "weekly").detail()
        XCTAssertEqual(d.leading, "limit $20.00 · resets weekly")
    }

    func testNoResetIntervalOmitsResetsSegment() {
        let d = spend(limit: 20, remaining: 12).detail()
        XCTAssertEqual(d.leading, "limit $20.00 · $12.00 left")
    }

    func testNoLimit() {
        let d = spend(lifetime: 2.01).detail()
        XCTAssertEqual(d.leading, "no limit")
        XCTAssertEqual(d.trailing, "lifetime $2.01")
    }

    func testDisabledIsPrefixAndKeepsKnownSegments() {
        let d = spend(limit: 20, remaining: 4, reset: "weekly", disabled: true).detail()
        XCTAssertEqual(d.leading, "disabled · limit $20.00 · $4.00 left · resets weekly")
        let noLimit = spend(disabled: true).detail()
        XCTAssertEqual(noLimit.leading, "disabled · no limit")
    }

    func testMissingLifetimeGivesNilTrailing() {
        XCTAssertNil(spend(limit: 20, remaining: 4).detail().trailing)
    }

    func testSummaryLineCounts() {
        let keys = [
            spend(limit: 20, remaining: 0, reset: "weekly"),
            spend(limit: 20, remaining: 20, reset: "daily"),
            spend(),                       // unlimited
            spend(limit: 20, disabled: true),
        ]
        XCTAssertEqual(KeySpend.summaryLine(for: keys), "4 keys · 3 limited · 1 unlimited · 1 disabled")
        XCTAssertEqual(KeySpend.summaryLine(for: [spend(limit: 5, remaining: 5)]), "1 key · 1 limited")
        XCTAssertEqual(KeySpend.summaryLine(for: [spend(), spend()]), "2 keys · 2 unlimited")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter KeyDetailTests 2>&1 | tail -5`
Expected: compile error — `KeyDetail`/`detail()`/`summaryLine` undefined.

- [ ] **Step 3: Implement** — new file `Core/Sources/LLMCostBarCore/KeyDetail.swift`:

```swift
import Foundation

/// Inspector/pinned-strip text for one API key, composed here so the wording
/// is unit-tested and SwiftUI renders without any string logic. leading goes
/// left (tail-truncates in the UI); trailing goes right (never truncates).
public struct KeyDetail: Equatable, Sendable {
    public let leading: String
    public let trailing: String?
}

extension KeySpend {
    private static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    public func detail() -> KeyDetail {
        var segments: [String] = []
        if disabled { segments.append("disabled") }
        if let limit = limitUSD {
            segments.append("limit \(Self.usd(limit))")
            // Unknown remaining is omitted, never shown as $0.00 (that would
            // read as "exhausted" when we simply don't know).
            if let remaining = limitRemainingUSD { segments.append("\(Self.usd(remaining)) left") }
            if let reset = limitReset { segments.append("resets \(reset)") }
        } else {
            segments.append("no limit")
        }
        return KeyDetail(leading: segments.joined(separator: " · "),
                         trailing: lifetimeUSD.map { "lifetime \(Self.usd($0))" })
    }

    /// Idle inspector summary over the DISPLAYED rows, e.g.
    /// "4 keys · 3 limited · 1 unlimited · 1 disabled" (zero segments omitted;
    /// "limited" = has a budget limit, regardless of how much is used).
    public static func summaryLine(for keys: [KeySpend]) -> String {
        let limited = keys.filter { $0.limitUSD != nil }.count
        let unlimited = keys.count - limited
        let disabled = keys.filter(\.disabled).count
        var parts = ["\(keys.count) \(keys.count == 1 ? "key" : "keys")"]
        if limited > 0 { parts.append("\(limited) limited") }
        if unlimited > 0 { parts.append("\(unlimited) unlimited") }
        if disabled > 0 { parts.append("\(disabled) disabled") }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Run the full Core suite**

Run: `cd Core && swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core && git commit -m "core: KeyDetail composer + key-list summary line"
```

---

### Task 5: DropdownView — aligned rows, inspector, pin

**Files:**
- Modify: `App/DropdownView.swift` (`VendorCard` only: the `ForEach(vendor.topKeys...)` block in `expandedContent`, `keyRowAXLabel`, new state + helpers)

No unit tests (SwiftUI is manually verified in this repo); compile-check with the full build in Step 3.

- [ ] **Step 1: State + helpers.** In `struct VendorCard` (below `@State private var hoverDay: String?`) add:

```swift
    /// Stable row identity across polls — KeySpend values change every ~5s,
    /// so pins/hover must not key off the row value (spec: rename or top-5
    /// eviction simply drops the pin).
    struct KeyRowID: Hashable {
        let accountID: String
        let apiKeyID: String
        init(_ k: KeySpend) { accountID = k.accountID; apiKeyID = k.apiKeyID }
    }
    @State private var pinnedKey: KeyRowID?
    @State private var hoveredKey: KeyRowID?
```

And at file scope (bottom of `DropdownView.swift`):

```swift
extension KeySpend {
    /// Stable ForEach identity (spec: never key rows by their mutable value).
    var rowID: VendorCard.KeyRowID { .init(self) }
}

    /// Chevron + hover + pin only when rows have windows AND metadata (spec gate).
    private var keyListInteractive: Bool {
        vendor.hasKeyMetadata && vendor.topKeys.contains { $0.mtdUSD != nil }
    }
```

- [ ] **Step 2: Replace the key-list block.** Replace everything from `if !vendor.topKeys.isEmpty {` through the end of the `ForEach` (the block added in v1.3.20 with the VStack + ProgressView limit bar) with:

```swift
            if !vendor.topKeys.isEmpty {
                let hasWindows = vendor.topKeys.contains { $0.mtdUSD != nil }
                // Column-header line for windowed data; legacy single-total
                // rows keep the old plain label (and the old row format below).
                if hasWindows {
                    HStack(spacing: 0) {
                        Text(vendor.vendor == "anthropic" ? "API KEYS · EST. SPEND" : "API KEYS")
                        Spacer(minLength: 8)
                        Text("TODAY").frame(width: Self.statWidth, alignment: .trailing)
                        Text("MTD").frame(width: Self.statWidth, alignment: .trailing)
                        Text("30D").frame(width: Self.statWidth, alignment: .trailing)
                    }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                    .padding(.bottom, 1)
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                } else {
                    Text(vendor.vendor == "anthropic" ? "API keys · est. spend" : "API keys")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(vendor.topKeys, id: \.rowID) { k in
                    keyRow(k, hasWindows: hasWindows)
                }
                if keyListInteractive {
                    inspectorLine
                }
            }
```

- [ ] **Step 3: Add the row, pin strip, and inspector views** as private members of `VendorCard` (near `keyCell`):

```swift
    /// Exhausted = known-zero remaining only; unknown (nil) is never red.
    private func isCapped(_ k: KeySpend) -> Bool {
        if let remaining = k.limitRemainingUSD { return remaining <= 0.01 }
        return false
    }

    @ViewBuilder private func keyRow(_ k: KeySpend, hasWindows: Bool) -> some View {
        let id = KeyRowID(k)
        let interactive = keyListInteractive
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if interactive {
                    Image(systemName: pinnedKey == id ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8)).foregroundStyle(.quaternary)
                }
                Text(k.apiKeyID)
                    .font(.subheadline)
                    .foregroundStyle(isCapped(k) ? Color.red : Color.secondary)
                    .strikethrough(k.disabled)
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
            .padding(.vertical, 1).padding(.horizontal, 4)
            .background(hoveredKey == id && interactive ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, -4)
            .contentShape(Rectangle())
            .onHover { inside in
                guard interactive else { return }
                if inside { hoveredKey = id } else if hoveredKey == id { hoveredKey = nil }
            }
            .onTapGesture {
                guard interactive else { return }
                pinnedKey = pinnedKey == id ? nil : id   // single pin per card
            }
            if interactive, pinnedKey == id {
                let d = k.detail()
                HStack {
                    Text(d.leading).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let trailing = d.trailing { Text(trailing).layoutPriority(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .opacity(k.disabled ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keyRowAXLabel(k, hasWindows: hasWindows))
        .accessibilityValue(interactive ? (pinnedKey == id ? "expanded" : "collapsed") : "")
        .accessibilityAction(named: pinnedKey == id ? "collapse details" : "expand details") {
            guard interactive else { return }
            pinnedKey = pinnedKey == id ? nil : id
        }
    }

    /// Fixed-height line under the list: idle summary, or the hovered key's
    /// detail. Reserved space — hover never shifts layout (spec H2).
    private var inspectorLine: some View {
        HStack {
            if let hovered = vendor.topKeys.first(where: { KeyRowID($0) == hoveredKey }) {
                let d = hovered.detail()
                Text("\(hovered.apiKeyID) · \(d.leading)").lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let trailing = d.trailing { Text(trailing).layoutPriority(1) }
            } else {
                Text(KeySpend.summaryLine(for: vendor.topKeys))
                Spacer()
            }
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .frame(height: 14)
        .padding(.top, 2)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .accessibilityHidden(true)   // redundant with per-row labels
        .onDisappear { pinnedKey = nil; hoveredKey = nil }   // collapse/tab-switch clears pin
    }
```

- [ ] **Step 4: Extend `keyRowAXLabel`** — replace its body so detail info is never hover-only:

```swift
    private func keyRowAXLabel(_ k: KeySpend, hasWindows: Bool) -> String {
        var label = hasWindows
            ? "\(k.apiKeyID), today \(axAmount(k.todayUSD)), month to date \(axAmount(k.mtdUSD)), 30 days \(axAmount(k.totalUSD))"
            : "\(k.apiKeyID), total \(usd(k.totalUSD))"
        let d = k.detail()
        label += ", " + d.leading
        if let trailing = d.trailing { label += ", " + trailing }
        return label
    }
```

Also DELETE the now-unused v1.3.20 leftovers inside the old ForEach block if any remain (the `ProgressView(value: fraction)` limit bar, its caption `Text`, and the red `Text("disabled")` badge) — `keyRow(_:hasWindows:)` replaces them entirely.

- [ ] **Step 5: Build**

Run: `cd /Users/mikeb/DevProjects/LLM-cost-bar && xcodegen generate >/dev/null && xcodebuild -scheme LLMCostBar build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|\*\* BUILD" | head`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add App && git commit -m "app: aligned key rows + hover inspector + click-to-pin detail (spec 2026-07-25)"
```

---

### Task 6: Full verification + manual check

- [ ] **Step 1: Full Core suite** — `cd Core && swift test 2>&1 | tail -3` → all pass.
- [ ] **Step 2: Full app build** — command from Task 5 Step 5 → `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Manual verification checklist** (run the app locally or note for the user's post-release test):
  - Key columns align exactly under the vendor header's today/MTD/30d.
  - erik: red name (remaining $0), hover fills inspector, click pins strip.
  - Unlimited key: no decoration; inspector says "no limit".
  - Idle inspector shows "3 keys · 3 limited" (or current real counts).
  - OpenAI/Anthropic cards: header line present, but no chevrons/inspector.
  - Chart, credits bar, collapse behavior unchanged.
- [ ] **Step 4: Merge to develop**

```bash
git checkout develop && git merge --ff-only feature/key-list-ui
```

(Release/bump happens on the user's go, per project workflow.)
