import Charts
import NS2Kit
import SwiftUI

struct BatteryPane: View {
    @Environment(BridgeModel.self) private var model
    @State private var range: HistoryRange = .sixHours

    enum HistoryRange: String, CaseIterable, Identifiable {
        case hour = "1 h", sixHours = "6 h", day = "24 h", week = "7 days"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self { case .hour: return 3600; case .sixHours: return 6 * 3600; case .day: return 86400; case .week: return 7 * 86400 }
        }
    }

    var body: some View {
        @Bindable var model = model
        let rec = model.batteryRecord
        let r = model.batteryReading
        let pct = rec.flatMap { rec in r.map { rec.percent($0) } } ?? r.map { $0.level * 100 }
        let rate = rec?.ratePerHour()
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Battery").font(.title2.bold())
                    Text("Live battery data for \(model.selected.map { "P\($0.player)'s \($0.kind.displayName)" } ?? "the controller"), updated every 10 seconds. History is kept per physical controller.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refreshBatteryNow() } label: { Label("Read now", systemImage: "arrow.clockwise") }
                    .disabled(!model.isConnected)
            }

            // Headline
            HStack(alignment: .center, spacing: 28) {
                Gauge(value: (pct ?? 0) / 100) {
                    EmptyView()
                } currentValueLabel: {
                    Text(pct.map { "\(Int($0.rounded()))%" } ?? "—").font(.title.bold())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .scaleEffect(1.8)
                .frame(width: 110, height: 110)
                .tint(gaugeColor(pct))

                VStack(alignment: .leading, spacing: 6) {
                    Text(stateText(r)).font(.title3.bold())
                    if let mv = r?.millivolts {
                        Text(String(format: "%.3f V", Double(mv) / 1000)).font(.system(.title2, design: .monospaced))
                    }
                    if let rate {
                        Text(String(format: "%@%.1f %%/hour", rate >= 0 ? "+" : "", rate)).font(.callout.monospacedDigit())
                        if let eta = etaText(pct: pct, rate: rate, charging: r?.charging ?? false) {
                            Text(eta).font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Rate: measuring (needs ~5 minutes of steady charging or discharging)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if r?.charging == true, !(rec?.curve.measured ?? false) {
                        Text("Voltage reads a little high while charging, so % runs ahead slightly until it's unplugged.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // History chart
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Voltage history").font(.headline)
                    Spacer()
                    Picker("", selection: $range) {
                        ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 260)
                }
                let pts = (rec?.samples ?? []).filter { Date().timeIntervalSince($0.t) <= range.seconds && $0.mv != nil }
                if pts.count < 2 {
                    Text("Collecting data: the chart fills in as NS2 Bridge reads the battery (one point per minute).")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                } else {
                    Chart(pts, id: \.t) { s in
                        LineMark(x: .value("Time", s.t), y: .value("Volts", Double(s.mv!) / 1000))
                            .foregroundStyle(by: .value("State", s.charging ? "Charging" : (s.external ? "Plugged in" : "On battery")))
                            .interpolationMethod(.monotone)
                    }
                    .chartForegroundStyleScale(["Charging": Color.green, "Plugged in": Color.blue, "On battery": Color.orange])
                    .chartYScale(domain: 3.3...4.3)
                    .frame(height: 170)
                }
            }

            // Nerd stats
            VStack(alignment: .leading, spacing: 8) {
                Text("Nerd stats").font(.headline)
                let cols = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)
                LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                    stat("Cell voltage", r?.millivolts.map { "\($0) mV" } ?? "not reported")
                    stat("Controller's own level", r.map { levelText($0.level) } ?? "—")
                    stat("Estimated charge cycles", rec.map { String(format: "%.2f", $0.cycles) } ?? "—")
                    stat("Highest voltage seen", rec?.maxMillivolts.map { "\($0) mV" } ?? "—")
                    stat("Lowest voltage seen", rec?.minMillivolts.map { "\($0) mV" } ?? "—")
                    stat("Last full charge", rec?.lastFull.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "not yet seen")
                    stat("Time charging (seen)", rec.map { hours($0.chargingSeconds) } ?? "—")
                    stat("Time on battery (seen)", rec.map { hours($0.batterySeconds) } ?? "—")
                    stat("Tracking since", rec.map { $0.firstSeen.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    stat("Voltage → % curve", rec?.curve.measured == true ? "Calibrated for this controller" : "Typical Li-ion curve")
                    stat("History points", rec.map { "\($0.samples.count)" } ?? "—")
                    stat("Charge status bytes", (r?.statusRaw.isEmpty ?? true) ? "—" : r!.statusRaw.map { String(format: "%02X", $0) }.joined(separator: " "))
                    if let fw = model.selectedFirmware { stat("Firmware", fw) }
                    if let mac = model.selectedMAC { stat("Bluetooth address", mac) }
                    stat("Power", r.map { $0.charging ? "Charging" : ($0.externalPower ? "Plugged in, not charging" : "Battery") } ?? "—")
                }
                Text("Cycles and times count only what NS2 Bridge has seen while running. The controllers don't store a cycle count themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Charge alert
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $model.chargeAlertEnabled) {
                        Text("Charge limit alert").font(.headline)
                    }
                    HStack {
                        Text("Alert at")
                        Slider(value: $model.chargeAlertPercent, in: 50...100, step: 5)
                        Text("\(Int(model.chargeAlertPercent))%").monospacedDigit().frame(width: 44)
                    }
                    .disabled(!model.chargeAlertEnabled)
                    Text("When a charging controller reaches this level, NS2 Bridge shows a notification, plays a chime and buzzes the controller so you can unplug it. Keeping lithium batteries between about 20% and 80% slows their wear.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Why an alert and not an automatic stop: neither controller lets a computer switch its charging off (their charge chips are run by the controller itself), and Macs can't cut power to a USB-C port.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Calibration
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Battery calibration").font(.headline)
                    Text("Builds a voltage-to-percent curve for this specific controller, so the percentage stays accurate as the battery ages. Charge it to full, then play wirelessly until it's low. NS2 Bridge times the discharge while it runs; the app must stay open.")
                        .font(.caption).foregroundStyle(.secondary)
                    calibrationControls(rec)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Life test
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Battery life test").font(.headline)
                    Text("Play wirelessly (not charging) for at least 5 minutes; NS2 Bridge measures the drain and projects how long a full charge lasts. The rumble option adds a steady gentle vibration to measure the worst case.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let t = model.lifeTest {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Running for \(Int(Date().timeIntervalSince(t.start) / 60)) min\(t.withRumble ? " · with rumble" : "")")
                            Spacer()
                            Button("Stop and measure") { model.stopLifeTest() }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        HStack {
                            Button("Start") { model.startLifeTest(withRumble: false) }
                            Button("Start with rumble load") { model.startLifeTest(withRumble: true) }
                        }
                        .disabled(!model.isConnected || (r?.externalPower ?? true))
                        if r?.externalPower ?? true {
                            Text("Unplug the controller first. The test only works on battery.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    ForEach((rec?.lifeTests ?? []).reversed()) { t in
                        Text(String(format: "%@ · %.0f min · %.1f %%/h · ≈ %.1f h from full%@",
                                    t.date.formatted(date: .abbreviated, time: .shortened), t.minutes, t.drainPerHour,
                                    t.projectedHoursFull, t.withRumble ? " · with rumble" : ""))
                            .font(.caption.monospacedDigit())
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func calibrationControls(_ rec: BatteryRecord?) -> some View {
        if let run = rec?.calibration, run.stage != .done {
            switch run.stage {
            case .waitingForFull:
                HStack {
                    Label("Step 1 of 2: charge it until it's full. Leave it plugged in; NS2 Bridge notices when charging stops.", systemImage: "bolt.batteryblock")
                    Spacer()
                    Button("Cancel") { model.cancelBatteryCalibration() }
                }
            case .discharging:
                HStack {
                    Label(String(format: "Step 2 of 2: unplug and play wirelessly until it's low. %.0f minutes recorded so far.", run.dischargeMinutes),
                          systemImage: "battery.75percent")
                    Spacer()
                    Button("Finish now") { model.finishBatteryCalibrationNow() }
                    Button("Cancel") { model.cancelBatteryCalibration() }
                }
            case .done:
                EmptyView()
            }
        } else {
            HStack {
                Button("Start calibration") { model.startBatteryCalibration() }.disabled(!model.isConnected)
                if rec?.curve.measured == true {
                    Button("Reset to typical curve") { model.resetBatteryCurve() }
                    Label("Calibrated", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().bold()).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func stateText(_ r: BatteryReading?) -> String {
        guard let r else { return model.isConnected ? "Reading battery…" : "No controller" }
        if r.charging { return "Charging" }
        if r.externalPower { return "Plugged in · full" }
        return "On battery"
    }

    private func levelText(_ l: Double) -> String {
        model.selectedKind.isSwitch2Family ? "\(Int((l * 9).rounded())) of 9" : "\(Int((l * 4).rounded())) of 4"
    }

    private func hours(_ s: Double) -> String { s < 3600 ? "\(Int(s / 60)) min" : String(format: "%.1f h", s / 3600) }

    private func gaugeColor(_ p: Double?) -> Color {
        guard let p else { return .gray }
        return p < 20 ? .red : (p < 40 ? .orange : .green)
    }

    private func etaText(pct: Double?, rate: Double, charging: Bool) -> String? {
        guard let pct else { return nil }
        if charging, rate > 0.5 {
            let target = model.chargeAlertEnabled ? model.chargeAlertPercent : 100
            guard pct < target else { return nil }
            return String(format: "≈ %@ to %.0f%%", duration((target - pct) / rate), target)
        }
        if !charging, rate < -0.5 { return String(format: "≈ %@ left", duration(pct / -rate)) }
        return nil
    }

    private func duration(_ h: Double) -> String {
        h < 1 ? "\(Int((h * 60).rounded())) min" : String(format: "%.1f h", h)
    }
}
