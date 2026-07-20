import Foundation

/// Tolerant scalar extraction for the undocumented subscription endpoints/files:
/// shapes drift (Int vs Double vs String, epoch vs ISO, nesting moves), and one
/// unrecognized field must never blank a whole card.
enum SubJSON {
    static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func int(_ any: Any?) -> Int? {
        double(any).map { Int($0) }
    }

    /// Epoch seconds, epoch milliseconds, or ISO8601 (with or without fractional seconds).
    static func date(_ any: Any?) -> Date? {
        if let n = double(any) {
            guard n > 0 else { return nil }
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        guard let s = any as? String else { return nil }
        let fmt = ISO8601DateFormatter()
        if let d = fmt.date(from: s) { return d }
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: s)
    }

    /// Depth-bounded search for a dictionary under `key` anywhere in the tree —
    /// event payloads wrap rate_limits at varying levels across CLI versions.
    static func findDict(in any: Any, key: String, depth: Int = 0) -> [String: Any]? {
        guard depth < 6 else { return nil }
        if let dict = any as? [String: Any] {
            if let hit = dict[key] as? [String: Any] { return hit }
            for v in dict.values {
                if let hit = findDict(in: v, key: key, depth: depth + 1) { return hit }
            }
        } else if let arr = any as? [Any] {
            for v in arr {
                if let hit = findDict(in: v, key: key, depth: depth + 1) { return hit }
            }
        }
        return nil
    }
}
