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
    static let expectedTeamID = "4KY3876TB2"

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
            guard let appName else { throw InstallError.step("DMG contains no .app") }
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
        guard signInfo.contains("TeamIdentifier=\(expectedTeamID)") else {
            throw InstallError.step("downloaded app is signed by an unexpected team — aborting")
        }
        let stagedPlist = staged.appendingPathComponent("Contents/Info.plist")
        let stagedVersion = (NSDictionary(contentsOf: stagedPlist)?["CFBundleShortVersionString"] as? String) ?? "?"
        guard stagedVersion == release.version else {
            throw InstallError.step("downloaded app is v\(stagedVersion), expected v\(release.version)")
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

        // 7. One-shot marker so the new instance can show "✓ Updated to vX.Y.Z".
        try? Data(release.version.utf8).write(to: paths.updateInstalledMark)
        log.info("installed v\(release.version) at \(dest.path)")
        return dest
    }

    /// Spawns a detached relauncher and exits. `open -n` starts the NEW binary
    /// after the 1 s sleep gives this process time to fully terminate.
    static func relaunchAndQuit(bundleAt url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n '\(url.path)'"]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - helpers

    private static func download(_ url: URL, to dest: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw InstallError.step("download failed (HTTP \(status))") }
        let expected = response.expectedContentLength   // -1 if unknown
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        var lastReported = -1
        for try await byte in bytes {
            data.append(byte)
            if expected > 0 {
                let pct = Int(Double(data.count) / Double(expected) * 100)
                if pct != lastReported {   // throttle: at most one UI hop per percent
                    lastReported = pct
                    progress(Double(pct) / 100)
                }
            }
        }
        try data.write(to: dest)
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
        do { try p.run() } catch { throw InstallError.step("\(step): \(error.localizedDescription)") }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: output, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw InstallError.step("\(step): \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        return text
    }
}
