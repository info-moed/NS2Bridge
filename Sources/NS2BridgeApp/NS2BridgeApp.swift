import AppKit
import Metal
import SceneKit
import simd
import NS2Kit
import SwiftUI

@main
struct NS2BridgeApp: App {
    @State private var model: BridgeModel

    init() {
        // Developer aid: `NS2Bridge --render-drawings <folder>` saves the controller drawings as PNGs, then quits
        // (before any controller or port is touched).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-drawings"), i + 1 < args.count {
            DrawingRenderer.renderAll(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        // `--render-intro <folder>`: the startup animation as frames and an animated GIF.
        if let i = args.firstIndex(of: "--render-intro"), i + 1 < args.count {
            MainActor.assumeIsolated { IntroExporter.render(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        // `--screenshot-tour <folder>`: documentation screenshots of every tab (see ScreenshotTour).
        if let i = args.firstIndex(of: "--screenshot-tour"), i + 1 < args.count {
            ScreenshotTour.folder = URL(fileURLWithPath: args[i + 1])
            ScreenshotTour.prepareDefaults()
        }
        _model = State(initialValue: BridgeModel())
    }

    var body: some Scene {
        Window("NS2 Bridge", id: "main") {
            MainView().environment(model)
        }
        .defaultSize(width: 900, height: 640)
        .defaultLaunchBehavior(.presented)

        // The plain icon only while no controller is connected: then the controller pills
        // (ControllerStatusItems) take its place and carry its commands.
        MenuBarExtra(isInserted: Binding(get: { model.controllers.isEmpty }, set: { _ in })) {
            MenuContent().environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar

struct MenuContent: View {
    @Environment(BridgeModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.controllers.isEmpty {
                StatusRow()
            } else {
                ForEach(model.controllers) { c in
                    HStack(spacing: 8) {
                        PlayerBadge(player: c.player)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.kind.displayName + (c.transport == .bluetooth ? " · Bluetooth" : "")).font(.headline)
                            Text(c.ready ? "\(c.rate) reports/s · \(Int((c.battery * 100).rounded()))%\(c.charging ? " ⚡︎" : "")" : "Setting up…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.canDisconnect(c.id) {
                            Button { model.disconnect(c.id) } label: { Image(systemName: "power") }
                                .help("Turn off to save battery")
                        }
                    }
                }
            }
            Divider()
            Button("Open NS2 Bridge…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Reconnect controllers") {
                for c in model.controllers where c.kind.needsInit { model.select(c.id); model.reconnectSelected() }
            }
            .disabled(!model.controllers.contains { $0.kind.needsInit })
            if let u = model.availableUpdate {
                Button("Update available: NS2 Bridge \(u.version)…") { model.downloadUpdate() }
            }
            Divider()
            Menu("Help") { HelpMenuItems() }.menuStyle(.borderlessButton)
            Divider()
            Button("Quit NS2 Bridge") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 290)
    }
}

// MARK: - Shared bits

/// One color per player slot, used everywhere (badges, menu bar): P1 blue, P2 red, P3 yellow, P4 green…
enum PlayerColor {
    static let all: [Color] = [.blue, .red, .yellow, .green, .purple, .orange, .pink, .teal]
    static func of(_ player: Int) -> Color { all[max(0, player - 1) % all.count] }
    /// Text on the color: dark on the light ones, white on the rest.
    static func ink(_ player: Int) -> Color { [3, 4].contains((max(1, player) - 1) % all.count + 1) ? .black : .white }
}

struct PlayerBadge: View {
    let player: Int
    var body: some View {
        Text("P\(player)").font(.system(size: 11, weight: .heavy, design: .rounded))
            .accessibilityLabel("Player \(player)")
            .foregroundStyle(PlayerColor.ink(player))
            .frame(width: 28, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(PlayerColor.of(player)))
    }
}

/// Menu bar label: one pill per connected controller, in player order, in that player's color
/// (e.g. GC blue = P1, N64 red = P2, PC2 yellow = P3). Rendered to a color image: macOS would otherwise
/// draw menu bar labels in a single color. A controller still setting up is shown faded.
struct MenuBarLabel: View {
    let model: BridgeModel
    @Environment(\.openWindow) private var openWindow

    // The controllers themselves are separate menu bar items (ControllerStatusItems): one pill each.
    var body: some View {
        Image(systemName: model.anyConnected ? "gamecontroller.fill" : "gamecontroller")
            .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Sidebar footer: Basic / Advanced.
struct ModeSwitch: View {
    @Environment(BridgeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $model.advancedMode) { Text("Advanced tools").font(.callout) }
                .toggleStyle(.switch).controlSize(.small)
            Text(model.advancedMode ? "Showing every tab." : "Basic: the everyday tabs.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Double-click: turn off (with confirmation). Right-click: open settings or turn off.
struct ControllerActions: ViewModifier {
    let id: String
    let model: BridgeModel
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.confirmTurnOff(id) })
            .contextMenu {
                Button("Open Settings") { model.showController(id) }
                Button(model.canDisconnect(id) ? "Turn Off…" : "Disconnect…") { model.confirmTurnOff(id) }
            }
    }
}

struct StatusRow: View {
    @Environment(BridgeModel.self) private var model

    var color: Color {
        guard let s = model.selected else { return model.hubError == nil ? .gray : .red }
        return s.ready ? .green : .yellow
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(model.statusText).font(.headline).lineLimit(2)
        }
    }
}

struct BatteryRow: View {
    let battery: Double
    let charging: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: charging ? "battery.100percent.bolt" : "battery.75percent")
            ProgressView(value: battery).frame(width: 80)
            Text("\(Int((battery * 100).rounded()))%\(charging ? " · charging" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Chips across the top of the window: which controller the tools act on.
struct ControllerPicker: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if model.controllers.isEmpty {
                StatusRow()
            }
            ForEach(model.controllers) { c in
                let isSel = c.id == model.selected?.id
                Button { model.select(c.id) } label: {
                    HStack(spacing: 6) {
                        PlayerBadge(player: c.player)
                        Text(c.kind.shortName + (c.transport == .bluetooth ? " (BT)" : "")).font(.callout.bold())
                        Circle().fill(c.ready ? Color.green : Color.yellow).frame(width: 7, height: 7)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isSel ? Color.accentColor.opacity(0.18) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSel ? Color.accentColor : Color.gray.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .modifier(ControllerActions(id: c.id, model: model))
                .help("Tools act on this controller. Double-click to turn it off; right-click for more.")
            }
            Spacer()
            if let i = model.input, model.isConnected {
                BatteryRow(battery: i.battery, charging: i.charging)
            }
        }
    }
}

// MARK: - Window

enum Pane: String, CaseIterable, Identifiable {
    case players = "Players & Profiles"
    case controller = "Controller"
    case calibrate = "Calibrate Sticks"
    case buttons = "Button Test"
    case haptics = "Haptics"
    case motion = "Motion"
    case latency = "Latency Test"
    case battery = "Battery"
    case games = "Games"
    case wireless = "Wireless"
    case diagnostics = "Diagnostics"
    case setup = "Setup"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .players: return "person.2"
        case .controller: return "gamecontroller"
        case .calibrate: return "scope"
        case .buttons: return "checklist"
        case .haptics: return "waveform"
        case .motion: return "gyroscope"
        case .latency: return "stopwatch"
        case .battery: return "battery.75percent"
        case .games: return "play.rectangle.on.rectangle"
        case .wireless: return "antenna.radiowaves.left.and.right"
        case .diagnostics: return "waveform.path.ecg"
        case .setup: return "gearshape"
        }
    }
    /// Shown in Basic mode (everyday use). The rest appear in Advanced mode.
    var isBasic: Bool { [.players, .controller, .calibrate, .haptics, .games, .wireless, .battery, .setup].contains(self) }
    /// Tabs whose tools act on the selected controller.
    var usesSelection: Bool { [.controller, .calibrate, .buttons, .haptics, .motion, .latency, .battery, .diagnostics].contains(self) }
}

/// The intro plays once per launch, even if the window is closed and reopened.
@MainActor private var introShownThisLaunch = false

struct MainView: View {
    @Environment(BridgeModel.self) private var model
    @State private var pane: Pane? = .controller

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases.filter { model.advancedMode || $0.isBasic }, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .safeAreaInset(edge: .bottom) { ModeSwitch().padding(12) }
            .navigationSplitViewColumnWidth(210)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                UpdateBanner()
                ControllerPicker()
                    .padding(.horizontal, 20).padding(.vertical, 10)
                if model.menuBarTagsHidden {
                    Label("NS2 Bridge's controller tags don't fit in your menu bar and are hidden behind the camera notch. Hold ⌘ and drag them to the right, or remove some other menu bar icons.",
                          systemImage: "menubar.rectangle")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                Divider()
                ScrollView {
                    Group {
                        switch pane ?? .controller {
                        case .players: PlayersPane()
                        case .controller: ControllerPane()
                        case .calibrate: CalibratePane()
                        case .buttons: ButtonTestPane()
                        case .haptics: HapticsPane()
                        case .motion: MotionPane()
                        case .latency: LatencyPane()
                        case .battery: BatteryPane()
                        case .games: GamesPane()
                        case .wireless: WirelessPane()
                        case .diagnostics: DiagnosticsPane()
                        case .setup: SetupPane()
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let m = model.message {
                    Divider()
                    HStack {
                        Image(systemName: "info.circle")
                        Text(m)
                        Spacer()
                        Button("Dismiss") { model.message = nil }.buttonStyle(.borderless)
                    }
                    .font(.callout).padding(.horizontal, 20).padding(.vertical, 8)
                }
            }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if let p = model.requestedPane { pane = p; model.requestedPane = nil }   // opened from the menu bar
        }
        .onChange(of: model.advancedMode) { _, advanced in
            if !advanced, let p = pane, !p.isBasic { pane = .controller }
        }
        .overlay {
            if model.introPlaying { IntroAnimation { withAnimation(.easeOut(duration: 0.2)) { model.introPlaying = false } } }
        }
        .onAppear {
            // Once per launch, when the window first appears.
            if !introShownThisLaunch, model.introEnabled, ScreenshotTour.folder == nil,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                model.introPlaying = true
            }
            introShownThisLaunch = true
        }
        .sheet(isPresented: Binding(get: { model.showWelcome && !model.introPlaying }, set: { model.showWelcome = $0 })) {
            WelcomeView().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.whatsNew != nil && !model.showWelcome && !model.introPlaying }, set: { if !$0 { model.whatsNew = nil } })) {
            WhatsNewSheet(notes: model.whatsNew ?? "").environment(model)
        }
        .sheet(isPresented: Binding(get: { model.diagnosticsReport != nil }, set: { if !$0 { model.diagnosticsReport = nil } })) {
            DiagnosticsReportSheet(report: model.diagnosticsReport ?? "").environment(model)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.openURL(BridgeModel.Links.guide((pane ?? .controller).guidePage)) } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help for this tab (opens the user guide)")
            }
        }
        .task { await ScreenshotTour.run(model: model) }
        .onChange(of: model.requestedPane) { _, p in
            if let p { pane = p; model.requestedPane = nil }
        }
    }
}

// MARK: - Drawing snapshots (developer aid)

@MainActor
enum DrawingRenderer {
    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        save(GameCubeDrawing(buttons: [], main: (0, 0), cStick: (0, 0), triggers: [0, 0]), 520, 340, dir, "gamecube-idle")
        save(GameCubeDrawing(buttons: [.a, .z, .up, .l], main: (0.7, 0.7), cStick: (-1, 0), triggers: [1, 0.4]), 520, 340, dir, "gamecube-pressed")
        save(N64Drawing(buttons: [.a, .cUp], stick: (0.5, -0.5)), 520, 340, dir, "n64")
        save(ControllerDrawing(buttons: [.a, .zr], left: (0.5, 0.5), right: (0, 0)), 560, 340, dir, "pro")
        // 3D motion view in known positions (SDL frame): flat on a desk, top edge up 45°, right grip down 30°.
        let poses: [(String, simd_quatd)] = [("flat", simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)),
                                             ("pitch-up-45", simd_quatd(angle: .pi / 4, axis: SIMD3(1, 0, 0))),
                                             ("right-down-30", simd_quatd(angle: -.pi / 6, axis: SIMD3(0, 0, 1)))]
        let scene = MotionScene()
        if let device = MTLCreateSystemDefaultDevice() {
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene.scene
            renderer.pointOfView = scene.camera
            scene.scene.background.contents = NSColor(white: 0.93, alpha: 1)
            for (name, q) in poses {
                scene.update(orientation: q, accel: q.inverse.act(SIMD3(0, 1, 0)))
                let img = renderer.snapshot(atTime: 0, with: CGSize(width: 720, height: 500), antialiasingMode: .multisampling4X)
                if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("motion-\(name).png"))
                }
            }
        }
        for i in 0..<WelcomeContent.pageCount {
            save(WelcomeContent(page: .constant(i), advanced: .constant(false), openAtLogin: .constant(true),
                                sdlEnabled: .constant(true), checkUpdates: .constant(false), connected: [], finish: {}), 620, 520, dir, "welcome-\(i + 1)")
        }
    }

    private static func save<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat, _ dir: URL, _ name: String) {
        for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let view = v.frame(width: w, height: h).padding(10)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

/// Help items, shared by the menu bar menus.
struct HelpMenuItems: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        Button("About NS2 Bridge") { model.showAbout() }
        Button("NS2 Bridge Help") { model.openURL(BridgeModel.Links.site) }
        Button("Troubleshooting") { model.openURL(BridgeModel.Links.site.appendingPathComponent("reference/troubleshooting.html")) }
        Button(model.checkingForUpdates ? "Checking for Updates…" : "Check for Updates…") { model.checkForUpdates(userInitiated: true) }
            .disabled(model.checkingForUpdates)
        Divider()
        Button("Export Diagnostics Report…") { model.exportDiagnosticsFromMenu() }
        Button("Report an Issue…") { model.openURL(BridgeModel.Links.newIssue) }
    }
}

/// A banner across the window when a newer release exists.
struct UpdateBanner: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        if let u = model.availableUpdate {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("NS2 Bridge \(u.version) is available").font(.callout.bold())
                Text("You have \(BridgeModel.appVersion).").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Release Notes and Download") { model.downloadUpdate() }
                Button { model.availableUpdate = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Hide until the next check")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.blue.opacity(0.1))
        }
    }
}

/// After an update: this version's changelog section.
struct WhatsNewSheet: View {
    @Environment(BridgeModel.self) private var model
    let notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's new in NS2 Bridge \(BridgeModel.appVersion)").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(notes.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        let text = line.trimmingCharacters(in: .whitespaces)
                        if text.hasPrefix("### ") {
                            Text(text.dropFirst(4)).font(.headline).padding(.top, 6)
                        } else if !text.isEmpty {
                            Text((try? AttributedString(markdown: String(line), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(String(line)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(4)
            }
            HStack {
                Button("Full Changelog") { model.openURL(BridgeModel.Links.repository.appendingPathComponent("blob/main/CHANGELOG.md")) }
                Spacer()
                Button("Continue") { model.whatsNew = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
    }
}

extension Pane {
    /// The user-guide page for this tab (docs/guide/<page>.md).
    var guidePage: String {
        switch self {
        case .players, .controller: "controllers"
        case .calibrate: "calibration"
        case .buttons: "button-test"
        case .haptics: "haptics"
        case .motion: "motion"
        case .latency: "latency"
        case .battery: "battery"
        case .games: "games"
        case .wireless: "bluetooth"
        case .diagnostics: "diagnostics"
        case .setup: "setup"
        }
    }
}
