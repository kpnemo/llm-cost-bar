import Foundation

public enum MenuBarDisplay: String, Codable, CaseIterable, Sendable {
    case iconOnly, today, monthToDate, last30Days
}

public enum PopoverTab: String, Codable, CaseIterable, Sendable {
    case apiSpend, subscriptions
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var refreshMinutes: Int = 15
    public var menuBarDisplay: MenuBarDisplay = .monthToDate
    public var keepAppAlive: Bool = true
    public var defaultTab: PopoverTab = .apiSpend
    public var subscriptionAlertThreshold: Int = 80   // % used that triggers a notification
    public var autoCheckUpdates: Bool = true

    public init() {}

    /// Per-field decodeIfPresent with defaults: a config.json written by any older
    /// or newer version must never throw here — synthesized Codable would throw
    /// keyNotFound for fields added later, and load()'s fallback would then
    /// silently reset EVERY preference the user had set.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshMinutes = (try? c.decodeIfPresent(Int.self, forKey: .refreshMinutes)) ?? nil ?? 15
        menuBarDisplay = (try? c.decodeIfPresent(MenuBarDisplay.self, forKey: .menuBarDisplay)) ?? nil ?? .monthToDate
        keepAppAlive = (try? c.decodeIfPresent(Bool.self, forKey: .keepAppAlive)) ?? nil ?? true
        defaultTab = (try? c.decodeIfPresent(PopoverTab.self, forKey: .defaultTab)) ?? nil ?? .apiSpend
        subscriptionAlertThreshold = (try? c.decodeIfPresent(Int.self, forKey: .subscriptionAlertThreshold)) ?? nil ?? 80
        autoCheckUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates)) ?? nil ?? true
    }

    /// Missing or corrupt file → defaults. Never throws: prefs must not brick either process.
    public static func load(from url: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return cfg
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
