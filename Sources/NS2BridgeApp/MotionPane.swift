import NS2Kit
import SceneKit
import SwiftUI

/// Gyro / accelerometer (Switch 2 Pro), gyro calibration, and the DSU (Cemuhook) server.
struct MotionPane: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            Text("Motion").font(.title2.bold())
            Text("Gyro aiming and motion controls in emulators. NS2 Bridge reads the Switch 2 Pro Controller's gyroscope and accelerometer and serves them, with buttons and sticks, over DSU (the “CemuHook” protocol).")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Gyro and accelerometer (Switch 2 Pro)").font(.headline)
                    Picker("Motion", selection: $model.motionMode) {
                        ForEach(BridgeModel.MotionMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                    Text(motionStatus).font(.callout).foregroundStyle(model.motionEnabled ? .green : .secondary)
                    Label("While motion is flowing, games that read the Pro through SDL directly can't see it (the controller then sends a report format macOS doesn't describe). Automatic avoids that: motion is only on while an emulator is using the Pro over DSU.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("N64 and GameCube controllers have no motion sensors; they still appear to DSU clients with their buttons and sticks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }

            if model.selectedKind.hasMotion {
                live
                calibration
            } else if model.selected != nil {
                Text("The selected controller has no motion sensors. Select a Switch 2 Pro Controller above to see live motion.")
                    .foregroundStyle(.secondary)
            }

            dsuBox
        }
    }

    private var motionStatus: String {
        switch model.motionMode {
        case .off: return "Off: the Pro works in every game; no gyro."
        case .on: return "On: gyro flows all the time."
        case .automatic:
            return model.motionEnabled ? "On now: an emulator is using the Pro over DSU."
                                       : "Waiting: turns on when an emulator connects to the DSU server for the Pro."
        }
    }

    // MARK: Live readout

    private var live: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live").font(.headline)
            if let m = model.motion {
                HStack(alignment: .top, spacing: 18) {
                    SceneView(scene: model.motionScene.scene, pointOfView: model.motionScene.camera,
                              options: [.rendersContinuously])
                        .frame(width: 360, height: 250)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pick up the controller: the model should move the same way.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: "Tilt forward/back  %+5.0f°", model.tilt.pitch)).monospacedDigit()
                            Text(String(format: "Tilt left/right    %+5.0f°", model.tilt.roll)).monospacedDigit()
                        }
                        .font(.callout.monospaced())
                        VStack(alignment: .leading, spacing: 3) {
                            legend(.red, "X: right")
                            legend(.green, "Y: up, out of the face")
                            legend(.blue, "Z: toward you")
                            legend(.yellow, "measured gravity: should always point straight up")
                        }
                        .font(.caption)
                        Button("Re-center") { model.resetOrientation() }
                            .help("Levels the model and faces it forward. Turning left/right slowly drifts without a compass.")
                    }
                    .frame(maxWidth: 260, alignment: .leading)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("X").font(.caption.bold()); Text("Y").font(.caption.bold()); Text("Z").font(.caption.bold())
                    }
                    GridRow {
                        Text("Gyro °/s").font(.caption)
                        AxisBar(value: m.gyro.x, range: 500, label: "pitch")
                        AxisBar(value: m.gyro.y, range: 500, label: "yaw")
                        AxisBar(value: m.gyro.z, range: 500, label: "roll")
                    }
                    GridRow {
                        Text("Accel g").font(.caption)
                        AxisBar(value: m.accel.x, range: 2, label: "right")
                        AxisBar(value: m.accel.y, range: 2, label: "up")
                        AxisBar(value: m.accel.z, range: 2, label: "toward you")
                    }
                }
                Text(String(format: "IMU %.1f °C · controller clock %.3f s", m.temperatureC, Double(m.timestampMicros) / 1e6))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("Flat on a table, Accel Y reads about +1 g and the gyro about 0. Tilting the top edge up turns gyro X positive.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.motionEnabled
                     ? "Waiting for motion data… (If nothing arrives, press Reconnect in Diagnostics.)"
                     : "Motion is off right now. Choose Always on to see live values here, or connect an emulator in Automatic.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Calibration

    private var calibration: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gyro calibration").font(.headline)
                Text("Every gyro reads slightly off zero when still, which makes aim drift. Put the controller down on a table, then measure the offset (3 seconds). It's saved for this controller.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { model.startGyroCalibration() } label: { Label("Calibrate gyro", systemImage: "scope") }
                        .disabled(!model.motionEnabled || model.motion == nil || isMeasuring)
                    Button("Reset") { model.resetGyroCalibration() }
                    switch model.gyroCal {
                    case .idle:
                        let b = model.gyroBias
                        Text(b == .zero ? "Not calibrated" : String(format: "Offset %+.2f, %+.2f, %+.2f °/s", b.x, b.y, b.z))
                            .font(.caption).foregroundStyle(.secondary)
                    case .measuring:
                        ProgressView().controlSize(.small)
                        Text("Hold still…").font(.caption)
                    case .done(let s):
                        Label(s, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    case .failed(let s):
                        Label(s, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(6)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 4)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var isMeasuring: Bool { if case .measuring = model.gyroCal { return true } else { return false } }

    // MARK: DSU

    private var dsuBox: some View {
        @Bindable var model = model
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.dsuEnabled) { Text("DSU server on 127.0.0.1:\(String(DSUServer.defaultPort))").font(.headline) }
                if let e = model.dsuError {
                    Label(e, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                } else if model.dsuEnabled {
                    Text(model.dsuClients == 0 ? "No emulator connected yet." : "\(model.dsuClients) emulator\(model.dsuClients == 1 ? "" : "s") listening.")
                        .font(.caption).foregroundStyle(model.dsuClients > 0 ? .green : .secondary)
                }
                Text("Player 1 is DSU slot 1 (index 0), player 2 slot 2, and so on. Buttons go by position: the bottom face button is Cross/South.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("• Dolphin: Controllers → Alternate Input Sources → DSU Client → Add 127.0.0.1, port 26760.")
                    Text("• Cemu: Input settings → API “DSUController”, 127.0.0.1:26760.")
                    Text("• Ryujinx: Input → Motion → “CemuHook compatible”, server 127.0.0.1:26760, slot = player − 1.")
                }
                .font(.caption)
            }
            .padding(6)
        }
    }
}

/// A signed value as a centered bar with its number.
struct AxisBar: View {
    let value: Double
    let range: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { g in
                let w = g.size.width, half = w / 2
                let v = max(-1, min(1, value / range))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                    Rectangle().fill(Color.accentColor)
                        .frame(width: abs(v) * half)
                        .offset(x: v >= 0 ? half : half - abs(v) * half)
                    Rectangle().fill(Color.secondary).frame(width: 1).offset(x: half)
                }
            }
            .frame(width: 130, height: 10)
            Text(String(format: "%+.2f %@", value, label)).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }
}
