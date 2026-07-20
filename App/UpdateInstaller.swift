import AppKit
import Foundation
import os
import LLMCostBarCore

enum InstallError: LocalizedError {
    case step(String)
    var errorDescription: String? {
        if case .step(let msg) = self { return msg }
        return nil
    }
}

/// Downloads a release DMG, verifies the bundle inside it, and swaps it over the
/// running app. Every destructive step happens only after signature/team/version
/// verification of the staged copy; any failure after the daemon is stopped
/// restores it before rethrowing.
enum UpdateInstaller {
    static let log = Logger(subsystem: AppIDs.subsystem, category: "updater")

    /// Logs and returns — every abort must be visible in `log show`, not just
    /// the UI row (the 4KY3876TB2 team-pin bug was invisible in logs).
    private static func fail(_ message: String) -> InstallError {
        log.error("install aborted: \(message)")
        return .step(message)
    }

    /// Runs the full sequence except the final relaunch (the caller owns UI
    /// state and process exit). Returns the installed bundle URL.
    static func install(release: ReleaseInfo, paths: AppPaths,
                        downloadProgress: @escaping @Sendable (Double) -> Void,
                        onInstalling: @escaping @Sendable () -> Void) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("llmcostbar-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download the DMG.
        let dmg = work.appendingPathComponent(UpdateService.assetName)
        try await download(release.dmgURL, to: dmg, progress: downloadProgress)
        onInstalling()

        // 2. Mount, copy the .app out, unmount.
        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                     "-mountpoint", mount.path], step: "mounting DMG")
        let staged = work.appendingPathComponent("staged.app")
        do {
            let appName = try fm.contentsOfDirectory(atPath: mount.path).first { $0.hasSuffix(".app") }
            guard let appName else { throw fail("DMG contains no .app") }
            try run("/usr/bin/ditto", [mount.appendingPathComponent(appName).path, staged.path],
                    step: "copying app from DMG")
        } catch {
            try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], step: "unmounting DMG")
            throw error
        }
        try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], step: "unmounting DMG")

        // 3. Verify the staged bundle BEFORE touching anything on disk.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path],
                step: "verifying signature")
        // codesign -dvv prints signing info on stderr; run() captures both.
        let signInfo = try run("/usr/bin/codesign", ["-dvv", staged.path], step: "reading signature")
        guard UpdateService.codesignOutput(signInfo, containsTeam: UpdateService.releaseTeamID) else {
            throw fail("downloaded app is signed by an unexpected team — aborting")
        }
        let stagedPlist = staged.appendingPathComponent("Contents/Info.plist")
        let stagedVersion = (NSDictionary(contentsOf: stagedPlist)?["CFBundleShortVersionString"] as? String) ?? "?"
        guard stagedVersion == release.version else {
            throw fail("downloaded app is v\(stagedVersion), expected v\(release.version)")
        }

        // 4. Verified — strip quarantine so relaunch avoids Gatekeeper translocation.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path], step: "dequarantine")

        // 5. Stop the daemon (also disarms its watchdog so it can't relaunch the
        //    old app mid-swap); deleting the heartbeat makes the relaunched app's
        //    DaemonManager.ensure() take its missing-heartbeat path and re-bootstrap.
        DaemonManager.bootout()
        try? fm.removeItem(at: paths.heartbeat)

        // 6. Swap at the running bundle's location. Trashing keeps the running
        //    process alive (it holds the old inodes) and gives the user a
        //    recovery path if anything goes wrong later.
        let dest = Bundle.main.bundleURL
        var trashedOld: NSURL?
        do {
            try fm.trashItem(at: dest, resultingItemURL: &trashedOld)
            try run("/usr/bin/ditto", [staged.path, dest.path], step: "installing new app")
        } catch {
            log.error("install failed at swap: \(String(describing: error)) — rolling back")
            if let old = trashedOld as URL? {
                try? fm.removeItem(at: dest)               // partial copy, if any
                try? fm.moveItem(at: old, to: dest)
            }
            DaemonManager.ensure(heartbeatURL: paths.heartbeat, force: true)
            throw error
        }

        // 7. Restart the daemon NOW, from the new bundle (the LaunchAgent plist
        //    points at the fixed bundle path, so this launches the new binary).
        //    Doing it before the app relaunch means every post-swap outcome —
        //    including a failed relaunch — leaves a live daemon.
        DaemonManager.ensure(heartbeatURL: paths.heartbeat, force: true)

        // 8. One-shot marker so the new instance can show "✓ Updated to vX.Y.Z".
        try? Data(release.version.utf8).write(to: paths.updateInstalledMark)
        log.info("installed v\(release.version) at \(dest.path)")
        return dest
    }

    /// Launches the freshly installed bundle and terminates this process only
    /// once the new instance is confirmed running. A brief two-instance overlap
    /// is harmless (menu-bar app); a silent no-app outcome is not — on failure
    /// the old instance stays alive and reports instead of exiting blind.
    static func relaunchAndQuit(bundleAt url: URL, onFailure: @escaping @MainActor (String) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            DispatchQueue.main.async {
                if app != nil {
                    NSApp.terminate(nil)
                } else {
                    log.error("relaunch failed: \(String(describing: error))")
                    onFailure("update installed, but relaunch failed — please quit and reopen the app")
                }
            }
        }
    }

    // MARK: - helpers

    /// Streamed download straight to disk; progress comes from the task's own
    /// Progress object (handles the GitHub → objects.githubusercontent redirect
    /// and unknown lengths for free).
    private static func download(_ url: URL, to dest: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                observation?.invalidate()
                observation = nil
                if let error {
                    return cont.resume(throwing: fail("download failed: \(error.localizedDescription)"))
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let tmp else {
                    return cont.resume(throwing: fail("download failed (HTTP \(status))"))
                }
                do {
                    // Must move before this handler returns — URLSession deletes tmp after.
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume()
                } catch {
                    cont.resume(throwing: fail("saving download: \(error.localizedDescription)"))
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                progress(p.fractionCompleted)
            }
            task.resume()
        }
    }

    /// Runs a tool to completion, capturing stdout+stderr. Non-zero exit → error
    /// tagged with the human-readable step name.
    @discardableResult
    private static func run(_ tool: String, _ args: [String], step: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { throw fail("\(step): \(error.localizedDescription)") }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: output, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw fail("\(step): \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        return text
    }
}
