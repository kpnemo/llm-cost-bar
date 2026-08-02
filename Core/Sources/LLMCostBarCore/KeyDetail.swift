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
        if apiKeyID == UsageStore.unattributedKeyID {
            return KeyDetail(leading: "spend with no listed key (deleted key, playground, or OAuth app)",
                             trailing: nil)
        }
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
        let keys = keys.filter { $0.apiKeyID != UsageStore.unattributedKeyID }   // synthetic row is not a key
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
