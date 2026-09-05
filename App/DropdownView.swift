import SwiftUI
import Charts
import LLMCostBarCore

struct DropdownView: View {
    @Environment(StoreModel.self) var model
    @EnvironmentObject var pairing: PairingController
    @EnvironmentObject var updater: UpdaterModel
    @Environment(\.openSettings) private var openSettings
    @State private var tab: PopoverTab
    init(defaultTab: PopoverTab) { _tab = State(initialValue: defaultTab) }
    @State private var liveRefresh: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardHeader(tab: tab)

            Picker("Tab", selection: Binding(get: { tab }, set: { value in
                guard tab != value else { return }
                PerformanceMonitor.shared.begin("tab_" + value.rawValue)
                tab = value
            })) {
                Text("API Spend").tag(PopoverTab.apiSpend)
                Text("Subscriptions").tag(PopoverTab.subscriptions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == .apiSpend {
                apiSpendContent
            } else {
                SubscriptionsSection()
            }

            UpdateRow()

            Divider()
            HStack {
                Button("Settings…") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Text("v\(updater.currentVersion)")
                    .font(.caption).foregroundStyle(.tertiary)
                    .help("LLM Cost Bar version")
                SyncStatusView()
            }
            .font(.body)
        }
        .padding(16)
        .frame(width: 440)
        .background(PerformanceProbe(surface: "popup", revision: tab.rawValue))
        .onAppear {
            PerformanceMonitor.shared.popupAppeared()
            (NSApp.delegate as? AppDelegate)?.pairing = pairing
            model.refresh()
            // Cached config is already current; do not wait for a database load.
            tab = model.config.defaultTab
            // While the popover is open, refresh every 5 s so the footer status
            // ("syncing…" → "N min ago") and amounts update live instead of
            // waiting for the 30 s background timer or a close/reopen.
            liveRefresh?.cancel()
            liveRefresh = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    model.refresh()
                }
            }
        }
        .onDisappear {
            PerformanceMonitor.shared.popupClosed()
            liveRefresh?.cancel()
            liveRefresh = nil
        }
    }

    @ViewBuilder private var apiSpendContent: some View {
        // Expand/collapse persists in config (collapsed by default): only
        // vendors in expandedVendors render open, across popover opens and
        // app relaunches.
        ForEach(model.vendors, id: \.vendor) { v in
            VendorCard(vendor: v,
                       account: model.accounts.first { $0.vendor == v.vendor },
                       series: model.series[v.vendor] ?? [],
                       chart: model.charts[v.vendor],
                       isCollapsed: !model.config.expandedVendors.contains(v.vendor),
                       toggle: {
                           if let i = model.config.expandedVendors.firstIndex(of: v.vendor) {
                               model.config.expandedVendors.remove(at: i)
                           } else {
                               model.config.expandedVendors.append(v.vendor)
                           }
                           model.saveConfig()
                       })
                .equatable()
        }

        if model.vendors.isEmpty {
            Text("No accounts connected — open Settings to pair OpenRouter.")
                .foregroundStyle(.secondary).font(.body)
        }
    }

}

private struct DashboardHeader: View {
    @Environment(StoreModel.self) var model
    let tab: PopoverTab
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in content }
    }
    @ViewBuilder private var content: some View {
        if tab == .apiSpend {
            HStack {
                Text("Today \(usd(model.summary.todayUSD))")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("MTD \(usd(model.summary.monthUSD))")
                    .font(.title3).foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Subscriptions").font(.title2.weight(.semibold))
                Spacer()
                if let next = nextReset {
                    Text("next reset in \(countdown(to: next))")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Soonest upcoming window reset across all enabled subscription sources.
    private var nextReset: Date? {
        let enabled = Set(model.subscriptionSources.filter(\.enabled).map(\.source))
        return model.subscriptionWindows
            .filter { enabled.contains($0.source) }
            .compactMap { $0.resetsAt.flatMap(parseISO) }
            .filter { $0 > Date() }
            .min()
    }

}

private struct SyncStatusView: View {
    @Environment(StoreModel.self) var model
    @ViewBuilder var body: some View {
        if !model.daemonHealthy {
            // Grace window: right after launch/self-update the daemon is still
            // booting and hasn't heartbeat yet — "paused" would be a false alarm.
            if model.statusDate.timeIntervalSince(model.launchedAt) < 120 {
                Label("syncing…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } else {
                Label("sync paused", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } else if let last = model.accounts.compactMap(\.lastSyncOK).max(),
                  let date = parseISO(last) {
            let mins = Int(model.statusDate.timeIntervalSince(date) / 60)
            syncButton(text: mins > 120 ? "synced \(mins / 60) h ago" : "\(mins) min ago")
                .foregroundStyle(mins > 120 ? .orange : .secondary)
        } else {
            syncButton(text: "never synced")
                .foregroundStyle(.secondary)
        }
    }

    /// The refresh glyph is a button: click → daemon syncs within ~5 s.
    private func syncButton(text: String) -> some View {
        Button {
            model.requestSync()
        } label: {
            Label(text, systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.plain)
        .help("Sync now")
    }
}

/// Quiet self-update row above the footer. Hidden entirely in the common case
/// (no update known, nothing recently installed) so the popover stays lean.
struct UpdateRow: View {
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        switch updater.phase {
        case .justUpdated(let version):
            row(tint: .green) {
                Label("Updated to v\(version)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Spacer()
            }
        case .downloading(let pct):
            if let release = updater.availableRelease {
                row(tint: .blue) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloading v\(release.version)… \(Int(pct * 100))%")
                            .foregroundStyle(.blue)
                        ProgressView(value: pct).controlSize(.small)
                    }
                }
            }
        case .installing:
            row(tint: .blue) {
                Label("Installing — restarting…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
                Spacer()
            }
        case .failed(let message):
            row(tint: .orange) {
                Label("Update failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(message)
                Spacer()
                Button("Retry") { updater.install() }
                    .controlSize(.small)
            }
        case .idle, .checking:
            if let release = updater.availableRelease {
                row(tint: .blue) {
                    Label("Update available — v\(release.version)", systemImage: "arrow.up.circle")
                        .foregroundStyle(.blue)
                    Spacer()
                    Button("Install") { updater.install() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func row<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(content: content)
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct VendorCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.vendor == rhs.vendor && lhs.account == rhs.account && lhs.series == rhs.series &&
        lhs.chart == rhs.chart && lhs.isCollapsed == rhs.isCollapsed
    }
    let vendor: VendorSummary
    let account: AccountRow?
    let series: [DayCost]
    let chart: SpendChart?
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var hoverDay: String?

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

    /// Chevron + hover + pin only when rows have windows AND metadata (spec gate).
    private var keyListInteractive: Bool {
        vendor.hasKeyMetadata && vendor.topKeys.contains { $0.mtdUSD != nil }
    }

    static let statWidth: CGFloat = 76

    private func statColumn(_ amount: String, label: String, color: Color, dim: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(amount).font(.body.weight(.bold)).monospacedDigit()
                .foregroundStyle(color).opacity(dim ? 0.45 : 1)
            Text(label).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(width: Self.statWidth, alignment: .trailing)
    }

    /// VoiceOver text for a key-row amount; nil → "no data".
    private func axAmount(_ value: Double?) -> String {
        value.map(usd) ?? "no data"
    }

    /// nil → "—" (old daemon rows mixed with new); values that display as
    /// $0.00 render dim (nil and negatives don't).
    private func keyCell(_ value: Double?, color: Color) -> some View {
        let v = value ?? 1
        return Text(value.map(usd) ?? "—")
            .font(.subheadline).monospacedDigit()
            .foregroundStyle(color)
            .opacity(v < 0.005 && v >= 0 ? 0.45 : 1)
            .frame(width: Self.statWidth, alignment: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row is the collapse toggle — always visible.
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption).foregroundStyle(.tertiary)
                    if let icon = Self.vendorIcon(vendor.vendor) {
                        Image(nsImage: icon)
                            .resizable().interpolation(.high)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(vendorDisplayName).font(.title3).bold()
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                statColumn(usd(vendor.todayUSD), label: "today", color: .blue,
                           dim: vendor.todayUSD < 0.005)
                statColumn(usd(vendor.monthUSD), label: "MTD", color: .primary)
                statColumn(usd(vendor.last30USD), label: "30d", color: .secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if !isCollapsed {
                expandedContent
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let day = hoverDay, let point = filledSeries.first(where: { $0.day == day }) {
                    Text("\(prettyDay(day)) · \(usd(point.costUSD))")
                        .font(.subheadline).foregroundStyle(.primary)
                } else {
                    Text(" ").font(.subheadline)
                }
            }

            if !series.isEmpty {
                let filled = filledSeries
                Chart(filled, id: \.day) { point in
                    BarMark(x: .value("Day", String(point.day.suffix(5))),
                            y: .value("USD", point.costUSD))
                        .foregroundStyle(.blue.opacity(barOpacity(point.day)))
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.system(size: 10))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { hoverDay = nil; return }
                                    let x = location.x - geo[plotFrame].origin.x
                                    if let suffix: String = proxy.value(atX: x) {
                                        hoverDay = filled.first { $0.day.hasSuffix(suffix) }?.day
                                    } else {
                                        hoverDay = nil
                                    }
                                case .ended:
                                    hoverDay = nil
                                }
                            }
                    }
                }
                .frame(height: 72)
                .padding(.vertical, 2)
            }

            if let total = vendor.creditsTotalUSD, let used = vendor.creditsUsedUSD, total > 0 {
                let fraction = min(used / total, 1.0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("credits: \(usd(vendor.balanceUSD ?? total - used)) left of \(usd(total))")
                        Spacer()
                        Text("\(Int(fraction * 100))% used")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    ProgressView(value: fraction)
                        .tint(fraction < 0.7 ? .green : (fraction < 0.9 ? .orange : .red))
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            } else if let b = vendor.balanceUSD {
                Text("balance \(usd(b))").font(.subheadline).foregroundStyle(.secondary)
            }

            if account?.needsReauth == true {
                Label("reconnect needed — open Settings", systemImage: "key.slash")
                    .font(.subheadline).foregroundStyle(.red)
            }

            // KeySpend's synthesized Hashable covers all fields; apiKeyID alone
            // isn't guaranteed unique across accounts, so identify rows by the
            // whole value.
            //
            // All three vendors now report per-day per-key dollars: Anthropic
            // estimated (allocated from org cost by token share), OpenAI and
            // OpenRouter real dollars (OpenRouter via per-key /activity calls).
            // The single-column branch below remains only as a fallback for
            // old daemon data that predates per-key windows.
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
        }
    }

    /// Fill missing days with zero bars so the 30-day chart has a continuous
    /// axis. Today's bar uses the vendor's live figure when it exceeds the
    /// activity feed (which only publishes completed UTC days) — otherwise the
    /// chart shows an empty slot while the header reports live spend.
    private var filledSeries: [DayCost] { chart?.points ?? [] }

    private func barOpacity(_ day: String) -> Double {
        let base: Double = (hoverDay == nil || hoverDay == day) ? 0.7 : 0.3
        return (day == chart?.today && chart?.todayIsLiveEstimate == true) ? base * 0.55 : base
    }

    private func keyRowAXLabel(_ k: KeySpend, hasWindows: Bool) -> String {
        var label = hasWindows
            ? "\(k.apiKeyID), today \(axAmount(k.todayUSD)), month to date \(axAmount(k.mtdUSD)), 30 days \(axAmount(k.totalUSD))"
            : "\(k.apiKeyID), total \(usd(k.totalUSD))"
        // Detail info must never be hover-only (spec: accessibility).
        let d = k.detail()
        label += ", " + d.leading
        if let trailing = d.trailing { label += ", " + trailing }
        return label
    }

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
        // VoiceOver: bare amounts carry no column semantics — read the whole
        // row as one element with named columns.
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

    /// "2026-07-19" → "Jul 19" for the hover readout.
    private func prettyDay(_ day: String) -> String {
        guard let date = parseISO(day + "T00:00:00Z") else { return day }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }

    /// Bundled favicon for a vendor (Resources/VendorIcons/<vendor>.png,
    /// embedded by a project.yml post-build script). Cached — cards re-render
    /// on every hover tick and disk I/O per frame would stutter the chart.
    private static var iconCache: [String: NSImage?] = [:]
    static func vendorIcon(_ vendor: String) -> NSImage? {
        if let cached = iconCache[vendor] { return cached }
        let url = Bundle.main.url(forResource: vendor, withExtension: "png", subdirectory: "VendorIcons")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        iconCache[vendor] = image
        return image
    }

    private var vendorDisplayName: String {
        switch vendor.vendor {
        case "openrouter": "OpenRouter"
        case "openai": "OpenAI"
        default: vendor.vendor.capitalized
        }
    }
}

extension KeySpend {
    /// Stable ForEach identity (spec: never key rows by their mutable value).
    var rowID: VendorCard.KeyRowID { .init(self) }
}

func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
