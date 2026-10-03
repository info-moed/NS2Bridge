import AppKit
import NS2Kit
import SwiftUI

struct GamesPane: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Games").font(.title2.bold())
                    Text("Add a game and NS2 Bridge checks how it does rumble, fixes what it can, and confirms it works when you play.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.addGame() } label: { Label("Add game…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }

            if let s = model.session { LiveCheck(session: s) }

            if model.games.isEmpty {
                Text("No games yet — click Add game… and pick an app (for example Wave Race 64 Recompiled).")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 30).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            } else {
                VStack(spacing: 10) {
                    ForEach(model.games, id: \.self) { GameRow(url: $0) }
                }
            }

            if let err = model.gameBridgeError {
                Label("Rumble link not listening: \(err)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("Games with the helper installed rumble however you launch them. Others: quit the game and launch it from here, since the helper attaches at launch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GameRow: View {
    @Environment(BridgeModel.self) private var model
    let url: URL
    @State private var expanded = false

    var body: some View {
        let a = model.analyses[url.path]
        let verified = model.verifiedGames.contains(url.path)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(url.deletingPathExtension().lastPathComponent).font(.headline)
                        if verified {
                            Label("Rumble verified", systemImage: "checkmark.seal.fill")
                                .font(.caption.bold()).foregroundStyle(.green)
                        }
                    }
                    if model.analyzing.contains(url.path) {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking how this game does rumble…") }
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let a {
                        Label(a.headline, systemImage: icon(a.verdict))
                            .font(.caption).foregroundStyle(color(a.verdict))
                    }
                    ForEach(model.driverReports[url.path] ?? [], id: \.productID) { r in
                        Label(r.isProblem
                              ? "Last run: N64 read without SDL's N64 driver, so input was wrong. Launch from here or install the helper."
                              : "Last run: \(ControllerKind(productID: r.productID)?.shortName ?? "controller") on \(r.isVirtual ? "Bluetooth (NS2 Bridge's virtual gamepad)" : r.usesSDLDriver ? "SDL's own driver" : "SDL's generic driver") ✓",
                              systemImage: r.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .font(.caption).foregroundStyle(r.isProblem ? .red : .secondary)
                    }
                    if a?.n64DriverInSDL == false {
                        Label("N64 controller hidden from this game (its SDL is too old for it)", systemImage: "eye.slash")
                            .font(.caption).foregroundStyle(.orange)
                    } else if a?.changesControllerDrivers == true, !model.isHelperInstalled(url) {
                        Label("Changes SDL's controller drivers: play it from here or install the helper for the N64", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                actions(a)
            }
            if let a, expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(a.findings, id: \.self) { f in
                        Text("• \(f)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if a.verdict == .needsInstall || model.isHelperInstalled(url) {
                        Text(model.isHelperInstalled(url)
                             ? "The rumble helper is installed inside this game (originals backed up in ~/Library/Application Support/NS2Bridge/Backups). Remove it any time to restore the game exactly."
                             : "Fix: install the helper into the game. NS2 Bridge backs up the game's SDL library, places the helper next to it, and re-signs only what macOS requires. No copies.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if GameAnalyzer.legacyCopy(of: url) != nil {
                        HStack {
                            Text("An old rumble-ready copy from NS2 Bridge 0.1 is still in ~/Applications/NS2 Bridge Games.")
                                .font(.caption).foregroundStyle(.orange)
                            Button("Move it to the Trash") { model.trashLegacyCopy(url) }.font(.caption)
                        }
                    }
                    HStack {
                        if model.isHelperInstalled(url) {
                            if model.helperNeedsUpdate(url) {
                                Button("Update helper in game") { model.installHelper(url) }
                            }
                            Button("Remove helper from game") { model.uninstallHelper(url) }
                        } else if a.verdict == .ready {
                            Button("Install into game (rumble from Finder/Steam too)") { model.installHelper(url) }
                        }
                        Button("Check again") { model.analyze(url) }
                        Button("Remove from list", role: .destructive) { model.removeGame(url) }
                    }
                    .buttonStyle(.borderless).font(.caption).padding(.top, 2)
                }
                .padding(.leading, 56)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    }

    @ViewBuilder private func actions(_ a: GameAnalysis?) -> some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "info.circle") }
                .buttonStyle(.borderless).help("Details")
            if model.canLaunchWithRumble(url) {
                Button { model.launch(url) } label: { Label("Play with rumble", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
            } else if a?.verdict == .needsInstall {
                if model.installing.contains(url.path) {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.caption)
                } else {
                    Button { model.installHelper(url) } label: { Label("Install rumble into game", systemImage: "wand.and.stars") }
                        .buttonStyle(.borderedProminent)
                }
            } else if a != nil {
                Button { model.launchPlain(url) } label: { Label("Play (no rumble)", systemImage: "play") }
            }
        }
    }

    private func icon(_ v: GameAnalysis.Verdict) -> String {
        switch v {
        case .ready: return "checkmark.circle.fill"
        case .needsInstall: return "wrench.and.screwdriver.fill"
        default: return "xmark.circle"
        }
    }

    private func color(_ v: GameAnalysis.Verdict) -> Color {
        switch v {
        case .ready: return .green
        case .needsInstall: return .orange
        default: return .secondary
        }
    }
}

/// Step-by-step confirmation for the game that was just launched.
struct LiveCheck: View {
    @Environment(BridgeModel.self) private var model
    let session: LaunchSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Checking \(session.name)").font(.headline)
                Spacer()
                Button("Dismiss") { model.session = nil }.buttonStyle(.borderless).font(.caption)
            }
            step(session.launched, "Game launched")
            step(session.helperLoaded != nil,
                 session.helperLoaded.map { "Rumble helper attached (SDL\($0))" } ?? "Rumble helper attaching…",
                 failed: session.timedOut && session.helperLoaded == nil,
                 failText: "Helper didn't attach — try Check again, or make a rumble-ready copy.")
            step(session.rumbleSeen,
                 session.rumbleSeen ? "Game rumble received — working ✓" : "Now do something in the game that should rumble…",
                 pending: session.helperLoaded != nil)
            if let e = model.lastGameRumble {
                Text(String(format: "Last request: low %.0f%%  high %.0f%%  %d ms  ·  %d total",
                            e.low * 100, e.high * 100, e.durationMs, model.gameRumbleEvents))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if session.helperLoaded != nil, !session.rumbleSeen {
                Text("Nothing yet? Check the game's own rumble setting is on (recompiled ports usually have one under controls or input).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).stroke(session.rumbleSeen ? Color.green : Color.accentColor, lineWidth: 1.5))
    }

    private func step(_ done: Bool, _ text: String, failed: Bool = false, failText: String = "", pending: Bool = true) -> some View {
        HStack(spacing: 8) {
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else if failed { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            else if pending { ProgressView().controlSize(.small) }
            else { Image(systemName: "circle").foregroundStyle(.secondary) }
            Text(failed ? failText : text).foregroundStyle(done || failed ? .primary : .secondary)
        }
    }
}
