import AppKit
import Foundation
import SwiftUI
import LLMCostBarCore

/// Drives the self-update lifecycle: a quiet daily check (plus manual checks
/// from Settings), and the one-click download → verify → swap → relaunch flow.
@MainActor
final class UpdaterModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(Double)   // 0...1
        case installing
        case failed(String)
        case justUpdated(String)   // one-shot confirmation after a relaunch
    }

    @Published private(set) var phase: Phase = .idle
    /// Set while a newer release is known; the popover row is visible iff this
    /// is non-nil (or phase is justUpdated/failed).
    @Published private(set) var availableRelease: ReleaseInfo?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastCheckResult: String?

    let paths = AppPaths.resolve()
    private let service = UpdateService()
    private var autoTask: Task<Void, Never>?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init() {
        consumeUpdateInstalledMark()
        startAutoChecks()
    }

    deinit { autoTask?.cancel() }

    /// The installer writes the marker just before relaunch; finding it here
    /// means we ARE the freshly installed version — confirm briefly, then hide.
    private func consumeUpdateInstalledMark() {
        guard let data = try? Data(contentsOf: paths.updateInstalledMark),
              let version = String(data: data, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: paths.updateInstalledMark)
        guard version == currentVersion else { return }
        phase = .justUpdated(version)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            if case .justUpdated = self?.phase { self?.phase = .idle }
        }
    }

    /// First check ~10 s after launch (network may still be coming up at login),
    /// then daily. Config is re-read each round so the Settings toggle applies
    /// without a restart.
    private func startAutoChecks() {
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                guard let self else { return }
                if AppConfig.load(from: self.paths.config).autoCheckUpdates {
                    await self.check(manual: false)
                }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check(manual: Bool = true) async {
        switch phase {
        case .checking, .downloading, .installing: return   // busy
        default: break
        }
        if manual { phase = .checking }
        do {
            let release = try await service.checkForUpdate(currentVersion: currentVersion)
            availableRelease = release
            lastCheckResult = release.map { "Version \($0.version) is available" } ?? "Up to date"
        } catch {
            // Quiet failure by design: status is visible in Settings only.
            lastCheckResult = "Check failed: \(shortError(error))"
        }
        lastCheck = Date()
        if manual, case .checking = phase { phase = .idle }
    }

    /// One click: download → verify → swap → relaunch. Any failure lands in
    /// .failed with the release kept, so Retry is a plain install() again.
    func install() {
        guard let release = availableRelease else { return }
        switch phase {
        case .downloading, .installing: return
        default: break
        }
        phase = .downloading(0)
        let paths = self.paths
        Task {
            do {
                let installedAt = try await UpdateInstaller.install(
                    release: release, paths: paths,
                    downloadProgress: { pct in
                        Task { @MainActor [weak self] in
                            if case .downloading = self?.phase { self?.phase = .downloading(pct) }
                        }
                    },
                    onInstalling: {
                        Task { @MainActor [weak self] in self?.phase = .installing }
                    })
                UpdateInstaller.relaunchAndQuit(bundleAt: installedAt)
            } catch {
                phase = .failed(shortError(error))
            }
        }
    }

    private func shortError(_ error: Error) -> String {
        switch error {
        case let e as InstallError: e.localizedDescription
        case let e as ProviderError:
            switch e {
            case .transient: "network unavailable or rate-limited"
            case .http(let code, _): "GitHub returned HTTP \(code)"
            case .decode: "unexpected response from GitHub"
            case .auth: "GitHub refused the request"
            }
        default: error.localizedDescription
        }
    }
}
