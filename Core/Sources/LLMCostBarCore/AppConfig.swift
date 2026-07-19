import Foundation

public enum MenuBarDisplay: String, Codable, CaseIterable, Sendable {
    case iconOnly, today, monthToDate
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var refreshMinutes: Int = 15
    public var menuBarDisplay: MenuBarDisplay = .monthToDate
    public var keepAppAlive: Bool = true

    public init() {}

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
