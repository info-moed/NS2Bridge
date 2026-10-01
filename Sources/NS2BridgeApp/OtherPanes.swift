import NS2Kit
import SwiftUI

// MARK: - Button test

struct ButtonTestPane: View {
    @Environment(BridgeModel.self) private var model
    private let cols = Array(repeating: GridItem(.fixed(118), spacing: 10), count: 5)

    var body: some View {
        let names = model.selectedKind.buttonNames
        let held = model.input?.pressed ?? []
        let seen = model.seenButtons
        let done = names.filter { seen.contains($0) }.count
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Button test").font(.title2.bold())
                    Text("Press every button on \(model.selected.map { "P\($0.player)'s \($0.kind.displayName)" } ?? "the controller") once. Each tile turns green when it's been seen, and glows while held.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") { model.resetButtonTest() }
            }
            ProgressView(value: Double(done), total: Double(names.count)) {
                Text(done == names.count ? "All \(done) buttons work ✓" : "\(done) of \(names.count) buttons verified")
                    .font(.headline)
                    .foregroundStyle(done == names.count ? .green : .primary)
            }
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                ForEach(names, id: \.self) { name in
                    let isHeld = held.contains(name), isSeen = seen.contains(name)
                    HStack {
                        Image(systemName: isSeen ? "checkmark.circle.fill" : "circle")
                        Text(name).font(.system(.body, design: .rounded).bold())
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(isHeld ? Color.accentColor : (isSeen ? Color.green.opacity(0.22) : Color.gray.opacity(0.14)))
                    )
                    .foregroundStyle(isHeld ? .white : (isSeen ? .green : .primary))
                }
            }
        }
        .disabled(!model.isConnected)
    }
}

// MARK: - Diagnostics

struct DiagnosticsPane: View {
    @Environment(BridgeModel.self) private var model

    private var fields: [(ClosedRange<Int>, String, Color)] {
        switch model.selectedKind {
        case .switch2Pro where model.raw.first == Report05.id:
            return [(0...0, "Report ID 0x05 (motion on)", .purple), (1...4, "Counter", .gray), (5...8, "Buttons", .blue),
                    (11...16, "Sticks", .teal), (32...34, "Battery mV / charge", .yellow),
                    (43...48, "IMU time / temperature", .gray), (49...60, "Accel + gyro", .orange)]
        case .gameCube:
            return [(0...0, "Report ID 0x0A", .purple), (1...1, "Counter", .gray), (2...2, "Power / battery", .yellow),
                    (3...5, "Buttons", .blue), (6...11, "Sticks", .teal), (13...14, "Analog L / R", .pink),
                    (15...15, "Motion length", .gray)]
        case .switch2Pro:
            return [(0...0, "Report ID 0x09", .purple), (1...1, "Counter", .gray), (2...2, "Power / battery", .yellow),
                    (3...5, "Buttons", .blue), (6...11, "Sticks", .teal), (12...15, "Status / motion length", .gray),
                    (16...45, "Motion (packed, not yet decoded)", .orange)]
        case .n64:
            return [(0...0, "Report ID 0x30", .purple), (1...1, "Timer", .gray), (2...2, "Battery / connection", .yellow),
                    (3...5, "Buttons", .blue), (6...8, "Stick", .teal), (9...11, "Unused 2nd stick", .gray),
                    (12...12, "Vibration status", .orange)]
        }
    }

    private func color(for i: Int) -> Color {
        fields.first { $0.0.contains(i) }?.2 ?? .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Diagnostics").font(.title2.bold())

            HStack(spacing: 16) {
                Stat(title: "Status", value: model.isConnected ? "Streaming" : "—")
                Stat(title: "Report rate", value: "\(model.rate) Hz",
                     warn: model.isConnected && Double(model.rate) < 800 / model.selectedKind.usbIntervalMs)
                Stat(title: "Battery", value: model.input.map { "\(Int(($0.battery * 100).rounded()))%" } ?? "—")
                Stat(title: "Power", value: model.input.map { $0.charging ? "Charging" : ($0.externalPower ? "USB" : "Battery") } ?? "—")
                Stat(title: "Controller", value: model.selected?.label ?? "—")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Live report (64 bytes)").font(.headline)
                Text("Each cell is one byte. It lights up orange while that byte is changing — useful for spotting which part of the report reacts to what you do.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(0..<4, id: \.self) { row in
                        GridRow {
                            ForEach(0..<16, id: \.self) { col in
                                let i = row * 16 + col
                                let b = i < model.raw.count ? model.raw[i] : 0
                                VStack(spacing: 1) {
                                    Text(String(format: "%02X", b)).font(.system(size: 12, design: .monospaced).bold())
                                    Text("\(i)").font(.system(size: 8)).foregroundStyle(.secondary)
                                }
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(model.activity[i] * 0.8)))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color(for: i).opacity(0.7), lineWidth: 1.5))
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    ForEach(fields, id: \.1) { f in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).stroke(f.2, lineWidth: 1.5).frame(width: 10, height: 10)
                            Text(f.1).font(.caption2)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button { model.reconnectSelected() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    .disabled(model.selected == nil || !model.selectedKind.needsInit)
                Button { model.toggleCapture() } label: {
                    Label(model.capturing ? "Stop recording (\(model.captureCount))" : "Record reports to Desktop",
                          systemImage: model.capturing ? "stop.circle.fill" : "record.circle")
                }
                .tint(model.capturing ? .red : nil)
                if model.lastCaptureURL != nil, !model.capturing {
                    Button("Show recording in Finder") { model.revealCapture() }
                }
            }
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var warn = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(warn ? .orange : .primary)
        }
        .padding(10)
        .frame(minWidth: 110, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}

// MARK: - Setup

struct SetupPane: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 22) {
            Text("Setup").font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $model.advancedMode) { Text("Advanced tools").font(.headline) }
                    Text("Basic shows the everyday tabs. Advanced adds Button Test, Motion (gyro and DSU for emulators), Latency Test and Diagnostics.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show the welcome guide again") { model.showWelcome = true }.padding(.top, 2)
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $model.sdlEnabled) {
                        Text("Let SDL games and emulators use this controller").font(.headline)
                    }
                    Text("Most Mac emulators and ports (RetroArch, Dolphin, Ares, recompiled N64 games…) read controllers through SDL. This tells SDL how to read the Switch 2 Pro and GameCube controllers, and keeps SDL's own N64 driver on even in games that switch it off. Applies to apps you open after turning it on — quit and reopen any that are already running.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Note: this also makes SDL skip Apple's controller framework for all pads, and replaces any SDL_GAMECONTROLLERCONFIG, SDL_JOYSTICK_HIDAPI or SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC you set yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Copy SDL mapping") { model.copySDLMapping() }.padding(.top, 2)
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $model.forceFeedbackEnabled) {
                        Text("Rumble in SDL games through macOS force feedback").font(.headline)
                    }
                    Text("Adds NS2 Bridge's force-feedback plug-in to each connected controller, so SDL games see rumble support by themselves: no helper, no changes to the game, however the game is launched. Works for games that read the controller as a generic joystick (the Switch 2 Pro on macOS). The plug-in is removed again when NS2 Bridge quits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Game compatibility").font(.headline)
                    Toggle(isOn: $model.xboxMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show up as an Xbox controller in games")
                            Text("For games launched from the Games tab. Games that only accept Xbox / XInput-style controllers will take it, and show Xbox button prompts.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Button layout", selection: $model.buttonLayout) {
                        Text("Match positions — bottom button is A (Xbox style)").tag(SDLMapping.Layout.positions)
                        Text("Match labels — the button marked A is A (Nintendo style)").tag(SDLMapping.Layout.labels)
                    }
                    .pickerStyle(.radioGroup)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                        Text("Open NS2 Bridge at login").font(.headline)
                    }
                    Text("Keeps it in the menu bar so the controller works the moment you plug it in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Coming later").font(.headline)
                    Text("Gyro / motion (for emulators via DSU, and gyro-as-mouse) · Rumble · NSO GameCube and N64 controllers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
