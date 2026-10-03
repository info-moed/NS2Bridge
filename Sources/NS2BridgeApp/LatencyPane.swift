import NS2Kit
import SwiftUI

struct LatencyPane: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        let live = model.latency
        let shown = model.latencyResult ?? live
        let e = LatencyMonitor.expectation(for: shown.link, kind: model.selectedKind, bluetoothIntervalMs: model.bluetoothExpectedMs)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latency test").font(.title2.bold())
                    Text("Measures how fast \(model.selected.map { "P\($0.player)'s \($0.kind.displayName)" } ?? "the controller")'s reports arrive over \(live.link.rawValue) and compares that with what it should deliver.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let end = model.latencyTestEnds {
                    ProgressView(value: 10 - max(0, end.timeIntervalSinceNow), total: 10).frame(width: 120)
                    Text("Testing…").font(.caption)
                } else {
                    Button { model.runLatencyTest() } label: { Label("Run 10-second test", systemImage: "stopwatch") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isConnected)
                }
            }

            if let r = model.latencyResult {
                verdictBanner(r)
            } else {
                Text("Showing live numbers. Hold the controller normally (or leave it on the desk) and run the 10-second test for a verdict.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Measured").font(.caption.bold())
                    Text("Expected").font(.caption.bold())
                    Text("").frame(width: 20)
                }
                Divider().gridCellColumns(4)
                row("Report rate", String(format: "%.0f Hz", shown.rateHz), String(format: "%.0f Hz", 1000 / e.intervalMs),
                    ok: shown.rateHz >= 1000 / e.acceptableMs)
                row("Average interval", ms(shown.meanMs), ms(e.intervalMs), ok: shown.meanMs <= e.acceptableMs)
                row("99% of reports within", ms(shown.p99Ms), "≤ " + ms(e.acceptableMs * 1.5), ok: shown.p99Ms <= e.acceptableMs * 1.5)
                row("Jitter", "± " + ms(shown.jitterMs), shown.link == .usb ? "≤ ± 0.5 ms" : "≤ ± 5 ms",
                    ok: shown.jitterMs <= (shown.link == .usb ? 0.5 : 5))
                row("Dropped reports", String(format: "%d (%.2f%%)", shown.dropped, shown.dropPercent), "0 (< 1%)",
                    ok: shown.dropPercent < 1)
                if let h = shown.hostDelayMs {
                    row("Time inside macOS", ms(h), "< 1 ms", ok: h < 1)
                }
                Divider().gridCellColumns(4)
                row("Added input latency (avg)", ms(shown.addedAverageMs), ms(e.intervalMs / 2), ok: shown.addedAverageMs <= e.acceptableMs / 2 + 1)
                row("Added input latency (worst)", ms(shown.addedWorstMs), ms(e.intervalMs), ok: shown.addedWorstMs <= e.acceptableMs * 1.5 + 1)
            }
            .font(.body.monospacedDigit())
            .opacity(shown.samples > 0 ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Report interval histogram").font(.headline)
                Histogram(buckets: shown.histogram, expected: e.intervalMs)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Report interval histogram")
                    .accessibilityValue(shown.samples > 0 ? String(format: "Most reports %.0f to %.0f milliseconds apart; expected %.1f", Double(2 * (shown.histogram.firstIndex(of: shown.histogram.max() ?? 0) ?? 0)), Double(2 * (shown.histogram.firstIndex(of: shown.histogram.max() ?? 0) ?? 0) + 2), e.intervalMs) : "No data yet")
                    .frame(height: 110)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What the numbers mean").font(.headline)
                    Text("• \(e.note)")
                    Text("• \"Added input latency\" is the delay the link adds on top of the game itself: on average you wait half an interval for the next report, at worst a full one.")
                    Text("• For reference: USB 250 Hz = 4 ms · Switch 2 console over Bluetooth = 5 ms · NS2 Bridge over Bluetooth = 7.5 ms (Fastest) · macOS's default = 30 ms.")
                    Text("• It measures the link, not your display or the game's frame time — those add their own delay on top.")
                }
                .font(.caption).foregroundStyle(.secondary).padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func ms(_ v: Double) -> String { v > 0 ? String(format: "%.1f ms", v) : "—" }

    private func row(_ title: String, _ measured: String, _ expected: String, ok: Bool) -> some View {
        GridRow {
            Text(title)
            Text(measured).bold()
            Text(expected).foregroundStyle(.secondary)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }

    private func verdictBanner(_ r: LatencyMonitor.Snapshot) -> some View {
        let e = LatencyMonitor.expectation(for: r.link, kind: model.selectedKind, bluetoothIntervalMs: model.bluetoothExpectedMs)
        let good = r.meanMs <= e.acceptableMs && r.dropPercent < 1
        return HStack {
            Image(systemName: good ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(good ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(good ? "\(r.link.rawValue) link is performing as expected" : "\(r.link.rawValue) link is slower than expected").font(.headline)
                Text(String(format: "%.0f Hz · %.1f ms average · adds ~%.1f ms on average, ~%.1f ms worst case",
                            r.rateHz, r.meanMs, r.addedAverageMs, r.addedWorstMs)).font(.callout)
            }
            Spacer()
            Button("Copy results") { model.copyLatencyReport(r) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill((good ? Color.green : Color.orange).opacity(0.12)))
    }
}

struct Histogram: View {
    let buckets: [Int]
    let expected: Double

    var body: some View {
        let maxV = max(1, buckets.max() ?? 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(buckets.indices, id: \.self) { i in
                let isExpected = Int(expected / 2) == i
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isExpected ? Color.green : Color.accentColor.opacity(0.7))
                        .frame(height: max(1, CGFloat(buckets[i]) / CGFloat(maxV) * 80))
                    Text(i == 20 ? "40+" : "\(i * 2)").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                .frame(width: 22)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("ms between reports · green = expected").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
