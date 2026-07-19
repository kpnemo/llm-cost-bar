import SwiftUI
import Charts
import LLMCostBarCore

struct DropdownView: View {
    @EnvironmentObject var model: StoreModel
    @EnvironmentObject var pairing: PairingController
    @Environment(\.openSettings) private var openSettings
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today \(usd(model.summary.todayUSD))")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("MTD \(usd(model.summary.monthUSD))")
                    .font(.title3).foregroundStyle(.secondary)
            }

            ForEach(model.vendors, id: \.vendor) { v in
                VendorCard(vendor: v,
                           account: model.accounts.first { $0.vendor == v.vendor },
                           series: model.series[v.vendor] ?? [],
                           isCollapsed: collapsed.contains(v.vendor),
                           toggle: {
                               if collapsed.contains(v.vendor) { collapsed.remove(v.vendor) }
                               else { collapsed.insert(v.vendor) }
                           })
            }

            if model.vendors.isEmpty {
                Text("No accounts connected — open Settings to pair OpenRouter.")
                    .foregroundStyle(.secondary).font(.body)
            }

            Divider()
            HStack {
                Button("Settings…") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                syncStatus
            }
            .font(.body)
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            (NSApp.delegate as? AppDelegate)?.pairing = pairing
            model.refresh()
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

struct VendorCard: View {
    let vendor: VendorSummary
    let account: AccountRow?
    let series: [DayCost]
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var hoverDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row is the collapse toggle — always visible.
            HStack {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption).foregroundStyle(.tertiary)
                if let icon = Self.vendorIcon(vendor.vendor) {
                    Image(nsImage: icon)
                        .resizable().interpolation(.high)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(vendorDisplayName).font(.title3).bold()
                if isCollapsed {
                    Text("today \(usd(vendor.todayUSD))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(usd(vendor.monthUSD)).font(.title3).bold()
                    Text("MTD").font(.caption).foregroundStyle(.tertiary)
                }
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
            if let day = hoverDay, let point = filledSeries.first(where: { $0.day == day }) {
                Text("\(prettyDay(day)) · \(usd(point.costUSD))")
                    .font(.subheadline).foregroundStyle(.primary)
            } else {
                Text("today \(usd(vendor.todayUSD))")
                    .font(.subheadline).foregroundStyle(.secondary)
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

            // KeySpend is Hashable (accountID + apiKeyID + todayUSD); apiKeyID alone
            // isn't guaranteed unique across accounts, so identify rows by the
            // whole value rather than `id: \.apiKeyID` as originally sketched.
            if !vendor.topKeys.isEmpty {
                // OpenRouter reports lifetime per-key totals; OpenAI real 30-day
                // dollars; Anthropic has no per-key cost API, so 30-day estimates
                // allocated from org cost by token share.
                Text(vendor.vendor == "anthropic" ? "API keys · 30-day est. spend"
                     : vendor.vendor == "openai" ? "API keys · 30-day spend"
                     : "API keys · total spend")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(vendor.topKeys, id: \.self) { k in
                HStack {
                    Text(k.apiKeyID).font(.subheadline)
                    Spacer()
                    Text(usd(k.totalUSD)).font(.subheadline)
                }
                .foregroundStyle(.secondary)
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
