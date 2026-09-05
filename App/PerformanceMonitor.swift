import AppKit
import QuartzCore
import SwiftUI
import os

/// Local, bounded diagnostics. Disk I/O never runs on the UI thread.
final class PerformanceLog: @unchecked Sendable {
    static let shared = PerformanceLog()
    private let queue = DispatchQueue(label: "com.mikeb.LLMCostBar.performance-log", qos: .utility)
    private let logger = Logger(subsystem: "com.mikeb.LLMCostBar", category: "performance")
    private let session = UUID().uuidString
    private let started = ProcessInfo.processInfo.systemUptime
    static let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["LLMCOSTBAR_PERFORMANCE_LOG_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/LLMCostBar", isDirectory: true)
    }()

    func record(_ event: String, fields: [String: String] = [:]) {
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            var row = fields
            row["event"] = event
            row["session"] = session
            row["timestamp"] = ISO8601DateFormatter().string(from: Date())
            row["app_uptime_s"] = String(format: "%.1f", uptime - started)
            row["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            row["build"] = Bundle.main.object(forInfoDictionaryKey: "PerformanceBuild") as? String ?? "local"
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let url = Self.directory.appendingPathComponent("performance.jsonl")
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size >= 1_048_576 {
                    let older = Self.directory.appendingPathComponent("performance.2.jsonl")
                    let previous = Self.directory.appendingPathComponent("performance.1.jsonl")
                    if fm.fileExists(atPath: older.path) { try fm.removeItem(at: older) }
                    if fm.fileExists(atPath: previous.path) { try fm.moveItem(at: previous, to: older) }
                    try fm.moveItem(at: url, to: previous)
                }
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(0x0a)
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                logger.error("Could not write performance log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func duration(_ event: String, since start: TimeInterval, fields: [String: String] = [:]) {
        var fields = fields
        fields["duration_ms"] = Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
        record(event, fields: fields)
    }

    static func milliseconds(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds * 1000) }
}

/// Instruments only this app's events; no global event tap or accessibility grant.
/// The display-link endpoint is a render proxy, NOT a compositor presentation fence.
@MainActor
final class PerformanceMonitor: NSObject {
    static let shared = PerformanceMonitor()
    private weak var statusView: NSView?
    private weak var popupWindow: NSWindow?
    private weak var popupProbe: NSView?
    private var eventMonitor: Any?
    private var input: (timestamp: TimeInterval, received: TimeInterval, window: Int, kind: String, released: TimeInterval?)?
    private struct Interaction {
        let id = UUID().uuidString
        let action: String
        let input: String
        let start: TimeInterval
        let received: TimeInterval
        var released: TimeInterval?
        var windowNumber: Int?
        var drawn: TimeInterval?
        var windowUpdated: TimeInterval?
    }
    private var pending: Interaction?
    private var displayLink: CADisplayLink?
    private var watchdog: Timer?
    private var lastWatchdog = ProcessInfo.processInfo.systemUptime

    func start() {
        guard eventMonitor == nil else { return }
        PerformanceLog.shared.record("session_start")
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.received(event)
            return event
        }
        watchdog = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkResponsiveness() }
        }
        RunLoop.main.add(watchdog!, forMode: .common)
    }

    private func checkResponsiveness() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = now - lastWatchdog - 0.25
        lastWatchdog = now
        // Uptime excludes sleep. Very long gaps (e.g. debugger suspension) are
        // kept separately from interaction measurements and never called renders.
        if delay >= 0.1 { PerformanceLog.shared.record("main_runloop_delay", fields: ["delay_ms": PerformanceLog.milliseconds(delay)]) }
        if let pending, now - pending.start > 5 { cancel(reason: "timeout") }
    }

    private func received(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            if var input, input.kind == "mouse", input.window == event.windowNumber {
                input.released = event.timestamp
                self.input = input
                if pending?.start == input.timestamp { pending?.released = event.timestamp }
            }
            return
        }
        input = (event.timestamp, ProcessInfo.processInfo.systemUptime, event.windowNumber,
                 event.type == .keyDown ? "keyboard" : "mouse", nil)
        guard event.type == .leftMouseDown, popupWindow?.isVisible != true else { return }
        // MenuBarExtra may rasterize its SwiftUI label instead of attaching the
        // representable to a window. Its app-owned status-level window still
        // receives local NSEvents, without relying on a private class name.
        let isStatusWindow = event.window?.level == .statusBar
        let hitsLabel = statusView.map { view in
            event.window === view.window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        } ?? false
        if isStatusWindow || hitsLabel { begin("menu_open") }
    }

    func registerStatus(_ view: NSView) { statusView = view; start() }

    func registerPopup(_ view: NSView) { popupProbe = view; popupWindow = view.window }

    func begin(_ action: String, useInput: Bool = true) {
        if pending != nil { cancel(reason: "superseded") }
        let now = ProcessInfo.processInfo.systemUptime
        let event = useInput ? input.flatMap { now - $0.received < 2 ? $0 : nil } : nil
        pending = Interaction(action: action, input: event?.kind ?? "programmatic",
                              start: event?.timestamp ?? now, received: event?.received ?? now, released: event?.released)
        if let pending {
            PerformanceLog.shared.record("interaction_start", fields: ["id": pending.id, "action": action, "input": pending.input])
        }
    }

    func popupAppeared() {
        // Accessibility/keyboard opens may not produce a status-item mouse event.
        // Keep those samples separate instead of claiming a measured mouse click.
        if pending == nil { begin("menu_open", useInput: false) }
        // A cached popup may reopen without SwiftUI updating its body. Redraw
        // only the transparent sentinel so those fast opens are measured too.
        popupProbe?.needsDisplay = true
    }

    func popupClosed() {
        if pending?.action == "menu_open" || pending?.action.hasPrefix("tab_") == true { cancel(reason: "closed") }
    }

    func contentDrawn(in view: NSView, surface: String) {
        if surface == "popup" { popupWindow = view.window }
        guard var p = pending, p.drawn == nil,
              (surface == "popup" && (p.action == "menu_open" || p.action.hasPrefix("tab_"))) ||
              (surface == "settings" && p.action.hasPrefix("settings_")) else { return }
        p.windowNumber = view.window?.windowNumber
        p.drawn = ProcessInfo.processInfo.systemUptime
        pending = p
        let id = p.id
        // Run after the current AppKit drawing pass unwinds. didUpdateNotification
        // alone is unsuitable: it may arrive BEFORE Core Animation draws a view,
        // causing a measurement to wait for an unrelated later window update.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.pending?.id == id else { return }
            self.windowUpdated(for: view)
        }
    }

    private func windowUpdated(for view: NSView) {
        guard var p = pending, p.drawn != nil, p.windowUpdated == nil,
              view.window?.isVisible == true, view.window?.windowNumber == p.windowNumber else { return }
        p.windowUpdated = ProcessInfo.processInfo.systemUptime
        pending = p
        displayLink?.invalidate()
        displayLink = view.displayLink(target: self, selector: #selector(nextDisplayRefresh(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func nextDisplayRefresh(_ link: CADisplayLink) {
        guard let p = pending, let updated = p.windowUpdated else { return }
        // timestamp describes the most recent refresh, targetTimestamp a FUTURE
        // one. Wait for a refresh timestamp after our completed window update.
        guard link.timestamp >= updated else { return }
        var fields = [
            "id": p.id, "action": p.action, "input": p.input,
            "queue_ms": PerformanceLog.milliseconds(p.received - p.start),
            "draw_pass_ms": PerformanceLog.milliseconds(updated - p.start),
            "render_proxy_ms": PerformanceLog.milliseconds(link.timestamp - p.start),
            "endpoint": "first_display_refresh_after_drawing_pass"
        ]
        if let released = p.released, released >= p.start, released <= link.timestamp {
            fields["mouse_hold_ms"] = PerformanceLog.milliseconds(released - p.start)
            fields["release_to_render_ms"] = PerformanceLog.milliseconds(link.timestamp - released)
        }
        PerformanceLog.shared.record("interaction", fields: fields)
        pending = nil
        link.invalidate()
        displayLink = nil
    }

    private func cancel(reason: String) {
        if let p = pending {
            PerformanceLog.shared.record("interaction_incomplete", fields: ["id": p.id, "action": p.action, "reason": reason])
        }
        pending = nil
        displayLink?.invalidate()
        displayLink = nil
    }
}

/// A transparent drawing sentinel. Completion requires a draw of the selected
/// content, completion of that AppKit drawing pass, and a subsequent display
/// refresh. This is explicitly a presentation proxy, not a GPU/compositor fence.
struct PerformanceProbe: NSViewRepresentable {
    let surface: String
    var revision: String = ""
    func makeNSView(context: Context) -> ProbeView { ProbeView(surface: surface) }
    func updateNSView(_ view: ProbeView, context: Context) { view.needsDisplay = true }

    final class ProbeView: NSView {
        let surface: String
        init(surface: String) { self.surface = surface; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if surface == "status" { PerformanceMonitor.shared.registerStatus(self) }
            if surface == "popup" { PerformanceMonitor.shared.registerPopup(self) }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if surface != "status" { PerformanceMonitor.shared.contentDrawn(in: self, surface: surface) }
        }
    }
}
