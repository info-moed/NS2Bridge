import AppKit
import NS2Kit
import SwiftUI

struct WirelessPane: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Wireless").font(.title2.bold())
            Text("Use your controllers over Bluetooth. USB is still the fastest link, by a few milliseconds.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("N64 Controller").font(.headline)
                        Spacer()
                        if let c = model.controllers.first(where: { $0.kind == .n64 && $0.transport == .bluetooth }) {
                            Label("Connected wirelessly as P\(c.player)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    Text("The N64 controller uses classic Bluetooth, which macOS pairs by itself. Pair it once and NS2 Bridge picks it up automatically every time it connects:")
                        .font(.callout)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("1. Unplug the USB cable.")
                        Text("2. Hold the small SYNC button on the top of the controller until the lights sweep.")
                        Text("3. In Bluetooth settings, click Connect next to \"N64 Controller\".")
                    }
                    .font(.callout)
                    Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) } label: {
                        Label("Open Bluetooth Settings", systemImage: "gear")
                    }
                    Text("After that, just press a button on the controller to reconnect. It reports every ~15 ms wirelessly (8 ms on USB).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Switch 2 Pro Controller and GameCube Controller").font(.headline).padding(.top, 4)
            Text("These use Bluetooth LE and connect through NS2 Bridge directly (not Bluetooth settings). Unplug the USB cable, click Connect, then hold the small SYNC button on the controller.")
                .font(.caption).foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        stateIcon
                        Text(stateText).font(.headline)
                        Spacer()
                        switch model.bleState {
                        case .connected, .connecting, .scanning:
                            Button("Disconnect") { model.disconnectWireless() }
                        default:
                            Button { model.connectWireless() } label: {
                                Label("Connect wirelessly", systemImage: "antenna.radiowaves.left.and.right")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.bleState == .off || model.bleState == .unauthorized)
                        }
                    }
                    if case .scanning = model.bleState {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. Unplug the USB cable.")
                            Text("2. Press the small round SYNC button on the top edge of the controller, next to the USB-C port.")
                            Text("3. The player lights will sweep — NS2 Bridge connects within a few seconds.")
                        }
                        .font(.callout)
                    }
                    if model.bleState == .unauthorized {
                        Text("Bluetooth access is off for NS2 Bridge. Turn it on in System Settings → Privacy & Security → Bluetooth.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                .padding(6)
            }

            if case .connected = model.bleState {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Latency").font(.headline)
                    BluetoothSpeedPicker()
                    HStack(spacing: 16) {
                        Stat(title: "Report rate", value: model.bleRate > 0 ? String(format: "%.0f Hz", model.bleRate) : "measuring…")
                        Stat(title: "Interval", value: model.bleIntervalMs > 0 ? String(format: "%.1f ms", model.bleIntervalMs) : "—",
                             warn: model.bleIntervalMs > model.bluetoothExpectedMs * 1.5)
                        Stat(title: "Jitter", value: model.bleJitterMs > 0 ? String(format: "± %.1f ms", model.bleJitterMs) : "—")
                        Stat(title: "USB for comparison", value: "250 Hz · 4 ms")
                    }
                    Text("The controller never asks for a faster connection, so macOS would leave it at 30 ms. NS2 Bridge asks macOS for a shorter interval: Fastest (7.5 ms, 133 reports/s) matches USB within a few milliseconds; Fast (15 ms) and Standard (macOS's 30 ms) use less of the controller's battery. Fastest steps down to Fast by itself if reports stop arriving at 7.5 ms.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.bleSpeedInEffect == .fast && model.bluetoothSpeed == .fastest {
                        Label("Running at Fast: reports didn't keep up at 7.5 ms on this connection.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Good to know").font(.headline)
                    Text("• Games see Bluetooth controllers through NS2 Bridge's helper, like Steam Input: in games launched from the Games tab or with the helper installed, the controller appears as a normal gamepad with rumble and, in SDL3 games, gyro.")
                    Text("• Reconnecting after the controller sleeps needs the SYNC button again (NS2 Bridge doesn't do Nintendo's pairing).")
                    Text("• The NS2 Bridge app itself (live view, calibration, haptics, diagnostics) works fully over Bluetooth.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var stateText: String {
        switch model.bleState {
        case .off: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission needed"
        case .idle: return "Not connected"
        case .scanning: return "Looking for the controller…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .connected(let n): return "\(n) connected wirelessly"
        case .failed(let e): return "Couldn't connect: \(e)"
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch model.bleState {
        case .connected: Circle().fill(.green).frame(width: 10, height: 10)
        case .scanning, .connecting: ProgressView().controlSize(.small)
        case .failed, .unauthorized: Circle().fill(.red).frame(width: 10, height: 10)
        default: Circle().fill(.gray).frame(width: 10, height: 10)
        }
    }
}

/// Wanted Bluetooth speed for Switch 2 controllers (applies at once, and at every connect).
private struct BluetoothSpeedPicker: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Speed", selection: $model.bluetoothSpeed) {
            ForEach(BluetoothSpeed.allCases) { s in
                Text("\(s.title) · \(s.intervalMs.formatted()) ms").tag(s)
            }
        }
        .pickerStyle(.segmented).frame(width: 420)
    }
}
