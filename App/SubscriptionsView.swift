import SwiftUI
import Charts
import LLMCostBarCore

/// Subscriptions tab body: one card per enabled auto-detected source.
struct SubscriptionsSection: View {
    @EnvironmentObject var model: StoreModel
    @EnvironmentObject var claudeConnect: ClaudeConnectController

    var body: some View {
        let enabled = model.subscriptionSources.filter(\.enabled)
        if enabled.isEmpty {
            Text("No subscriptions detected — install Claude Code or Codex CLI, run it once, and they appear here automatically.")
                .foregroundStyle(.secondary).font(.body)
        }
        ForEach(enabled, id: \.source) { src in
            let isClaude = src.source == SubscriptionSource.claude
            SubscriptionCard(source: src,
                             windows: SubscriptionCard.ordered(model.subscriptionWindows.filter { $0.source == src.source }),
                             series: model.subscriptionSeries[src.source] ?? [],
                             threshold: model.config.subscriptionAlertThreshold,
                             connectPhase: isClaude ? claudeConnect.phase : nil,
                             onConnect: isClaude ? { claudeConnect.connect() } : nil)
        }
        .onAppear {
            claudeConnect.store = model.store
            claudeConnect.onChanged = { model.refresh() }
        }
    }
}

struct SubscriptionCard: View {
    let source: SubscriptionSourceRow
    let windows: [SubscriptionWindowRow]
    let series: [SubscriptionPoint]
    let threshold: Int
    var connectPhase: ClaudeConnectController.Phase? = nil
    var onConnect: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon = VendorCard.vendorIcon(iconVendor) {
                    Image(nsImage: icon)
                        .resizable().interpolation(.high)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(displayName).font(.title3).bold()
                if let plan = planBadge {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(freshness).font(.caption).foregroundStyle(.tertiary)
            }

            if source.stale {
                if needsReconnect, let onConnect {
                    reconnectRow(onConnect)
                } else {
                    Label(source.staleReason ?? "sign-in required", systemImage: "key.slash")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }

            if let hot = windows.filter({ $0.usedPercent >= Double(threshold) })
                              .max(by: { $0.usedPercent < $1.usedPercent }) {
                Label("\(hot.label) window at \(Int(hot.usedPercent))%\(resetSuffix(hot))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            if windows.isEmpty {
                Text("waiting for first sync…").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(windows, id: \.self) { w in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(w.label) — \(Int(w.usedPercent))%")
                            .font(.subheadline).foregroundStyle(.primary)
                        Spacer()
                        Text(resetText(w)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ProgressView(value: w.usedPercent / 100)
                        .tint(barColor(w.usedPercent))
                        .controlSize(.small)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(displayName) \(w.label) window, \(Int(w.usedPercent)) percent used, \(resetText(w))")
            }

            // Sparkline appears once ≥12 h of history exists — with less, two
            // near-identical points stretch into a context-free flat line that
            // reads as broken. The x-axis is pinned to the full 7-day window so
            // young data grows in from the right edge instead of filling the
            // width dishonestly.
            if seriesIsMeaningful {
                Chart(series, id: \.self) { p in
                    AreaMark(x: .value("Time", p.bucketStart),
                             y: .value("%", p.usedPercent))
                        .foregroundStyle(.linearGradient(
                            colors: [.blue.opacity(0.22), .blue.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.bucketStart),
                             y: .value("%", p.usedPercent))
                        .foregroundStyle(.blue.opacity(0.7))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: Date().addingTimeInterval(-7 * 86400)...Date())
                .chartYScale(domain: 0...100)
                .frame(height: 36)
                .padding(.top, 2)
                Text("weekly window utilization, last 7 days")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Reconnect is click-gated: this row is the ONLY way a keychain dialog can
    /// appear, and only ever right after the user asked for it.
    private var needsReconnect: Bool {
        source.staleReason == ClaudeTokenResolver.reconnectReason
    }

    @ViewBuilder private func reconnectRow(_ onConnect: @escaping () -> Void) -> some View {
        switch connectPhase {
        case .connecting:
            Label("waiting for macOS approval…", systemImage: "key")
                .font(.subheadline).foregroundStyle(.secondary)
        case .connected:
            Label("connected ✓ — refreshing…", systemImage: "checkmark.circle")
                .font(.subheadline).foregroundStyle(.green)
        case .failed(let msg):
            HStack(alignment: .firstTextBaseline) {
                Label(msg, systemImage: "xmark.circle")
                    .font(.subheadline).foregroundStyle(.red)
                Spacer(minLength: 8)
                Button("Retry") { onConnect() }.controlSize(.small)
            }
        default:
            HStack(alignment: .firstTextBaseline) {
                Label(windows.isEmpty ? "Connect to show limits — macOS asks once for Keychain access"
                                      : "updates paused — reconnect to resume (last-known data below)",
                      systemImage: "key.slash")
                    .font(.subheadline).foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button(windows.isEmpty ? "Connect…" : "Reconnect") { onConnect() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    /// True once the series spans enough real time to draw a curve worth reading.
    private var seriesIsMeaningful: Bool {
        guard series.count >= 2, let oldest = series.first?.bucketStart else { return false }
        return Date().timeIntervalSince(oldest) >= 12 * 3600
    }

    // MARK: presentation helpers

    /// Session-style windows first, weekly after, model-specific last.
    static func ordered(_ rows: [SubscriptionWindowRow]) -> [SubscriptionWindowRow] {
        let rank = ["five_hour": 0, "secondary": 0, "seven_day": 1, "primary": 1,
                    "seven_day_opus": 2, "seven_day_sonnet": 3]
        return rows.sorted { (rank[$0.windowID] ?? 9) < (rank[$1.windowID] ?? 9) }
    }

    private var displayName: String { source.source == SubscriptionSource.claude ? "Claude" : "Codex" }
    /// Subscription sources reuse the API vendors' bundled favicons.
    private var iconVendor: String { source.source == SubscriptionSource.claude ? "anthropic" : "openai" }

    private var planBadge: String? {
        switch source.planType {
        case nil: return nil
        case "max_5x": return "Max 5×"
        case "max_20x": return "Max 20×"
        case "pro": return "Pro"
        case "plus": return "ChatGPT Plus"
        case let p?: return p.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var freshness: String {
        guard let newest = windows.compactMap({ parseISO($0.observedAt) }).max() else { return "" }
        let age = ageText(newest)
        return windows.contains { $0.origin == "jsonl" } ? "from CLI session · \(age)" : "updated \(age)"
    }

    private func barColor(_ pct: Double) -> Color {
        pct < 60 ? .green : (pct <= 85 ? .yellow : .red)
    }

    private func resetText(_ w: SubscriptionWindowRow) -> String {
        guard let reset = w.resetsAt.flatMap(parseISO) else { return "" }
        return resetDescription(reset)
    }

    private func resetSuffix(_ w: SubscriptionWindowRow) -> String {
        guard let reset = w.resetsAt.flatMap(parseISO), reset > Date() else { return "" }
        return " — resets in \(countdown(to: reset))"
    }
}

// MARK: shared date formatting

func parseISO(_ s: String) -> Date? {
    let fmt = ISO8601DateFormatter()
    if let d = fmt.date(from: s) { return d }
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.date(from: s)
}

/// "2 min ago" / "3 h ago" / "2 d ago"
func ageText(_ date: Date, now: Date = Date()) -> String {
    let s = max(0, now.timeIntervalSince(date))
    if s < 90 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 48 * 3600 { return "\(Int(s / 3600)) h ago" }
    return "\(Int(s / 86400)) d ago"
}

/// "in 2d 3h" / "in 3h 12m" / "in 45m"
func countdown(to date: Date, now: Date = Date()) -> String {
    let s = date.timeIntervalSince(now)
    guard s > 0 else { return "now" }
    let minutes = Int(s / 60), hours = minutes / 60, days = hours / 24
    if days > 0 { return "\(days)d \(hours % 24)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(max(minutes, 1))m"
}

/// "resets Tue 14:00 · in 2d 3h" (local time), or "resets now" once passed.
func resetDescription(_ reset: Date, now: Date = Date()) -> String {
    guard reset > now else { return "resets now" }
    let fmt = DateFormatter()
    fmt.dateFormat = Calendar.current.isDate(reset, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
    return "resets \(fmt.string(from: reset)) · in \(countdown(to: reset, now: now))"
}
