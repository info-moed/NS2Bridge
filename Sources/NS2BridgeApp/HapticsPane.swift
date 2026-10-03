import NS2Kit
import SwiftUI

struct HapticsPane: View {
    @Environment(BridgeModel.self) private var model

    private var description: String {
        let saved = "Settings are saved to the profile “\(model.profile.name)”."
        switch model.selectedKind {
        case .n64: return "The N64 controller's built-in rumble motor (original-Switch rumble format). " + saved
        case .gameCube: return "The GameCube controller's single rumble motor. It only switches on and off, so strength is made by pulsing it; the low/high bands feel the same. " + saved
        case .switch2Pro: return "HD Rumble 2: the controller's two vibration motors (left and right grips). " + saved
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            Text("Haptics").font(.title2.bold())
            Text(description)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $model.hapticsEnabled) { Text("Vibration on").font(.headline) }
                    HStack {
                        Text("Strength")
                        Slider(value: $model.hapticsIntensity, in: 0...1)
                        Text("\(Int((model.hapticsIntensity * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .disabled(!model.hapticsEnabled)
                    Text("Scales every vibration sent to this controller type, including game rumble.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Test effects").font(.headline)
                HStack(spacing: 10) {
                    effect("Tap", "hand.tap", .tap)
                    effect("Buzz", "waveform", .buzz)
                    effect("Heartbeat", "heart", .heartbeat)
                    effect("Ramp up", "chart.line.uptrend.xyaxis", .ramp)
                }
                HStack(spacing: 10) {
                    if model.selectedKind == .switch2Pro {
                        effect("Left motor", "l.circle", .leftOnly)
                        effect("Right motor", "r.circle", .rightOnly)
                    }
                    effect("Low band", "speaker.wave.1", .lowBand)
                    effect("High band", "speaker.wave.3", .highBand)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Manual control").font(.headline)
                        Spacer()
                        Button("Stop") { model.stopHaptics() }
                    }
                    Text("Each motor plays two bands at once — a deep low band and a sharper high band. Drag a strength slider to feel it continuously.")
                        .font(.caption).foregroundStyle(.secondary)
                    slider("Low band", $model.testLow, 0...1, "\(Int((model.testLow * 100).rounded()))%")
                    slider("High band", $model.testHigh, 0...1, "\(Int((model.testHigh * 100).rounded()))%")
                    if model.selectedKind.hasPitchControl {
                        Divider()
                        HStack {
                            Text("Pitch (experimental)").font(.subheadline.bold())
                            Spacer()
                            Button("Reset pitch") { model.resetPitch() }.buttonStyle(.borderless)
                        }
                        slider("Low pitch", $model.testLowFreq, 0...1023, String(format: "0x%03X", Int(model.testLowFreq)))
                        slider("High pitch", $model.testHighFreq, 0...1023, String(format: "0x%03X", Int(model.testHighFreq)))
                        Text("Raw 10-bit pitch codes: nobody has published how they map to Hz yet. Defaults (0x112 / 0x187) are what SDL and Linux use. Strength is capped at a safe level no matter what.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }
        }
        .disabled(!model.isConnected)
        .onDisappear { model.stopHaptics() }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ label: String) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: v, in: r).onChange(of: v.wrappedValue) { model.updateTestRumble() }
            Text(label).monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }

    private func effect(_ title: String, _ icon: String, _ e: HapticEffect) -> some View {
        Button { model.play(e) } label: {
            Label(title, systemImage: icon).frame(minWidth: 110)
        }
        .controlSize(.large)
        .disabled(!model.hapticsEnabled)
    }
}
