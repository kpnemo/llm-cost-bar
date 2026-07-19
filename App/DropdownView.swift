import SwiftUI
import LLMCostBarCore

struct DropdownView: View {
    @EnvironmentObject var model: StoreModel
    @EnvironmentObject var pairing: PairingController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today \(usd(model.summary.todayUSD))").font(.headline)
                Spacer()
                Text("MTD \(usd(model.summary.monthUSD))").foregroundStyle(.secondary)
            }

            ForEach(model.vendors, id: \.vendor) { v in
                VendorCard(vendor: v, account: model.accounts.first { $0.vendor == v.vendor })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(vendorDisplayName).bold()
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(usd(vendor.monthUSD)).bold()
                    Text("this month").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text("today \(usd(vendor.todayUSD))")
                .font(.caption).foregroundStyle(.secondary)

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
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var vendorDisplayName: String {
        switch vendor.vendor {
        case "openrouter": "OpenRouter"
        default: vendor.vendor.capitalized
        }
    }
}

func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
