import NS2Kit
import SwiftUI

struct CalibratePane: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        let kind = model.selectedKind
        let stickCount = kind.stickNames.count
        VStack(alignment: .leading, spacing: 18) {
            Text("Calibrate sticks").font(.title2.bold())
            Text("Teaches NS2 Bridge where \(model.selected.map { "P\($0.player)'s \($0.kind.displayName)" } ?? "your controller")'s stick\(stickCount > 1 ? "s rest" : " rests") and how far \(stickCount > 1 ? "they reach" : "it reaches"), so center reads as exactly 0 and a full push as 100%. Saved to the profile “\(model.profile.name)”.")
                .foregroundStyle(.secondary)

            instructions(stickCount: stickCount)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))

            HStack(alignment: .top, spacing: 28) {
                ForEach(0..<stickCount, id: \.self) { n in
                    StickPad(title: kind.stickNames[n],
                             raw: n < (model.input?.sticks.count ?? 0) ? model.input?.sticks[n] : nil,
                             cal: model.calibration(n),
                             octagon: kind.octagonalGate,
                             trail: n < model.trails.count ? model.trails[n] : [],
                             recordingGood: model.calStep == .range ? model.rangeProgress[n] : nil)
                }
            }

            HStack(spacing: 28) {
                ForEach(0..<stickCount, id: \.self) { n in
                    DeadzoneSlider(title: "\(kind.stickNames[n]) deadzone",
                                   value: Binding(get: { model.calibration(n).deadzone },
                                                  set: { model.setDeadzone($0, stick: n) }))
                }
            }
            Text("Deadzone ignores tiny movements around center. Raise it if the character drifts when you're not touching the stick.")
                .font(.caption).foregroundStyle(.secondary)

            if kind == .gameCube {
                Divider()
                TriggerTestSection()
            }
        }
        .disabled(!model.isConnected)
    }

    @ViewBuilder private func instructions(stickCount: Int) -> some View {
        switch model.calStep {
        case .idle:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready").font(.headline)
                    Text("Takes about 10 seconds. Click Start, then follow the two steps.")
                }
                Spacer()
                Button("Reset to defaults") { model.resetCalibration() }
                Button("Start calibration") { model.startCalibration() }.buttonStyle(.borderedProminent)
            }
        case .center:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stickCount > 1 ? "Step 1 of 2: let go of both sticks" : "Step 1 of 2: let go of the stick").font(.headline)
                    Text("Measuring where \(stickCount > 1 ? "they rest" : "it rests")…")
                }
            }
        case .range:
            let p = model.rangeProgress
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stickCount > 1 ? "Step 2 of 2: roll both sticks around the very edge, 3 times each" : "Step 2 of 2: roll the stick around the very edge, 3 times").font(.headline)
                    HStack(spacing: 14) {
                        ForEach(0..<stickCount, id: \.self) { n in
                            Label(model.selectedKind.stickNames[n], systemImage: p[n] ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(p[n] ? .green : .secondary)
                        }
                    }
                }
                Spacer()
                Button("Cancel") { model.cancelCalibration() }
                Button("Finish") { model.finishCalibration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!p.allSatisfy { $0 })
            }
        case .done(let msg):
            HStack {
                Label(msg, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Spacer()
                Button("Calibrate again") { model.startCalibration() }
            }
        case .failed(let msg):
            HStack {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Try again") { model.startCalibration() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct DeadzoneSlider: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...0.3, step: 0.01)
        }
        .frame(width: 240)
    }
}

/// Square pad: outer circle = full travel, dashed circle = deadzone, trail = recent positions.
struct StickPad: View {
    let title: String
    let raw: Stick?
    let cal: StickCalibration
    var octagon = false
    let trail: [CGPoint]
    let recordingGood: Bool?

    var body: some View {
        let size: CGFloat = 220
        let v: (x: Double, y: Double) = raw.map { cal.apply($0) } ?? (x: 0, y: 0)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                if let good = recordingGood {
                    Image(systemName: good ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(good ? .green : .secondary)
                }
            }
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                // An octagonal gate's diagonal notches sit outside the unit circle; shrink to fit.
                let dg = ControllerKind.n64Diagonal
                let r = (sz.width / 2 - 10) / (octagon ? (2 * dg * dg).squareRoot() : 1)
                func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y - y * r) }

                if octagon {
                    // N64 gate: cardinals at full travel, diagonal notches at 69/85 on each axis.
                    let verts: [(Double, Double)] = [(1, 0), (dg, dg), (0, 1), (-dg, dg), (-1, 0), (-dg, -dg), (0, -1), (dg, -dg)]
                    var gate = Path()
                    gate.move(to: pt(verts[0].0, verts[0].1))
                    for v in verts.dropFirst() { gate.addLine(to: pt(v.0, v.1)) }
                    gate.closeSubpath()
                    ctx.fill(gate, with: .color(.gray.opacity(0.12)))
                    ctx.stroke(gate, with: .color(.gray.opacity(0.6)), lineWidth: 1.5)
                    for v in verts {   // notch markers
                        let p = pt(v.0, v.1)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(.gray.opacity(0.7)))
                    }
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.gray.opacity(0.12)))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.gray.opacity(0.6)), lineWidth: 1.5)
                }
                let dz = r * cal.deadzone
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - dz, y: c.y - dz, width: 2 * dz, height: 2 * dz)),
                           with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
                ctx.stroke(cross, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)

                if trail.count > 1 {
                    var p = Path()
                    p.move(to: pt(trail[0].x, trail[0].y))
                    for t in trail.dropFirst() { p.addLine(to: pt(t.x, t.y)) }
                    ctx.stroke(p, with: .color(.accentColor.opacity(0.35)), lineWidth: 1.5)
                }
                let d = pt(v.x, v.y)
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - 7, y: d.y - 7, width: 14, height: 14)), with: .color(.accentColor))
            }
            .frame(width: size, height: size)
            Text(raw.map { "raw \($0.x), \($0.y)" } ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(String(format: "output %+.2f, %+.2f  ·  %d%%", v.x, v.y, Int(min(1, max(abs(v.x), abs(v.y), (v.x * v.x + v.y * v.y).squareRoot() / (octagon ? (2 * ControllerKind.n64Diagonal * ControllerKind.n64Diagonal).squareRoot() : 1))) * 100)))
                .font(.caption.monospaced())
        }
    }
}

// MARK: - Analog triggers (GameCube)

struct TriggerTestSection: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Analog triggers").font(.title3.bold())
            Text("Checks that L and R rest still, travel smoothly all the way, and click only at the end, then saves their range to “\(model.profile.name)” so a full press reads exactly 100%.")
                .foregroundStyle(.secondary)

            HStack(spacing: 28) {
                TriggerBar(name: "L", raw: model.gcState?.leftTrigger, percent: model.input?.triggers.first,
                           clicked: model.gcState?.buttons.contains(.l) ?? false, range: model.profile.triggers?.first)
                TriggerBar(name: "R", raw: model.gcState?.rightTrigger,
                           percent: (model.input?.triggers.count ?? 0) > 1 ? model.input?.triggers[1] : nil,
                           clicked: model.gcState?.buttons.contains(.r) ?? false,
                           range: (model.profile.triggers?.count ?? 0) > 1 ? model.profile.triggers?[1] : nil)
            }

            steps
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
        }
    }

    @ViewBuilder private var steps: some View {
        switch model.triggerTest {
        case .idle:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trigger test").font(.headline)
                    Text(model.profile.triggers == nil ? "Not calibrated: the range is learned as you play." : "Calibrated for this profile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.profile.triggers != nil { Button("Reset") { model.resetTriggerRanges() } }
                Button("Start trigger test") { model.startTriggerTest() }.buttonStyle(.borderedProminent)
            }
        case .rest:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Step 1 of 3: don't touch the triggers").font(.headline)
                    Text("Measuring where they rest…")
                }
            }
        case .press(let i):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Step \(i + 2) of 3: press \(i == 0 ? "L" : "R") slowly all the way until it clicks, then let go").font(.headline)
                    Text("Take about 2 seconds to go down: the test counts every position on the way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancelTriggerTest() }
            }
        case .done(let results, let saved):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    let pass = results.allSatisfy(\.passed)
                    Label(pass ? "Both triggers pass" : "Problems found", systemImage: pass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(pass ? .green : .orange)
                    Spacer()
                    if !saved { Button("Save range anyway") { model.saveTriggerRanges(results) } }
                    Button("Test again") { model.startTriggerTest() }
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["", "Rest", "Noise", "Click at", "Peak", "Positions", "Biggest jump"], id: \.self) {
                            Text($0).font(.caption.bold())
                        }
                    }
                    ForEach(results, id: \.name) { r in
                        GridRow {
                            Text(r.name).bold()
                            Text("\(r.rest)"); Text("±\(r.restNoise)")
                            Text(r.clickAt.map { "\($0)" } ?? "never")
                            Text("\(r.peak)"); Text("\(r.distinctSteps)"); Text("\(r.biggestJump)")
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
                ForEach(results.flatMap { r in r.problems.map { "\(r.name): \($0)" } }, id: \.self) {
                    Text("• \($0)").font(.caption).foregroundStyle(.orange)
                }
                ForEach(results.flatMap { r in r.notes.map { "\(r.name): \($0)" } }, id: \.self) {
                    Text("• \($0)").font(.caption).foregroundStyle(.secondary)
                }
                if saved { Text("Saved to “\(model.profile.name)”: a full press now reads 100%.").font(.caption).foregroundStyle(.green) }
            }
        case .failed(let msg):
            HStack {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Try again") { model.startTriggerTest() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Raw trigger travel (0–255) with the saved range marked, the calibrated %, and the click.
struct TriggerBar: View {
    let name: String
    let raw: UInt8?
    let percent: Double?
    let clicked: Bool
    let range: TriggerRange?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                if clicked { Label("click", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 5).fill(clicked ? Color.green : Color.accentColor)
                        .frame(width: w * CGFloat(raw ?? 0) / 255)
                    if let range {
                        ForEach([range.rest, range.full], id: \.self) { v in
                            Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2).offset(x: w * CGFloat(v) / 255)
                        }
                    }
                }
            }
            .frame(width: 260, height: 18)
            Text("raw \(raw.map(String.init) ?? "–") / 255 · \(Int(((percent ?? 0) * 100).rounded()))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
