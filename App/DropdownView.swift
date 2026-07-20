import SwiftUI
import Charts
import LLMCostBarCore

struct DropdownView: View {
    @EnvironmentObject var model: StoreModel
    @EnvironmentObject var pairing: PairingController
    @EnvironmentObject var updater: UpdaterModel
    @Environment(\.openSettings) private var openSettings
    @State private var tab: PopoverTab = .apiSpend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Picker("Tab", selection: $tab) {
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
                syncStatus
            }
            .font(.body)
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            (NSApp.delegate as? AppDelegate)?.pairing = pairing
            model.refresh()
            // Every popover open starts on the configured default tab (refresh()
            // just reloaded config, so a settings change applies immediately).
            tab = model.config.defaultTab
        }
    }

    @ViewBuilder private var header: some View {
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

    @ViewBuilder private var apiSpendContent: some View {
        // Expand/collapse persists in config (collapsed by default): only
        // vendors in expandedVendors render open, across popover opens and
        // app relaunches.
        ForEach(model.vendors, id: \.vendor) { v in
            VendorCard(vendor: v,
                       account: model.accounts.first { $0.vendor == v.vendor },
                       series: model.series[v.vendor] ?? [],
                       isCollapsed: !model.config.expandedVendors.contains(v.vendor),
                       toggle: {
                           if let i = model.config.expandedVendors.firstIndex(of: v.vendor) {
                               model.config.expandedVendors.remove(at: i)
                           } else {
                               model.config.expandedVendors.append(v.vendor)
                           }
                           model.saveConfig()
                       })
        }

        if model.vendors.isEmpty {
            Text("No accounts connected — open Settings to pair OpenRouter.")
                .foregroundStyle(.secondary).font(.body)
        }
    }

    @ViewBuilder private var syncStatus: some View {
        if !model.daemonHealthy {
            Label("sync paused", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if let last = model.accounts.compactMap(\.lastSyncOK).max(),
                  let date = ISO8601DateFormatter().date(from: last) {
            let mins = Int(Date().timeIntervalSince(date) / 60)
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

struct VendorCard: View {
    let vendor: VendorSummary
    let account: AccountRow?
    let series: [DayCost]
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var hoverDay: String?

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
                        .foregroundStyle(.blue.opacity(hoverDay == nil || hoverDay == point.day ? 0.7 : 0.3))
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
                Text(vendor.vendor == "anthropic" ? "API keys · est. spend" : "API keys")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            let hasWindows = vendor.topKeys.contains { $0.mtdUSD != nil }
            ForEach(vendor.topKeys, id: \.self) { k in
                HStack {
                    Text(k.apiKeyID).font(.subheadline).foregroundStyle(.secondary)
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
                // VoiceOver: bare amounts carry no column semantics — read the
                // whole row as one element with named columns.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hasWindows
                    ? "\(k.apiKeyID), today \(axAmount(k.todayUSD)), month to date \(axAmount(k.mtdUSD)), 30 days \(axAmount(k.totalUSD))"
                    : "\(k.apiKeyID), total \(usd(k.totalUSD))")
            }
        }
    }

    /// Fill missing days with zero bars so the 30-day chart has a continuous axis.
    private var filledSeries: [DayCost] {
        let byDay = Dictionary(uniqueKeysWithValues: series.map { ($0.day, $0.costUSD) })
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(identifier: "UTC")
        return (0..<30).reversed().map { offset in
            let day = fmt.string(from: Date().addingTimeInterval(-Double(offset) * 86400))
            return DayCost(day: day, costUSD: byDay[day] ?? 0)
        }
    }

    /// "2026-07-19" → "Jul 19" for the hover readout.
    private func prettyDay(_ day: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.calendar = Calendar(identifier: .gregorian)
        parse.dateFormat = "yyyy-MM-dd"; parse.timeZone = TimeZone(identifier: "UTC")
        guard let date = parse.date(from: day) else { return day }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "MMM d"
        return out.string(from: date)
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

func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
