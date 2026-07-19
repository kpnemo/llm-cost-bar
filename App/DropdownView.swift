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
                Text("Today \(usd(model.summary.todayUSD))").font(.headline)
                Spacer()
                Text("MTD \(usd(model.summary.monthUSD))").foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary).font(.callout)
            }

            Divider()
            HStack {
                Button("Settings…") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                syncStatus
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
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
            Label(mins > 120 ? "synced \(mins / 60) h ago" : "\(mins) min ago",
                  systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(mins > 120 ? .orange : .secondary)
        } else {
            Label("never synced", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        }
    }
}

struct VendorCard: View {
    let vendor: VendorSummary
    let account: AccountRow?
    let series: [DayCost]
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row is the collapse toggle — always visible.
            HStack {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(vendorDisplayName).bold()
                if isCollapsed {
                    Text("today \(usd(vendor.todayUSD))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(usd(vendor.monthUSD)).bold()
                    Text("this month").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if !isCollapsed {
                expandedContent
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("today \(usd(vendor.todayUSD))")
                .font(.caption).foregroundStyle(.secondary)

            if !series.isEmpty {
                Chart(filledSeries, id: \.day) { point in
                    BarMark(x: .value("Day", String(point.day.suffix(5))),
                            y: .value("USD", point.costUSD))
                        .foregroundStyle(.blue.opacity(0.7))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel().font(.system(size: 7))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.system(size: 7))
                    }
                }
                .frame(height: 56)
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
                    .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: fraction)
                        .tint(fraction < 0.7 ? .green : (fraction < 0.9 ? .orange : .red))
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            } else if let b = vendor.balanceUSD {
                Text("balance \(usd(b))").font(.caption).foregroundStyle(.secondary)
            }

            if account?.needsReauth == true {
                Label("reconnect needed — open Settings", systemImage: "key.slash")
                    .font(.caption).foregroundStyle(.red)
            }

            // KeySpend is Hashable (accountID + apiKeyID + todayUSD); apiKeyID alone
            // isn't guaranteed unique across accounts, so identify rows by the
            // whole value rather than `id: \.apiKeyID` as originally sketched.
            if !vendor.topKeys.isEmpty {
                Text("API keys · total spend").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(vendor.topKeys, id: \.self) { k in
                HStack {
                    Text(k.apiKeyID).font(.caption)
                    Spacer()
                    Text(usd(k.totalUSD)).font(.caption)
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

    private var vendorDisplayName: String {
        switch vendor.vendor {
        case "openrouter": "OpenRouter"
        default: vendor.vendor.capitalized
        }
    }
}

func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
