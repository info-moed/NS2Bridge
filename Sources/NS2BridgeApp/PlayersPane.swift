import NS2Kit
import SwiftUI

/// Connected controllers with player slots, plus profiles per controller type.
struct PlayersPane: View {
    @Environment(BridgeModel.self) private var model
    @State private var newName: [ControllerKind: String] = [:]
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Players").font(.title2.bold())
                Text("Every connected controller gets a player number, shown on its player lights. The Calibrate, Button Test, Haptics, Latency and Diagnostics tools act on the controller picked at the top of the window (Player 1 unless you choose another).")
                    .foregroundStyle(.secondary)
            }

            if model.controllers.isEmpty {
                Text("No controllers connected. Plug one in with a USB-C data cable, or connect a Switch 2 Pro Controller from Wireless.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            } else {
                VStack(spacing: 8) {
                    ForEach(model.controllers) { c in playerRow(c) }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles").font(.title2.bold())
                Text("A profile holds stick calibration, deadzones and vibration settings for one type of controller. The active profile applies to every controller of that type; switch profiles per game or per person.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ControllerKind.allCases) { kind in profileSection(kind) }
        }
    }

    private func playerRow(_ c: ControllerSummary) -> some View {
        HStack(spacing: 12) {
            PlayerBadge(player: c.player)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.kind.displayName).font(.headline)
                    if let tag = model.tag(forID: c.id) { Text(tag).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                Text("\(c.transport.rawValue) · \(c.ready ? "\(c.rate) reports/s" : "setting up…") · battery \(Int((c.battery * 100).rounded()))%\(c.charging ? " · charging" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                if let current = model.profile(forID: c.id) {
                    Picker("Profile", selection: Binding(get: { current.id }, set: { model.assignProfile($0, toController: c.id) })) {
                        ForEach(model.profiles.profiles(for: c.kind)) { Text($0.name).tag($0.id) }
                    }
                    .font(.caption).frame(width: 240)
                    .help("This controller's settings (calibration, vibration). Remembered for this controller: it gets them back whenever it reconnects.")
                }
            }
            Spacer()
            Picker("Player", selection: Binding(get: { c.player }, set: { model.assign(c.id, toPlayer: $0) })) {
                ForEach(1...4, id: \.self) { Text("Player \($0)").tag($0) }
            }
            .frame(width: 130)
            Button(c.id == model.selected?.id ? "Selected" : "Select") { model.select(c.id) }
                .disabled(c.id == model.selected?.id)
            Button { model.disconnect(c.id) } label: { Label("Turn off", systemImage: "power") }
                .disabled(!model.canDisconnect(c.id))
                .help(model.canDisconnect(c.id)
                      ? "Turn this wireless controller off to save its battery. Press a button to reconnect."
                      : "On USB the controller runs from the Mac and charges, so it isn't using its battery. Unplug it to disconnect.")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
        .contentShape(Rectangle())
        .modifier(ControllerActions(id: c.id, model: model))
    }

    private func profileSection(_ kind: ControllerKind) -> some View {
        let list = model.profiles.profiles(for: kind)
        let activeID = model.profiles.activeProfile(for: kind).id
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.displayName).font(.headline)
                Text("Each controller remembers its own profile (picker next to it above). The selected one here (●) is the starting point for controllers connecting for the first time.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(list) { p in
                    HStack(spacing: 10) {
                        Image(systemName: p.id == activeID ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(p.id == activeID ? Color.accentColor : .secondary)
                            .onTapGesture { model.setActiveProfile(p.id) }
                        if renaming == p.id {
                            TextField("Name", text: $renameText, onCommit: {
                                model.renameProfile(p.id, to: renameText); renaming = nil
                            })
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                        } else {
                            Text(p.name).fontWeight(p.id == activeID ? .bold : .regular)
                                .onTapGesture { model.setActiveProfile(p.id) }
                        }
                        Text(summary(p)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Rename") { renaming = p.id; renameText = p.name }.buttonStyle(.borderless)
                        Button("Delete", role: .destructive) { model.deleteProfile(p.id) }
                            .buttonStyle(.borderless)
                            .disabled(list.count <= 1)
                    }
                }
                HStack {
                    TextField("New profile name (copies the active one)", text: Binding(
                        get: { newName[kind] ?? "" }, set: { newName[kind] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 300)
                    Button("Add profile") {
                        model.addProfile(kind: kind, name: newName[kind] ?? "")
                        newName[kind] = ""
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ p: ControllerProfile) -> String {
        let dz = p.sticks.map { "\(Int(($0.deadzone * 100).rounded()))%" }.joined(separator: "/")
        return "deadzone \(dz) · vibration \(p.hapticsEnabled ? "\(Int((p.hapticsIntensity * 100).rounded()))%" : "off")"
    }
}
