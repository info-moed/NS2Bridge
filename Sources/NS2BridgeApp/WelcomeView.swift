import AppKit
import NS2Kit
import SwiftUI

/// First-launch guide: five short pages for everyday users. Shown once; reopen from Setup.
struct WelcomeView: View {
    @Environment(BridgeModel.self) private var model
    @State private var page = 0
    @State private var advanced = false
    @State private var openAtLogin = true

    var body: some View {
        @Bindable var model = model
        WelcomeContent(page: $page, advanced: $advanced, openAtLogin: $openAtLogin,
                       sdlEnabled: $model.sdlEnabled,
                       connected: model.controllers.sorted { $0.player < $1.player },
                       finish: { model.finishWelcome(advanced: advanced, openAtLogin: openAtLogin) })
            .onAppear { advanced = model.advancedMode; openAtLogin = model.launchAtLogin || !model.welcomeDone }
    }
}

/// The pages themselves, driven by plain values so they can also be rendered without a running model.
struct WelcomeContent: View {
    @Binding var page: Int
    @Binding var advanced: Bool
    @Binding var openAtLogin: Bool
    @Binding var sdlEnabled: Bool
    let connected: [ControllerSummary]
    let finish: () -> Void

    static let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < Self.pageCount - 1 {
                    Button("Skip") { finish() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .frame(height: 22)
            .padding([.horizontal, .top], 16)

            Group {
                switch page {
                case 0: welcome
                case 1: connect
                case 2: games
                case 3: feel
                default: mode
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44)
            .transition(.opacity)
            .id(page)

            HStack {
                Button("Back") { withAnimation { page -= 1 } }
                    .opacity(page == 0 ? 0 : 1).disabled(page == 0)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<Self.pageCount, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page < Self.pageCount - 1 {
                    Button("Next") { withAnimation { page += 1 } }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Get started") { finish() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 620, height: 520)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 96, height: 96)
            Text("Welcome to NS2 Bridge").font(.largeTitle.bold())
            Text("Your Nintendo controllers, ready for games on your Mac.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                point("gamecontroller.fill", .blue, "Plug in and play",
                      "Switch 2 Pro, GameCube and N64 controllers work as soon as they're connected.")
                point("waveform", .orange, "Rumble in games", "Feel the vibration in games and emulators that support it.")
                point("sparkles.tv", .purple, "Made for emulators and PC ports",
                      "Dolphin, RetroArch, recompiled N64 games and more.")
            }
            .padding(.top, 6)
            Spacer()
            Text("Unofficial app, not made or endorsed by Nintendo.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("cable.connector", "Connect a controller")
            step(1, "Plug it in with a USB-C cable that carries data.",
                 "Some cables only charge. If the controller charges but never shows up, try another cable.")
            step(2, "Look at the top of your screen.") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Each controller gets a colored tag in the menu bar. The color is the player:")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        tag("GC", player: 1, note: "Player 1")
                        tag("N64", player: 2, note: "Player 2")
                        tag("PC2", player: 3, note: "Player 3")
                        tag("GC", player: 4, note: "Player 4")
                    }
                }
            }
            step(3, "Prefer wireless?", "Open the **Wireless** tab later and follow its three steps.")
            Spacer()
            if let c = connected.first {
                Label("Connected: P\(c.player) · \(c.kind.displayName)\(connected.count > 1 ? " and \(connected.count - 1) more" : "")",
                      systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
            } else {
                Label("Waiting for a controller…", systemImage: "hourglass").foregroundStyle(.secondary)
            }
        }
    }

    private var games: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("play.rectangle.on.rectangle", "Play your games")
            step(1, "Let games see your controllers") {
                HStack(alignment: .center, spacing: 12) {
                    Toggle("Let games and emulators use my controllers", isOn: $sdlEnabled)
                        .toggleStyle(.switch).labelsHidden()
                    Text(sdlEnabled ? "On. Quit and reopen any game that's already running."
                                    : "Off. Turn it on so games can see your controllers (recommended).")
                        .foregroundStyle(.secondary)
                }
            }
            step(2, "For rumble, start games from NS2 Bridge",
                 "Open **Games**, click **Add game…** and pick the game. Then click **Play with rumble**. If NS2 Bridge offers to install its helper into a game, that's safe: the original is backed up and can be restored.")
            step(3, "Inside the game", "Check the game's own controller settings too: many have their own rumble switch and stick sensitivity.")
            Spacer()
        }
    }

    private var feel: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("slider.horizontal.3", "Make it feel right")
            point("scope", .teal, "Sticks feel off?", "**Calibrate Sticks** takes about 10 seconds: let go, then roll the sticks around the edge.")
            point("waveform", .orange, "Vibration too strong or weak?", "**Haptics** has a strength slider and test buttons.")
            point("power", .red, "Save battery", "Double-click a controller's tag in the menu bar to turn a wireless controller off.")
            point("contextualmenu.and.cursorarrow", .blue, "More options", "Right-click a tag, or a controller at the top of the window, to open its settings.")
            point("person.2", .green, "Change players", "**Players & Profiles** lets you swap who's player 1, 2, 3…")
            Spacer()
        }
    }

    private var mode: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("square.grid.2x2", "Choose your setup")
            Text("You can switch any time, at the bottom of the sidebar or in Setup.").foregroundStyle(.secondary)
            HStack(spacing: 14) {
                modeCard(false, "Basic", "hand.thumbsup",
                         "The essentials: your controllers, calibration, vibration, games, wireless, battery and settings.")
                modeCard(true, "Advanced", "wrench.and.screwdriver",
                         "Everything in Basic, plus button test, motion and gyro for emulators, latency test and diagnostics.")
            }
            Toggle(isOn: $openAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open NS2 Bridge when I log in").font(.headline)
                    Text("Recommended, so controllers work in games right after you start your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.top, 6)
            Spacer()
        }
    }

    // MARK: Pieces

    private func header(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Color.accentColor)
            Text(title).font(.largeTitle.bold())
        }
        .padding(.bottom, 4)
    }

    private func point(_ icon: String, _ color: Color, _ title: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ text: LocalizedStringKey) -> some View {
        step(n, title) { Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }

    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.headline).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    private func tag(_ code: String, player: Int, note: String) -> some View {
        VStack(spacing: 4) {
            Text(code).font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(PlayerColor.ink(player))
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(PlayerColor.of(player)))
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modeCard(_ isAdvanced: Bool, _ title: String, _ icon: String, _ text: String) -> some View {
        let on = advanced == isAdvanced
        return Button { advanced = isAdvanced } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.title2)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                }
                Text(title).font(.title3.bold())
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: on ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
