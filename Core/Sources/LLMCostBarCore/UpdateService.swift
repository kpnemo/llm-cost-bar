import Foundation

/// A published release the app can update to.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: String        // "1.3.0" — tag with the leading "v" stripped
    public let dmgURL: URL
    public let releasePageURL: URL?

    public init(version: String, dmgURL: URL, releasePageURL: URL?) {
        self.version = version
        self.dmgURL = dmgURL
        self.releasePageURL = releasePageURL
    }
}

/// Checks GitHub Releases for a newer version. Pure parsing/compare logic lives
/// here so it's unit-testable; the download/install orchestration is in the App
/// (the process that must replace and relaunch itself).
public struct UpdateService: Sendable {
    public static let defaultAPI = URL(string: "https://api.github.com/repos/kpnemo/llm-cost-bar/releases/latest")!
    public static let assetName = "LLMCostBar.dmg"

    let http: HTTPClient
    let apiURL: URL

    public init(http: HTTPClient = URLSessionHTTPClient(), apiURL: URL = UpdateService.defaultAPI) {
        self.http = http
        self.apiURL = apiURL
    }

    /// nil → already up to date. Throws ProviderError (transient/http/decode).
    public func checkForUpdate(currentVersion: String) async throws -> ReleaseInfo? {
        let (data, status) = try await http.get(apiURL, headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "LLMCostBar-updater",   // GitHub 403s UA-less requests
        ])
        if let err = classifyHTTP(status: status, data: data) { throw err }
        let info = try Self.parse(data)
        return Self.isNewer(info.version, than: currentVersion) ? info : nil
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL?
        let assets: [Asset]
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: data) }
        catch { throw ProviderError.decode("releases/latest: \(error)") }
        guard let dmg = release.assets.first(where: { $0.name == assetName }) else {
            throw ProviderError.decode("release \(release.tag_name) has no \(assetName) asset")
        }
        var version = release.tag_name
        if version.hasPrefix("v") { version.removeFirst() }
        return ReleaseInfo(version: version, dmgURL: dmg.browser_download_url,
                           releasePageURL: release.html_url)
    }

    /// Numeric per-component compare ("1.10.0" > "1.2.0"); missing components
    /// count as 0, so "1.2" == "1.2.0". Tolerates a leading "v".
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func components(_ s: String) -> [Int] {
            var s = s
            if s.hasPrefix("v") { s.removeFirst() }
            return s.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let r = components(remote), l = components(local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
