import AppKit
import Foundation
import NS2Kit
import Observation
import ServiceManagement
import UserNotifications

struct LifeTestState: Equatable {
    var key: String
    var start: Date
    var withRumble: Bool
}

struct LaunchSession: Equatable {
    var gamePath: String
    var name: String
    var launched = false
    var helperLoaded: Int?        // SDL major version reported by the helper
    var rumbleSeen = false
    var timedOut = false
}

enum TriggerTestStep: Equatable {
    case idle
    case rest(until: Date)
    case press(Int)                  // 0 = L, 1 = R
    case done([TriggerTestResult], saved: Bool)
    case failed(String)
}

enum GyroCalStep: Equatable {
    case idle
    case measuring(until: Date)
    case done(String)
    case failed(String)
}

enum CalStep: Equatable {
    case idle
    case center(remaining: Int)
    case range
    case done(String)
    case failed(String)
}

/// Summary of one connected controller for the UI.
struct ControllerSummary: Identifiable, Equatable {
    let id: String
    let kind: ControllerKind
    let player: Int
    let transport: LatencyMonitor.Link
    let battery: Double
    let charging: Bool
    let rate: Int
    let ready: Bool
    var label: String { "P\(player) · \(kind.shortName)\(transport == .bluetooth ? " · Bluetooth" : "")" }
}

/// App state. Controllers deliver 100–250 reports/s each on the main thread; we keep the newest in
/// ignored storage and publish the *selected* controller to SwiftUI at 60 Hz.
@MainActor
@Observable
final class BridgeModel {
    // Controllers
    var controllers: [ControllerSummary] = []
    /// Which controller the tools (Calibrate, Haptics, Latency, …) act on. nil = Player 1.
    var selectedID: String? { didSet { if oldValue != selectedID { selectionChanged() } } }
    var input: ControllerInput?
    var proState: ControllerState?
    var n64State: N64State?
    var gcState: GCState?
    var raw: [UInt8] = []
    var activity = [Double](repeating: 0, count: 64)
    var rate = 0
    var seen: [String: Set<String>] = [:]
    var trails: [[CGPoint]] = [[], []]
    var calStep: CalStep = .idle
    var profiles: ProfileStore { didSet { save("profiles", profiles); applyProfiles() } }

    // Diagnostics / setup
    var capturing = false
    var captureCount = 0
    var lastCaptureURL: URL?
    var sdlEnabled: Bool { didSet { UserDefaults.standard.set(sdlEnabled, forKey: "sdl.enabled"); applySDL() } }
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Games launched from NS2 Bridge see the controller as an Xbox controller (compatibility default).
    var xboxMode: Bool = UserDefaults.standard.object(forKey: "xbox.mode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(xboxMode, forKey: "xbox.mode"); refreshInstalledGameSettings() }
    }
    var buttonLayout: SDLMapping.Layout = SDLMapping.Layout(rawValue: UserDefaults.standard.string(forKey: "button.layout") ?? "") ?? .positions {
        didSet {
            UserDefaults.standard.set(buttonLayout.rawValue, forKey: "button.layout")
            if sdlEnabled { applySDL() }
            refreshInstalledGameSettings()
        }
    }
    var games: [URL] = (UserDefaults.standard.stringArray(forKey: "games") ?? []).map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(games.map(\.path), forKey: "games") }
    }
    var analyses: [String: GameAnalysis] = BridgeModel.load("games.analysis") ?? [:] {
        didSet { save("games.analysis", analyses) }
    }
    var verifiedGames: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "games.verified") ?? []) {
        didSet { UserDefaults.standard.set(Array(verifiedGames), forKey: "games.verified") }
    }
    var analyzing: Set<String> = []
    var installing: Set<String> = []
    /// Live check for the most recent launch.
    var session: LaunchSession?
    var gameLinkedPID: Int32?
    var gameRumbleEvents = 0
    /// Game path (or app name) → the drivers its SDL chose for Nintendo controllers, most recent run.
    var driverReports: [String: [GameRumbleServer.DriverReport]] = [:]
    var lastGameRumble: GameRumbleServer.Event?
    var gameBridgeError: String?
    var latency = LatencyMonitor.Snapshot()
    var latencyTestEnds: Date?
    var latencyResult: LatencyMonitor.Snapshot?
    var bleState: BLELink.State = .idle
    var bleRate = 0.0
    var bleIntervalMs = 0.0
    var bleJitterMs = 0.0
    /// Bluetooth speed in effect (Fastest can fall back to Fast by itself).
    var bleSpeedInEffect: BluetoothSpeed = .standard
    /// Wanted Bluetooth speed for Switch 2 controllers (Wireless tab).
    var bluetoothSpeed: BluetoothSpeed = UserDefaults.standard.string(forKey: "bluetooth.speed").flatMap(BluetoothSpeed.init(rawValue:)) ?? .fastest {
        didSet { UserDefaults.standard.set(bluetoothSpeed.rawValue, forKey: "bluetooth.speed"); hub.ble.speed = bluetoothSpeed }
    }
    /// Interval the latency test expects over Bluetooth.
    var bluetoothExpectedMs: Double { bleSpeedInEffect == .standard ? bluetoothSpeed.intervalMs : bleSpeedInEffect.intervalMs }
    var testLow = 0.0
    var testHigh = 0.0
    var testLowFreq = Double(HapticLevel.defaultLowFreq)
    var testHighFreq = Double(HapticLevel.defaultHighFreq)
    var hubError: String?
    var message: String?

    // Motion
    enum MotionMode: String, CaseIterable, Identifiable {
        case off, automatic, on
        var id: String { rawValue }
        var title: String { self == .off ? "Off" : self == .automatic ? "Automatic" : "Always on" }
    }
    /// When the Pro sends its motion report (0x05). While it does, SDL's generic backend can't read the Pro
    /// (see ControllerHub.motionEnabled), so Automatic only turns it on while an emulator is listening for
    /// that controller on the DSU server, and off again a few seconds after it stops.
    var motionMode: MotionMode = BridgeModel.initialMotionMode() {
        didSet { UserDefaults.standard.set(motionMode.rawValue, forKey: "motion.mode"); updateMotion() }
    }
    /// Motion is flowing right now (the effective state).
    private(set) var motionEnabled = false
    /// A DSU client is listening for a controller with motion (drives Automatic).
    private(set) var emulatorWantsMotion = false

    static func initialMotionMode(_ d: UserDefaults = .standard) -> MotionMode {
        if let m = d.string(forKey: "motion.mode").flatMap(MotionMode.init(rawValue:)) { return m }
        return d.bool(forKey: "motion.enabled") ? .on : .automatic       // 1.0 had an on/off switch
    }

    private func updateMotion() {
        hub.bluetoothMotion = motionMode != .off                        // games' virtual gamepads (helper)
        let slots = dsu.isRunning ? dsu.listeningSlots() : []
        emulatorWantsMotion = hub.controllers.contains { $0.kind.hasMotion && dsuSlots[$0.player].map(slots.contains) == true }
        let want = motionMode == .on || (motionMode == .automatic && emulatorWantsMotion)
        guard want != motionEnabled else { return }
        motionEnabled = want
        hub.motionEnabled = want
    }
    /// Serve every controller to DSU (Cemuhook) clients on 127.0.0.1:26760.
    var dsuEnabled: Bool = UserDefaults.standard.object(forKey: "dsu.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dsuEnabled, forKey: "dsu.enabled"); applyDSU() }
    }
    var dsuClients = 0
    var dsuError: String?
    var motion: MotionSample?
    /// Tilt of the selected controller from `OrientationFilter` (degrees), for the Motion tab.
    var tilt: (pitch: Double, roll: Double) = (0, 0)
    @ObservationIgnored private(set) lazy var motionScene = MotionScene()
    @ObservationIgnored private var orientationFilter = OrientationFilter()
    var gyroCal: GyroCalStep = .idle
    var triggerTest: TriggerTestStep = .idle
    /// Basic mode shows the everyday tabs; Advanced adds the diagnostic and specialist ones.
    var advancedMode: Bool = BridgeModel.initialAdvancedMode() {
        didSet { UserDefaults.standard.set(advancedMode, forKey: "ui.advanced") }
    }

    /// Saved choice, or for people updating from a version without modes, Advanced: they already know
    /// every tab, and Basic would hide some they used. New installs start in Basic.
    static func initialAdvancedMode(_ d: UserDefaults = .standard) -> Bool {
        if d.object(forKey: "ui.advanced") != nil { return d.bool(forKey: "ui.advanced") }
        let earlierUse = ["profiles", "games", "sdl.enabled", "xbox.mode", "button.layout", "ff.enabled"]
            .contains { d.object(forKey: $0) != nil }
        if earlierUse { d.set(true, forKey: "ui.advanced") }
        return earlierUse
    }
    /// The welcome guide has been completed or skipped once.
    var welcomeDone: Bool = UserDefaults.standard.bool(forKey: "welcome.done") {
        didSet { UserDefaults.standard.set(welcomeDone, forKey: "welcome.done") }
    }
    /// The welcome guide is on screen: on every new installation (also over old settings, which macOS keeps
    /// when an app is deleted), or reopened from Setup.
    var showWelcome = UserDefaults.standard.string(forKey: "welcome.install") != BridgeModel.installationID

    /// This copy of the app: version plus the file identity of the installed bundle. A new install (unzipped or
    /// copied) is a new file, so it gets the welcome guide again; relaunching the same copy doesn't.
    static let installationID: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var st = stat()
        let inode = stat(Bundle.main.bundlePath, &st) == 0 ? "\(st.st_dev)-\(st.st_ino)" : Bundle.main.bundlePath
        return "\(version) \(inode)"
    }()

    func finishWelcome(advanced: Bool, openAtLogin: Bool) {
        advancedMode = advanced
        if openAtLogin != launchAtLogin { setLaunchAtLogin(openAtLogin) }
        welcomeDone = true
        UserDefaults.standard.set(Self.installationID, forKey: "welcome.install")
        showWelcome = false
    }

    // MARK: - Updates

    /// Once a day, ask GitHub whether a newer release exists (Setup; offered in the welcome tour). Off by default:
    /// NS2 Bridge doesn't touch the network unless asked.
    var checkUpdatesAutomatically = UserDefaults.standard.bool(forKey: "updates.auto") {
        didSet {
            UserDefaults.standard.set(checkUpdatesAutomatically, forKey: "updates.auto")
            if checkUpdatesAutomatically { checkForUpdates(userInitiated: false) }
        }
    }
    /// A newer release, once found (shown as a banner and in the menu bar menu).
    var availableUpdate: UpdateCheck.Release?
    var checkingForUpdates = false

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func checkForUpdates(userInitiated: Bool) {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        Task { @MainActor in
            defer { checkingForUpdates = false }
            UserDefaults.standard.set(Date(), forKey: "updates.lastCheck")
            do {
                guard let latest = try await UpdateCheck.fetchLatest() else { throw URLError(.badServerResponse) }
                if UpdateCheck.isNewer(latest.version, than: Self.appVersion) {
                    availableUpdate = latest
                } else if userInitiated {
                    message = "NS2 Bridge \(Self.appVersion) is the latest version."
                }
            } catch {
                if userInitiated { message = "Couldn't check for updates: \(error.localizedDescription)" }
            }
        }
    }

    /// Automatic check when due (at launch and hourly from the watchdog; at most once a day).
    func checkForUpdatesIfDue() {
        guard checkUpdatesAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: "updates.lastCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 24 * 3600 { checkForUpdates(userInitiated: false) }
    }

    func downloadUpdate() {
        guard let u = availableUpdate else { return }
        openURL(u.page)                                         // the release page: notes, download, checksum
    }

    // MARK: - What's new

    /// After an update: this version's changelog section, shown once (after the welcome tour if that's open).
    var whatsNew: String? = BridgeModel.whatsNewForThisLaunch()

    static func whatsNewForThisLaunch() -> String? {
        let d = UserDefaults.standard
        // Versions before 1.1 didn't record themselves: earlier settings mean this launch is an update.
        let previous = d.string(forKey: "app.lastVersion") ?? (d.object(forKey: "welcome.done") != nil ? "1.0" : nil)
        d.set(appVersion, forKey: "app.lastVersion")
        guard let previous, previous != appVersion,
              let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Changelog.section(text, version: appVersion)
    }

    // MARK: - Startup animation

    /// Setup → Startup animation (on by default).
    var introEnabled = UserDefaults.standard.object(forKey: "ui.intro") as? Bool ?? true {
        didSet { UserDefaults.standard.set(introEnabled, forKey: "ui.intro") }
    }
    /// The intro is on screen (the welcome tour waits for it).
    var introPlaying = false

    // MARK: - Demo mode

    /// Two recorded controllers (a Switch 2 Pro and a GameCube controller) replayed as if connected, to explore
    /// NS2 Bridge without hardware. Not saved: Demo mode is always off at launch.
    var demoMode = false {
        didSet {
            guard demoMode != oldValue else { return }
            if demoMode { hub.startDemo(Self.demoClips()) } else { hub.stopDemo() }
        }
    }

    static func demoClips() -> [DemoClip] {
        Bundle.main.resourceURL.map { DemoClip.load(from: $0.appendingPathComponent("Demo")) } ?? []
    }

    // MARK: - Reset

    /// While resetting: nothing is saved on the way out.
    private var resetting = false

    /// Back to a fresh install: the helper comes out of every game it was installed into (original files
    /// restored), the Finder-wide SDL settings, login agent and login item go, every NS2 Bridge setting and
    /// data file is deleted, and NS2 Bridge relaunches with the welcome guide. Game backups are kept if a game
    /// couldn't be restored, so nothing is lost.
    func resetEverything() {
        var failed: [String] = []
        for g in games where GameInstaller.isInstalled(g) {
            do { try GameInstaller.uninstall(g) } catch { failed.append(g.deletingPathExtension().lastPathComponent) }
        }
        sdlEnabled = false                                     // unsets the SDL settings, removes the login agent
        SDLLoginAgent.update(nil)
        if launchAtLogin { setLaunchAtLogin(false) }
        hub.unregisterForceFeedback()
        let fm = FileManager.default
        let support = GameInstaller.supportDir
        for item in (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        where !(item.lastPathComponent == "Backups" && !failed.isEmpty) {
            try? fm.removeItem(at: item)
        }
        if failed.isEmpty { try? fm.removeItem(at: support) }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        if !failed.isEmpty {
            // Remembered across the relaunch so the user can deal with those games.
            UserDefaults.standard.set("Reset done, but the helper couldn't be removed from \(failed.joined(separator: ", ")); their backups are kept in Application Support/NS2Bridge/Backups.", forKey: "reset.message")
        }
        UserDefaults.standard.synchronize()
        resetting = true
        let p = Process()                                      // reopen once this copy has quit
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// The menu bar item with the controller pills didn't fit (hidden behind the camera notch).
    var menuBarTagsHidden = false

    /// Set to switch the main window to a tab (e.g. from the menu bar).
    var requestedPane: Pane?
    /// Opens the main window (captured from SwiftUI, which owns it).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var statusItems: ControllerStatusItems?
    var gyroBias: GyroBias { selectedController?.gyroBias ?? .zero }

    // Battery
    var batteryReading: BatteryReading?
    var batteryRecord: BatteryRecord?
    var chargeAlertEnabled: Bool = UserDefaults.standard.bool(forKey: "battery.alert.enabled") {
        didSet { UserDefaults.standard.set(chargeAlertEnabled, forKey: "battery.alert.enabled"); if chargeAlertEnabled { requestNotificationPermission() } }
    }
    var chargeAlertPercent: Double = UserDefaults.standard.object(forKey: "battery.alert.percent") as? Double ?? 80 {
        didSet { UserDefaults.standard.set(chargeAlertPercent, forKey: "battery.alert.percent") }
    }
    var lifeTest: LifeTestState?
    /// Rumble for SDL games through macOS force feedback (no changes to games).
    var forceFeedbackEnabled: Bool = UserDefaults.standard.object(forKey: "ff.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(forceFeedbackEnabled, forKey: "ff.enabled"); applyForceFeedback() }
    }

    // MARK: Selection helpers

    /// The controller the tools act on: the chosen one, or Player 1.
    var selected: ControllerSummary? {
        controllers.first { $0.id == selectedID } ?? controllers.min { $0.player < $1.player }
    }
    var selectedKind: ControllerKind { selected?.kind ?? .switch2Pro }
    /// A controller is selected and streaming.
    var isConnected: Bool { selected?.ready == true }
    var anyConnected: Bool { !controllers.isEmpty }

    var statusText: String {
        guard let s = selected else {
            if let e = hubError { return "Couldn't start a controller: \(e)" }
            return "No controller — plug in with a USB-C data cable"
        }
        return s.ready ? "\(s.kind.displayName)\(s.transport == .bluetooth ? " · Bluetooth" : "")" : "Setting up \(s.kind.displayName)…"
    }

    /// Active profile for the selected controller's kind.
    var profile: ControllerProfile { profiles.profile(for: selectedKind, device: selectedController?.deviceKey) }

    /// The profile a connected controller uses (its own, or its kind's default).
    func profile(for c: ConnectedController) -> ControllerProfile { profiles.profile(for: c.kind, device: c.deviceKey) }
    func profile(forID id: String) -> ControllerProfile? { hub.controller(id: id).map(profile(for:)) }
    func tag(forID id: String) -> String? { hub.controller(id: id)?.tag }

    /// Point a controller at another profile of its kind (remembered for that controller).
    func assignProfile(_ profileID: UUID, toController id: String) {
        guard let c = hub.controller(id: id), let key = c.deviceKey else { profiles.setActive(profileID); return }
        profiles.assign(profileID, to: key)
    }
    func calibration(_ stick: Int) -> StickCalibration { profile.calibration(stick) }
    /// Calibrated stick value, honoring the controller's gate shape (N64 = octagon).
    func calibrated(_ stick: Int, _ s: Stick) -> (x: Double, y: Double) {
        calibration(stick).apply(s, octagonal: selectedKind.octagonalGate)
    }
    var seenButtons: Set<String> { seen[selected?.id ?? ""] ?? [] }

    var hapticsEnabled: Bool {
        get { profile.hapticsEnabled }
        set { var p = profile; p.hapticsEnabled = newValue; profiles.update(p) }
    }
    var hapticsIntensity: Double {
        get { profile.hapticsIntensity }
        set { var p = profile; p.hapticsIntensity = newValue; profiles.update(p) }
    }
    func setDeadzone(_ v: Double, stick: Int) {
        var p = profile; var c = p.calibration(stick); c.deadzone = v; p.setCalibration(c, stick: stick); profiles.update(p)
    }

    @ObservationIgnored let hub = ControllerHub()
    @ObservationIgnored private var prevRaw: [UInt8] = []
    @ObservationIgnored private var act = [Double](repeating: 0, count: 64)
    @ObservationIgnored private var writer: CaptureWriter?
    @ObservationIgnored private var recorders: [CalibrationRecorder] = [CalibrationRecorder(), CalibrationRecorder()]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private(set) lazy var gameServer = GameRumbleServer()
    @ObservationIgnored private var pendingLaunch: (name: String, at: Date)?
    @ObservationIgnored private var batteryStore: [String: BatteryRecord] = BridgeModel.loadBatteryStore()
    @ObservationIgnored private var alerted: Set<String> = []
    @ObservationIgnored private var lastBatterySave = Date()
    @ObservationIgnored let dsu = DSUServer()
    @ObservationIgnored private var dsuSlots: [Int: Int] = [:]      // player → DSU slot
    @ObservationIgnored private var gyroCalibrator = GyroCalibrator()
    @ObservationIgnored private var triggerAnalyzers: [TriggerAnalyzer] = []
    @ObservationIgnored private var gyroCalID: String?
    @ObservationIgnored private var gyroBiases: [String: GyroBias] = BridgeModel.load("gyro.bias") ?? [:]

    init() {
        sdlEnabled = UserDefaults.standard.bool(forKey: "sdl.enabled")
        var store: ProfileStore = Self.load("profiles") ?? ProfileStore()
        store.ensureDefaults()
        // One-time migration of the single-controller settings from earlier versions.
        if UserDefaults.standard.object(forKey: "cal.left") != nil {
            var p = store.activeProfile(for: .switch2Pro)
            if let l: StickCalibration = Self.load("cal.left") { p.setCalibration(l, stick: 0) }
            if let r: StickCalibration = Self.load("cal.right") { p.setCalibration(r, stick: 1) }
            p.hapticsEnabled = UserDefaults.standard.object(forKey: "haptics.enabled") as? Bool ?? true
            p.hapticsIntensity = UserDefaults.standard.object(forKey: "haptics.intensity") as? Double ?? 1.0
            store.update(p)
            for k in ["cal.left", "cal.right", "haptics.enabled", "haptics.intensity"] { UserDefaults.standard.removeObject(forKey: k) }
        }
        profiles = store

        hub.onChange = { [weak self] in MainActor.assumeIsolated { self?.controllersChanged() } }
        hub.onRawReport = { [weak self] c, r in MainActor.assumeIsolated { self?.ingest(r, from: c) } }
        hub.onError = { [weak self] e in MainActor.assumeIsolated { self?.hubError = e } }
        hub.onBLEState = { [weak self] st in MainActor.assumeIsolated { self?.bleState = st } }
        hub.onBattery = { [weak self] c in MainActor.assumeIsolated { self?.batteryUpdated(c) } }
        checkForUpdatesIfDue()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdatesIfDue() }
        }
        if let m = UserDefaults.standard.string(forKey: "reset.message") {     // from a reset that couldn't restore a game
            message = m
            UserDefaults.standard.removeObject(forKey: "reset.message")
        }
        hub.motionEnabled = false                                      // decided once the DSU server is up
        hub.bluetoothMotion = motionMode != .off
        hub.ble.speed = bluetoothSpeed
        hub.start()
        dsu.onClientsChanged = { [weak self] n in MainActor.assumeIsolated { self?.dsuClients = n } }
        statusItems = ControllerStatusItems(model: self)
        applyDSU()
        applyForceFeedback()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hub.unregisterForceFeedback()      // leave controllers exactly as macOS set them up
                if self?.resetting != true { self?.saveBatteryStore() }
            }
        }

        let hub = self.hub
        gameServer.onRumble = { e in    // runs on the listener queue: no main-thread hop
            hub.gameRumble(productID: e.productID, deviceID: e.deviceID, rank: e.rank, low: e.low, high: e.high, milliseconds: e.durationMs)
        }
        gameServer.onHello = { [weak self] pid, sdl in MainActor.assumeIsolated {
            guard let self else { return }
            self.gameLinkedPID = pid; self.pendingLaunch = nil
            if self.session?.helperLoaded == nil { self.session?.helperLoaded = sdl }
        } }
        gameServer.onDriver = { [weak self] r in MainActor.assumeIsolated { self?.driverReported(r) } }
        gameServer.onEvent = { [weak self] e in MainActor.assumeIsolated {
            guard let self else { return }
            self.gameRumbleEvents += 1; self.lastGameRumble = e
            if var s = self.session, e.low > 0 || e.high > 0 {
                s.rumbleSeen = true; self.session = s
                self.verifiedGames.insert(s.gamePath)
            }
        } }
        do { try gameServer.start() } catch { gameBridgeError = "\(error)" }
        for g in games where analyses[g.path]?.changesControllerDrivers == nil { analyze(g) }   // missing, or from an older version
        if sdlEnabled { applySDL() }
        refreshInstalledGameSettings()          // mappings may have changed with this version

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    // MARK: - Controllers

    private func controllersChanged() {
        controllers = hub.controllers.map {
            ControllerSummary(id: $0.id, kind: $0.kind, player: $0.player, transport: $0.transport,
                              battery: $0.lastInput?.battery ?? 0, charging: $0.lastInput?.charging ?? false,
                              rate: $0.reportsPerSecond, ready: $0.ready)
        }
        statusItems?.update(controllers)
        if let id = selectedID, !controllers.contains(where: { $0.id == id }) { selectedID = nil }
        if !controllers.isEmpty { hubError = nil }
        applyProfiles()
        for c in hub.controllers { c.gyroBias = gyroBiases[c.identityKey] ?? .zero }
        // DSU slots follow player numbers; clear slots nobody holds any more.
        dsuSlots = DSUServer.slots(forPlayers: hub.controllers.map(\.player))
        let held = Set(dsuSlots.values)
        for slot in 0..<4 where !held.contains(slot) { dsu.update(slot: slot, pad: nil) }
    }

    /// Push each kind's active profile (vibration settings) to every connected controller of that kind.
    private func applyProfiles() {
        // A controller seen for the first time (with an identity) gets its own profile.
        var store = profiles
        var created = false
        for c in hub.controllers {
            if let key = c.deviceKey, let tag = c.tag, store.ensureDeviceProfile(device: key, kind: c.kind, tag: tag) { created = true }
        }
        if created { profiles = store; return }                 // didSet calls this again with the new profiles
        for c in hub.controllers {
            let p = profile(for: c)
            c.haptics.enabled = p.hapticsEnabled
            c.haptics.intensity = p.hapticsIntensity
            if c.triggerRanges != p.triggers { c.triggerRanges = p.triggers }
        }
    }

    private func selectionChanged() {
        batteryReading = nil
        batteryRecord = selectedController.flatMap { batteryStore[$0.identityKey] }
        prevRaw = []; act = [Double](repeating: 0, count: 64)
        trails = [[], []]; calStep = .idle; latencyResult = nil; latencyTestEnds = nil
        input = nil; proState = nil; n64State = nil; gcState = nil; raw = []
        orientationFilter = OrientationFilter()
    }

    func select(_ id: String) { selectedID = id }

    /// Bring up the main window on this controller's live view.
    func showController(_ id: String) {
        select(id)
        requestedPane = .controller
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Ask before turning a controller off (double-click or "Turn Off…" in the menu bar or the app).
    func confirmTurnOff(_ id: String) {
        guard let c = controllers.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        let name = "P\(c.player) · \(c.kind.displayName)"
        NSApp.activate(ignoringOtherApps: true)
        if canDisconnect(id) {
            alert.messageText = "Turn off \(name)?"
            alert.informativeText = "It turns off to save its battery. Press a button\(c.kind == .n64 ? "" : " or its sync button") to reconnect."
            alert.addButton(withTitle: "Turn Off")
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: disconnect(id)
            case .alertSecondButtonReturn: showController(id)
            default: break
            }
        } else {
            alert.messageText = "\(name) is connected by USB"
            alert.informativeText = "On USB it runs from the Mac and charges, so it isn't using its battery. Unplug the cable to disconnect it."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Settings")
            if alert.runModal() == .alertSecondButtonReturn { showController(id) }
        }
    }

    func canDisconnect(_ id: String) -> Bool { hub.controller(id: id).map(hub.canDisconnect) ?? false }

    /// Turn a wireless controller off to save its battery.
    func disconnect(_ id: String) {
        guard let c = hub.controller(id: id) else { return }
        hub.disconnect(c)
        message = "\(c.kind.displayName) turned off. Press a button\(c.kind == .n64 ? "" : " (or its sync button)") to reconnect."
    }

    func makePlayerOne(_ id: String) {
        guard let c = hub.controller(id: id) else { return }
        hub.assign(c, toPlayer: 1)
    }

    func assign(_ id: String, toPlayer p: Int) {
        guard let c = hub.controller(id: id) else { return }
        hub.assign(c, toPlayer: p)
    }

    private var selectedController: ConnectedController? { hub.controller(id: selected?.id) }

    // MARK: - Report flow

    private func ingest(_ r: [UInt8], from c: ConnectedController) {
        if c.kind == .gameCube, c.id == selected?.id, let gc = GCState(report: r) { feedTriggerTest(gc) }
        if let i = c.lastInput { seen[c.id, default: []].formUnion(i.pressed) }
        if dsuEnabled, dsu.isRunning, let slot = dsuSlots[c.player], let i = c.lastInput {
            dsu.update(slot: slot, pad: dsuPad(c, i))
        }
        // Games can't see Switch 2 controllers over Bluetooth: the helper inside each running game presents
        // them as SDL gamepads (the N64 uses classic Bluetooth, which macOS shows to games itself).
        if c.transport == .bluetooth, c.kind != .n64, let i = c.lastInput, gameServer.helperCount > 0 {
            var pad = dsuPad(c, i)
            if motionMode == .off { pad.motion = nil }
            gameServer.sendVirtual([VirtualGamepad(slot: UInt8(c.player), kind: c.kind, pad: pad, layout: buttonLayout)])
        }
        if c.id == selected?.id, r.first == Report05.id, let m = c.lastInput?.motion { orientationFilter.update(m) }
        if case .measuring = gyroCal, c.id == gyroCalID, r.first == Report05.id, let m = c.lastInput?.motion {
            gyroCalibrator.add(m)
        }
        guard c.id == selected?.id else { return }
        for i in 0..<min(64, r.count) {
            let changed = i < prevRaw.count && prevRaw[i] != r[i]
            act[i] = changed ? min(1, act[i] + 0.15) : act[i] * 0.985
        }
        prevRaw = r
        if let writer { writer.append(r); captureCount = writer.count }
    }

    private func publish() {
        tickCount += 1
        if tickCount % 30 == 0 { updateMotion() }                      // twice a second: DSU listeners come and go
        bleRate = hub.ble.measuredRate
        bleIntervalMs = hub.ble.measuredIntervalMs
        bleJitterMs = hub.ble.jitterMs
        bleSpeedInEffect = hub.ble.effectiveSpeed
        guard let c = selectedController else {
            if input != nil { input = nil; proState = nil; n64State = nil; gcState = nil }
            return
        }
        rate = c.reportsPerSecond
        if tickCount % 15 == 0 {
            latency = c.latency.snapshot()
            if let end = latencyTestEnds, Date() >= end { latencyResult = latency; latencyTestEnds = nil }
        }
        if case .measuring(let until) = gyroCal, Date() >= until { finishGyroCalibration() }
        guard let i = c.lastInput else { return }
        input = i
        motion = i.motion
        if let m = i.motion {
            motionScene.update(orientation: orientationFilter.orientation, accel: m.accel)
            tilt = orientationFilter.tilt
        }
        raw = c.lastRaw
        activity = act
        proState = c.kind == .switch2Pro ? ControllerState(report: c.lastRaw) : nil
        n64State = c.kind == .n64 ? N64State(report: c.lastRaw) : nil
        gcState = c.kind == .gameCube ? GCState(report: c.lastRaw) : nil

        for (n, stick) in i.sticks.enumerated() where n < 2 {
            let v = calibrated(n, stick)
            trails[n].append(CGPoint(x: v.x, y: v.y))
            if trails[n].count > 240 { trails[n].removeFirst() }
        }
        switch calStep {
        case .center(let n):
            for (k, s) in i.sticks.enumerated() where k < recorders.count { recorders[k].addCenter(s) }
            calStep = n > 1 ? .center(remaining: n - 1) : .range
        case .range:
            for (k, s) in i.sticks.enumerated() where k < recorders.count { recorders[k].addRange(s) }
        default: break
        }
    }

    // MARK: - Calibration

    func startCalibration() {
        recorders = [CalibrationRecorder(), CalibrationRecorder()]
        trails = [[], []]
        calStep = .center(remaining: 60)   // 1 s at 60 Hz
    }

    /// Per stick: enough travel recorded?
    var rangeProgress: [Bool] { (0..<selectedKind.stickNames.count).map { recorders[$0].rangeIsGood } }

    func finishCalibration() {
        let n = selectedKind.stickNames.count
        let results = (0..<n).map { recorders[$0].result(deadzone: calibration($0).deadzone) }
        guard results.allSatisfy({ $0 != nil }) else {
            calStep = .failed("Not enough travel recorded — roll each stick all the way around the edge a few times, then press Finish.")
            return
        }
        var p = profile
        for (k, c) in results.enumerated() { p.setCalibration(c!, stick: k) }
        profiles.update(p)
        refreshInstalledGameSettings()                    // games get the new stick range too
        let centers = results.enumerated().map { String(format: "%@ center %.0f, %.0f", selectedKind.stickNames[$0.offset], $0.element!.x.center, $0.element!.y.center) }
        calStep = .done("Saved to profile “\(p.name)”. " + centers.joined(separator: " · "))
    }

    func cancelCalibration() { calStep = .idle }

    // MARK: - Trigger test (GameCube analog L/R)

    /// Untouched for 2 s, then L slowly to the click and back, then R. Every report (~252/s) is used.
    func startTriggerTest() {
        guard selectedKind == .gameCube else { return }
        triggerAnalyzers = [TriggerAnalyzer(name: "L"), TriggerAnalyzer(name: "R")]
        triggerTest = .rest(until: Date().addingTimeInterval(2))
    }

    func cancelTriggerTest() { triggerTest = .idle }

    private func feedTriggerTest(_ gc: GCState) {
        let raw = [gc.leftTrigger, gc.rightTrigger]
        let clicks = [gc.buttons.contains(.l), gc.buttons.contains(.r)]
        switch triggerTest {
        case .rest(let until):
            for i in 0..<2 { triggerAnalyzers[i].addRest(raw[i]) }
            if Date() >= until {
                triggerTest = triggerAnalyzers.allSatisfy(\.hasRest) ? .press(0) : .failed("No reports arrived from the controller.")
            }
        case .press(let i):
            triggerAnalyzers[i].addPress(raw[i], click: clicks[i])
            // Done with this trigger once it has clicked and come back to rest.
            if triggerAnalyzers[i].clicked, Int(raw[i]) <= Int(triggerAnalyzers[i].restMedian) + 15 {
                if i == 0 { triggerTest = .press(1) } else { finishTriggerTest() }
            }
        default:
            break
        }
    }

    private func finishTriggerTest() {
        let results = triggerAnalyzers.map { $0.result() }
        save("trigger.test.last", results)                // readable with `defaults read local.ns2bridge trigger.test.last`
        let pass = results.allSatisfy(\.passed)
        if pass { saveTriggerRanges(results) }
        triggerTest = .done(results, saved: pass)
    }

    /// Store the measured travel in the profile: a full press (the click) then reads exactly 100%.
    func saveTriggerRanges(_ results: [TriggerTestResult]) {
        var p = profile
        p.triggers = results.map(\.range)
        profiles.update(p)
        if case .done(let r, _) = triggerTest { triggerTest = .done(r, saved: true) }
    }

    func resetTriggerRanges() {
        var p = profile
        p.triggers = nil
        profiles.update(p)
        triggerTest = .idle
    }

    func resetCalibration() {
        var p = profile
        for k in 0..<selectedKind.stickNames.count {
            var d = selectedKind.defaultCalibration; d.deadzone = p.calibration(k).deadzone
            p.setCalibration(d, stick: k)
        }
        profiles.update(p)
        refreshInstalledGameSettings()
        calStep = .idle
    }

    private func applyForceFeedback() {
        let plugin = Bundle.main.builtInPlugInsURL?.appendingPathComponent("NS2FF.plugin")
        let exists = plugin.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        hub.forceFeedbackPlugin = (forceFeedbackEnabled && exists) ? plugin : nil
    }

    // MARK: - Battery

    var selectedIdentity: String? { selectedController?.identityKey }
    var selectedFirmware: String? { selectedController?.firmware }
    var selectedMAC: String? { selectedController?.mac }

    private func batteryUpdated(_ c: ConnectedController) {
        guard let r = c.battery else { return }
        let key = c.identityKey
        var rec = batteryStore[key] ?? BatteryRecord(key: key, kind: c.kind)
        rec.add(r)
        if var run = rec.calibration, run.stage != .done {
            run.add(r)
            if run.stage == .done {
                if let curve = run.curve() {
                    rec.curve = curve
                    message = "Battery calibration finished for \(c.kind.displayName): its own voltage curve is now in use."
                } else {
                    message = "Battery calibration ended too early to build a curve (needs at least 10 minutes on battery)."
                }
            }
            rec.calibration = run
        }
        batteryStore[key] = rec

        // Charge alert: controllers can't be told to stop charging, so tell the user to unplug.
        let pct = rec.percent(r)
        if r.charging {
            if chargeAlertEnabled, pct >= chargeAlertPercent, !alerted.contains(key) {
                alerted.insert(key)
                fireChargeAlert(c, percent: pct)
            }
        } else {
            alerted.remove(key)
        }

        if c.id == selected?.id { batteryReading = r; batteryRecord = rec }
        if Date().timeIntervalSince(lastBatterySave) > 60 { saveBatteryStore() }
    }

    private func fireChargeAlert(_ c: ConnectedController, percent: Double) {
        let title = "Unplug your \(c.kind.displayName)"
        let body = String(format: "P%d is at %.0f%% — unplug it now to keep the battery healthy.", c.player, percent)
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "charge-\(c.identityKey)", content: content, trigger: nil))
        NSSound(named: "Glass")?.play()
        c.haptics.play(.heartbeat)
        message = title + ". " + body
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func refreshBatteryNow() { if let c = selectedController { hub.requestBattery(c) } }

    func startBatteryCalibration() {
        guard let key = selectedIdentity, let kind = selected?.kind else { return }
        var rec = batteryStore[key] ?? BatteryRecord(key: key, kind: kind)
        rec.calibration = CalibrationRun()
        batteryStore[key] = rec; batteryRecord = rec; saveBatteryStore()
    }

    func finishBatteryCalibrationNow() {
        guard let key = selectedIdentity, var rec = batteryStore[key], var run = rec.calibration else { return }
        run.stage = .done
        if let curve = run.curve() { rec.curve = curve; message = "Calibration saved from \(Int(run.dischargeMinutes)) minutes of data." }
        else { message = "Not enough data yet: it needs at least 10 minutes of running on battery." }
        rec.calibration = run
        batteryStore[key] = rec; batteryRecord = rec; saveBatteryStore()
    }

    func cancelBatteryCalibration() {
        guard let key = selectedIdentity, var rec = batteryStore[key] else { return }
        rec.calibration = nil
        batteryStore[key] = rec; batteryRecord = rec; saveBatteryStore()
    }

    func resetBatteryCurve() {
        guard let key = selectedIdentity, var rec = batteryStore[key] else { return }
        rec.curve = .typicalLiPo
        batteryStore[key] = rec; batteryRecord = rec; saveBatteryStore()
    }

    func startLifeTest(withRumble: Bool) {
        guard let key = selectedIdentity else { return }
        lifeTest = LifeTestState(key: key, start: Date(), withRumble: withRumble)
        if withRumble { selectedController?.haptics.setContinuous(left: HapticLevel(0.3), right: HapticLevel(0.3)) }
    }

    func stopLifeTest() {
        guard let t = lifeTest else { return }
        lifeTest = nil
        if t.withRumble { for c in hub.controllers where c.identityKey == t.key { c.haptics.setContinuous(left: .off, right: .off) } }
        guard var rec = batteryStore[t.key] else { return }
        let window = Date().timeIntervalSince(t.start)
        guard window >= 5 * 60, let rate = rec.ratePerHour(window: window), rate < 0 else {
            message = "Life test needs at least 5 minutes on battery (not charging) to measure a drain rate."
            return
        }
        let drain = -rate
        rec.lifeTests.append(LifeTestResult(date: Date(), minutes: window / 60, drainPerHour: drain,
                                            withRumble: t.withRumble, projectedHoursFull: 100 / drain))
        batteryStore[t.key] = rec; batteryRecord = rec; saveBatteryStore()
        message = String(format: "Life test: %.1f %%/hour → about %.1f hours from a full charge.", drain, 100 / drain)
    }

    private static var batteryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NS2Bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("battery.json")
    }

    private static func loadBatteryStore() -> [String: BatteryRecord] {
        guard let d = try? Data(contentsOf: batteryURL) else { return [:] }
        return (try? JSONDecoder().decode([String: BatteryRecord].self, from: d)) ?? [:]
    }

    func saveBatteryStore() {
        lastBatterySave = Date()
        if let d = try? JSONEncoder().encode(batteryStore) { try? d.write(to: Self.batteryURL, options: .atomic) }
    }

    // MARK: - Profiles

    func setActiveProfile(_ id: UUID) { profiles.setActive(id) }
    func addProfile(kind: ControllerKind, name: String) { profiles.add(name: name.isEmpty ? "New profile" : name, kind: kind) }
    func deleteProfile(_ id: UUID) { profiles.delete(id) }
    func renameProfile(_ id: UUID, to name: String) {
        guard var p = profiles.profiles.first(where: { $0.id == id }), !name.isEmpty else { return }
        p.name = name; profiles.update(p)
    }

    // MARK: - Diagnostics

    func toggleCapture() {
        if let writer {
            writer.close(); self.writer = nil; capturing = false
            message = "Saved \(captureCount) reports."
            return
        }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/ns2-capture-\(f.string(from: Date())).ns2cap")
        do {
            writer = try CaptureWriter(url: url)
            lastCaptureURL = url; capturing = true; captureCount = 0; message = nil
        } catch {
            message = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func revealCapture() {
        if let u = lastCaptureURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    func copySDLMapping() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SDLMapping.allLines(layout: buttonLayout), forType: .string)
        message = "SDL mapping copied to the clipboard."
    }

    func resetButtonTest() { if let id = selected?.id { seen[id] = [] } }

    // MARK: - Haptics

    func play(_ e: HapticEffect) { selectedController?.haptics.play(e) }

    /// Live test slider: continuous rumble while amplitude > 0.
    func updateTestRumble() {
        let l = HapticLevel(low: testLow, high: testHigh, lowFreq: UInt16(testLowFreq), highFreq: UInt16(testHighFreq))
        selectedController?.haptics.setContinuous(left: l, right: l)
    }

    func resetPitch() {
        testLowFreq = Double(HapticLevel.defaultLowFreq); testHighFreq = Double(HapticLevel.defaultHighFreq)
        updateTestRumble()
    }

    func stopHaptics() {
        testLow = 0; testHigh = 0
        for c in hub.controllers { c.haptics.stopAll() }
    }

    // MARK: - Latency

    func runLatencyTest() {
        selectedController?.latency.reset()
        latencyResult = nil
        latencyTestEnds = Date().addingTimeInterval(10)
    }

    func copyLatencyReport(_ s: LatencyMonitor.Snapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latencyText(s), forType: .string)
        message = "Latency results copied to the clipboard."
    }

    func latencyText(_ s: LatencyMonitor.Snapshot) -> String {
        let e = LatencyMonitor.expectation(for: s.link, kind: selectedKind, bluetoothIntervalMs: bluetoothExpectedMs)
        return String(format: """
        NS2 Bridge latency test — \(selectedKind.displayName) — %@
        Report rate: %.1f Hz (expected %.0f Hz)
        Interval: mean %.2f ms, median %.2f ms, 99th %.2f ms, max %.2f ms (expected %.1f ms)
        Jitter: ±%.2f ms
        Dropped reports: %d of %d (%.2f%%)
        Host (macOS) delay: %@
        Added input latency from the link: ~%.1f ms average, ~%.1f ms worst
        """, s.link.rawValue, s.rateHz, 1000 / e.intervalMs, s.meanMs, s.p50Ms, s.p99Ms, s.maxMs, e.intervalMs,
             s.jitterMs, s.dropped, s.received + s.dropped, s.dropPercent,
             s.hostDelayMs.map { String(format: "%.2f ms", $0) } ?? "n/a", s.addedAverageMs, s.addedWorstMs)
    }

    // MARK: - Diagnostics report

    /// The report on screen (Diagnostics tab or Help menu), nil when closed.
    var diagnosticsReport: String?

    func showDiagnosticsReport() { diagnosticsReport = makeDiagnosticsReport() }

    func copyDiagnosticsReport(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Diagnostics report copied."
    }

    func saveDiagnosticsReport(_ text: String) {
        let panel = NSSavePanel()
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "NS2 Bridge diagnostics \(day).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); message = "Diagnostics report saved." }
        catch { message = "Couldn't save: \(error.localizedDescription)" }
    }

    /// Project links (help, issues, releases).
    enum Links {
        static let site = URL(string: "https://info-moed.github.io/NS2Bridge/")!
        static let newIssue = URL(string: "https://github.com/info-moed/NS2Bridge/issues/new/choose")!
        static let releases = URL(string: "https://github.com/info-moed/NS2Bridge/releases")!
        static let repository = URL(string: "https://github.com/info-moed/NS2Bridge")!
        static func guide(_ page: String) -> URL { site.appendingPathComponent("guide/\(page).html") }
    }

    func openURL(_ url: URL) { NSWorkspace.shared.open(url) }

    /// From the menu bar: open the window and show the diagnostics report there.
    func exportDiagnosticsFromMenu() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        showDiagnosticsReport()
    }

    /// The standard About panel, with the project's links, license and the non-affiliation notice.
    func showAbout() {
        let credits = NSMutableAttributedString(string: "Switch 2 Pro, NSO GameCube and NSO N64 controllers on macOS.\n\n",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        for (title, url) in [("Website and documentation", Links.site), ("Source code (MIT License)", Links.repository),
                             ("Third-party notices", Links.repository.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"))] {
            credits.append(NSAttributedString(string: title + "\n", attributes: [.link: url, .font: NSFont.systemFont(ofSize: 11)]))
        }
        credits.append(NSAttributedString(string: "\nUnofficial: not affiliated with or endorsed by Nintendo, Microsoft or Apple.",
                                          attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Everything useful for a bug report, scrubbed of personal data (`Diagnostics.scrub`): versions, Mac,
    /// settings, controllers, Bluetooth, latency, games, and this app's recent log. Shown before it's saved.
    func makeDiagnosticsReport() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let helper = Bundle.main.url(forResource: "ns2rumble", withExtension: "dylib").map(GameInstaller.helperVersion) ?? 0
        let on = { (b: Bool) in b ? "on" : "off" }
        var lines = ["# NS2 Bridge diagnostics report", ""]
        let utc = ISO8601DateFormatter()
        lines += ["Generated \(utc.string(from: Date())) (UTC)", "", "## System", ""]
        lines.append("- NS2 Bridge \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · helper v\(helper)")
        lines.append("- \(ProcessInfo.processInfo.operatingSystemVersionString) · \(Diagnostics.macModel)")
        lines += ["", "## Settings", ""]
        lines.append("- Motion \(motionMode.rawValue) · DSU \(on(dsuEnabled))\(dsuError.map { " (error: \($0))" } ?? "") · \(dsuClients) DSU client(s)")
        lines.append("- SDL settings \(on(sdlEnabled)) · force feedback \(on(forceFeedbackEnabled)) · Xbox mode \(on(xboxMode)) · layout \(buttonLayout.rawValue)")
        lines.append("- Bluetooth speed \(bluetoothSpeed.rawValue) (in effect: \(bleSpeedInEffect.rawValue)) · advanced \(on(advancedMode)) · demo \(on(demoMode))")
        lines += ["", "## Controllers", ""]
        if hub.controllers.isEmpty { lines.append("- none connected") }
        for c in hub.controllers {
            let i = c.lastInput
            lines.append("- P\(c.player) \(c.kind.displayName) · \(c.transport.rawValue)\(c.isDemo ? " (demo)" : "") · \(c.reportsPerSecond) reports/s · battery \(i.map { "\(Int($0.battery * 100))%" } ?? "?")\(i?.charging == true ? " charging" : "") · profile “\(profile(for: c).name)”\(c.ready ? "" : " · not ready")")
        }
        lines += ["", "## Bluetooth", ""]
        lines.append("- \(String(describing: bleState)) · \(String(format: "%.0f", bleRate)) reports/s · interval \(String(format: "%.1f", bleIntervalMs)) ms ± \(String(format: "%.1f", bleJitterMs))")
        if let c = selectedController {
            lines += ["", "## Latency (\(c.label), last 1000 reports)", "", "```", latencyText(c.latency.snapshot()), "```"]
        }
        lines += ["", "## Games", ""]
        if games.isEmpty { lines.append("- none added") }
        for g in games {
            let a = analyses[g.path]
            let installed = GameInstaller.isInstalled(g)
            let drivers = (driverReports[g.path] ?? []).map { r in
                "\(ControllerKind(productID: r.productID)?.shortName ?? String(format: "%04X", r.productID)): \(r.isVirtual ? "virtual" : r.usesSDLDriver ? "SDL HIDAPI" : "generic")"
            }
            lines.append("- \(g.deletingPathExtension().lastPathComponent) · \(a.map { "\($0.verdict.rawValue), \($0.engine.rawValue)" } ?? "not analyzed") · helper \(installed ? "installed" : "at launch")\(drivers.isEmpty ? "" : " · last run: " + drivers.joined(separator: ", "))")
        }
        lines += ["", "## Log (last 15 minutes, NS2 Bridge only)", "", "```"] + Diagnostics.recentLog() + ["```", ""]
        return Diagnostics.scrub(lines.joined(separator: "\n"))
    }

    // MARK: - Motion

    private func applyDSU() {
        if dsuEnabled {
            do { try dsu.start(); dsuError = nil } catch { dsuError = "\(error)" }
            // Serve whatever is connected right away (clients see controllers before the next report).
            for c in hub.controllers {
                if let slot = dsuSlots[c.player], let i = c.lastInput { dsu.update(slot: slot, pad: dsuPad(c, i)) }
            }
        } else {
            dsu.stop()
            dsuError = nil
        }
    }

    /// Hold the controller still: averages the gyro for 3 s and stores the offset for this controller.
    func startGyroCalibration() {
        guard let c = selectedController, c.kind.hasMotion, motionEnabled else { return }
        gyroCalibrator = GyroCalibrator()
        gyroCalID = c.id
        gyroCal = .measuring(until: Date().addingTimeInterval(3))
    }

    private func finishGyroCalibration() {
        defer { gyroCalID = nil }
        guard let c = hub.controller(id: gyroCalID) else { gyroCal = .failed("The controller disconnected."); return }
        guard let residual = gyroCalibrator.result() else {
            gyroCal = .failed(gyroCalibrator.count < 100
                ? "No motion data arrived (\(gyroCalibrator.count) samples). Is motion on and the controller streaming?"
                : "The controller moved. Put it down on a table and try again.")
            return
        }
        // Readings already had the old offset removed, so add what's left to it.
        let b = GyroBias(x: c.gyroBias.x + residual.x, y: c.gyroBias.y + residual.y, z: c.gyroBias.z + residual.z)
        c.gyroBias = b
        gyroBiases[c.identityKey] = b
        save("gyro.bias", gyroBiases)
        gyroCal = .done(String(format: "Offset %+.2f, %+.2f, %+.2f °/s (%d samples).", b.x, b.y, b.z, gyroCalibrator.count))
    }

    /// Re-level the 3D view to the accelerometer and face it forward (turning drifts without a compass).
    func resetOrientation() { orientationFilter.reset(accel: motion?.accel) }

    func resetGyroCalibration() {
        guard let c = selectedController else { return }
        c.gyroBias = .zero
        gyroBiases[c.identityKey] = nil
        save("gyro.bias", gyroBiases)
        gyroCal = .idle
    }

    /// A controller as a DualShock for DSU clients. Face buttons go by position (bottom = cross).
    private func dsuPad(_ c: ConnectedController, _ i: ControllerInput) -> DSUServer.Pad {
        var p = DSUServer.Pad()
        let has = { (n: String) in i.pressed.contains(n) }
        let profile = self.profile(for: c)
        func stick(_ n: Int) -> SIMD2<Double> {
            guard n < i.sticks.count else { return .zero }
            let v = profile.calibration(n).apply(i.sticks[n], octagonal: c.kind.octagonalGate)
            return SIMD2(v.x, v.y)
        }
        p.bluetooth = c.transport == .bluetooth
        let macBytes = c.mac?.split(separator: ":").compactMap { UInt8($0, radix: 16) } ?? []
        p.mac = macBytes.count == 6 ? macBytes
            : [0x02, 0x4E, 0x53, UInt8(ControllerKind.allCases.firstIndex(of: c.kind) ?? 0), 0x00, UInt8(c.player)]
        p.battery = i.charging ? 0xEE : i.battery > 0.9 ? 0x05 : i.battery > 0.6 ? 0x04 : i.battery > 0.3 ? 0x03 : i.battery > 0.1 ? 0x02 : 0x01
        p.dpadUp = has("↑"); p.dpadDown = has("↓"); p.dpadLeft = has("←"); p.dpadRight = has("→")
        p.home = has("HOME"); p.touch = has("CAPTURE")
        p.leftStick = stick(0)
        switch c.kind {
        case .switch2Pro:
            p.south = has("B"); p.east = has("A"); p.west = has("Y"); p.north = has("X")
            p.l1 = has("L"); p.r1 = has("R"); p.l2 = has("ZL"); p.r2 = has("ZR")
            p.l3 = has("LS"); p.r3 = has("RS"); p.share = has("−"); p.options = has("+")
            p.rightStick = stick(1)
            p.hasMotion = motionMode != .off              // advertise it, so emulators subscribe (Automatic)
            p.motion = i.motion
        case .n64:
            p.south = has("A"); p.west = has("B")
            p.l1 = has("L"); p.r1 = has("R"); p.l2 = has("Z"); p.r2 = has("ZR"); p.options = has("START")
            p.rightStick = SIMD2((has("C→") ? 1 : 0) - (has("C←") ? 1 : 0), (has("C↑") ? 1 : 0) - (has("C↓") ? 1 : 0))
        case .gameCube:
            p.south = has("A"); p.west = has("B"); p.east = has("X"); p.north = has("Y")
            p.l1 = has("ZL"); p.r1 = has("Z"); p.l2 = has("L"); p.r2 = has("R")
            if i.triggers.count >= 2 { p.l2Analog = i.triggers[0]; p.r2Analog = i.triggers[1] }
            p.options = has("START"); p.share = has("C")
            p.rightStick = stick(1)
        }
        return p
    }

    // MARK: - Wireless

    func connectWireless() { hub.ble.connect() }
    func disconnectWireless() { hub.ble.disconnect() }
    func reconnectSelected() { if let c = selectedController { hub.reinitialize(c) } }

    // MARK: - Games

    func addGame() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose SDL games or emulators to launch with controller rumble"
        guard panel.runModal() == .OK else { return }
        for u in panel.urls where !games.contains(u) {
            games.append(u)
            analyze(u)
        }
    }

    func removeGame(_ url: URL) {
        games.removeAll { $0 == url }
        analyses[url.path] = nil
    }

    func analyze(_ url: URL) {
        analyzing.insert(url.path)
        Task.detached(priority: .userInitiated) {
            let a = GameAnalyzer.analyze(url)
            await MainActor.run {
                self.analyses[url.path] = a
                self.analyzing.remove(url.path)
                self.refreshInstalledGameSettings()          // the engine decides the N64 mapping
            }
        }
    }

    // Helper installed *into* the game (fallback for games whose signing blocks launch-time helpers).

    func isHelperInstalled(_ url: URL) -> Bool { GameInstaller.isInstalled(url) }
    func helperNeedsUpdate(_ url: URL) -> Bool {
        guard let helper = Bundle.main.url(forResource: "ns2rumble", withExtension: "dylib") else { return false }
        return GameInstaller.helperNeedsUpdate(url, helper: helper)
    }

    /// Settings the helper applies inside a game (SDL backend, mappings, Xbox mode).
    func gameSettings(for url: URL) -> [String: String] {
        // Some games (BattleShip) switch SDL's HIDAPI drivers off with SDL_SetHint, e.g. to leave adapters
        // like Raphnet's to their own code. Without its HIDAPI driver the N64 falls back to IOKit, which
        // misreads it (phantom presses). Each SDL HIDAPI driver checks its own hint before the master one,
        // so enabling only the N64 ("Nintendo Classic") driver keeps the game's choice for everything else.
        var s = ["SDL_JOYSTICK_MFI": "0", "SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC": "1",
                 "SDL_GAMECONTROLLERCONFIG": gameControllerConfig(for: url)]
        if xboxMode { s["NS2_XBOX_MODE"] = "1" }
        // Stick range for controllers SDL reads through IOKit: the helper rescales so full tilt = 100%.
        for kind in [ControllerKind.switch2Pro, .gameCube] {
            // Games can't tell which of two identical controllers they're reading here, so use the
            // lowest-numbered player's own profile, or the kind's default if none is connected.
            let c = hub.controllers.filter { $0.kind == kind }.min { $0.player < $1.player }
            let p = c.map(profile(for:)) ?? profiles.activeProfile(for: kind)
            s[GameStickCalibration.envKey(productID: kind.productID)] = GameStickCalibration.envValue(p.sticks)
        }
        if analyses[url.path]?.n64DriverInSDL == false {
            s["SDL_GAMECONTROLLER_IGNORE_DEVICES"] = String(format: "0x%04X/0x%04X", NS2Device.vendorID, ClassicDevice.n64)
        }
        return s
    }

    /// Games with the helper installed read their settings file at start-up, however they're launched.
    /// Rewrite those files whenever a setting they contain changes, so a Finder launch never runs stale.
    func refreshInstalledGameSettings() {
        for url in games where isHelperInstalled(url) {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            try? GameInstaller.writeSettings(gameSettings(for: url), bundleID: id)
        }
    }

    func installHelper(_ url: URL) {
        guard let a = analyses[url.path],
              let helper = Bundle.main.url(forResource: "ns2rumble", withExtension: "dylib") else {
            message = "Rumble helper missing from the app bundle: rebuild with scripts/build-app.sh."
            return
        }
        if let id = Bundle(url: url)?.bundleIdentifier, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            message = "Quit \(url.deletingPathExtension().lastPathComponent) first, then install."
            return
        }
        installing.insert(url.path)
        let settings = gameSettings(for: url)
        Task.detached(priority: .userInitiated) {
            let result = Result { try GameInstaller.install(url, helper: helper, settings: settings,
                                                            hardened: a.hardenedRuntime,
                                                            libraryValidationDisabled: a.libraryValidationDisabled) }
            await MainActor.run {
                self.installing.remove(url.path)
                switch result {
                case .success: self.message = "Rumble helper installed into \(url.deletingPathExtension().lastPathComponent). Launch it any way you like; rumble works."
                case .failure(let e): self.message = "\(e)"
                }
            }
        }
    }

    func uninstallHelper(_ url: URL) {
        do {
            try GameInstaller.uninstall(url)
            message = "Removed the helper from \(url.deletingPathExtension().lastPathComponent); the original files are back."
        } catch {
            message = "\(error)"
        }
    }

    /// Move an old "rumble-ready copy" (NS2 Bridge 0.1) to the Trash. Recoverable from the Trash.
    func trashLegacyCopy(_ url: URL) {
        guard let copy = GameAnalyzer.legacyCopy(of: url) else { return }
        NSWorkspace.shared.recycle([copy]) { _, error in
            DispatchQueue.main.async {
                self.message = error.map { "Couldn't move it to the Trash: \($0.localizedDescription)" } ?? "Old copy moved to the Trash."
            }
        }
    }

    /// Remember which driver a running game's SDL gave each Nintendo controller; warn about the N64 on IOKit.
    private func driverReported(_ r: GameRumbleServer.DriverReport) {
        let app = NSRunningApplication(processIdentifier: r.pid)
        let key = app?.bundleURL.flatMap { u in games.first { $0.standardizedFileURL == u.standardizedFileURL }?.path }
            ?? app?.localizedName ?? "pid \(r.pid)"
        var list = driverReports[key] ?? []
        if let first = list.first, first.pid != r.pid { list = [] }             // a new run of the game
        list.removeAll { $0.productID == r.productID }
        list.append(r)
        driverReports[key] = list
        if r.isProblem {
            let name = app?.localizedName ?? "A game"
            message = "\(name) is reading the N64 controller without SDL's N64 driver, so its input will be wrong. Quit it and launch it from NS2 Bridge (Games → Play with rumble), or install the helper into it."
        }
    }

    func canLaunchWithRumble(_ url: URL) -> Bool {
        guard let a = analyses[url.path] else { return false }
        return a.verdict == .ready || isHelperInstalled(url)
    }

    /// Launches the game with the matching rumble helper(s) injected, then verifies live that the
    /// helper loaded and that rumble requests arrive.
    func launch(_ url: URL) {
        let target = url
        let name = url.deletingPathExtension().lastPathComponent
        let installed = isHelperInstalled(url)
        let hooks = (analyses[url.path]?.hooks).flatMap { $0.isEmpty ? nil : $0 } ?? ["ns2rumble"]
        let paths = hooks.compactMap { Bundle.main.url(forResource: $0, withExtension: "dylib")?.path }
        guard paths.count == hooks.count else {
            message = "Rumble helper missing from the app bundle — rebuild with scripts/build-app.sh."
            return
        }
        if let id = Bundle(url: target)?.bundleIdentifier,
           !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            message = "\(name) is already running. Quit it first, then launch it from here so rumble can hook in."
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        // Games launched from here always get the SDL settings they need, even if the global switch is off.
        var env = gameSettings(for: url)
        env["NS2_LAUNCHED"] = "1"                 // the helper then keeps these instead of re-reading the file
        if installed {
            if let id = Bundle(url: url)?.bundleIdentifier { try? GameInstaller.writeSettings(env, bundleID: id) }
        } else {
            env["DYLD_INSERT_LIBRARIES"] = paths.joined(separator: ":")
        }
        cfg.environment = env
        cfg.activates = true
        gameLinkedPID = nil
        gameRumbleEvents = 0
        lastGameRumble = nil
        session = LaunchSession(gamePath: url.path, name: name)
        pendingLaunch = (name, Date())
        NSWorkspace.shared.openApplication(at: target, configuration: cfg) { app, error in
            DispatchQueue.main.async {
                if let error {
                    self.message = "Couldn't launch \(name): \(error.localizedDescription)"
                    self.session = nil
                } else if app != nil {
                    self.session?.launched = true
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let p = self.pendingLaunch, p.name == name else { return }
            self.pendingLaunch = nil
            self.session?.timedOut = true
        }
    }

    /// SDL mappings passed to a launched game: Switch 2 Pro and GameCube, plus the NSO N64 layout for its
    /// engine, numbered for the SDL that actually runs (SDL2, or SDL3 incl. sdl2-compat).
    func gameControllerConfig(for url: URL) -> String {
        var lines = [SDLMapping.allLines(layout: buttonLayout)]
        if let a = analyses[url.path], !a.sdl2Calls.isEmpty || !a.sdl3Calls.isEmpty,
           let n64 = N64Mapping.line(for: a.engine, sdl3: a.sdl3Backend ?? false) {
            lines.append(n64)
        }
        return lines.joined(separator: "\n")
    }

    /// Plain launch, no helper (for games where rumble can't be forwarded).
    func launchPlain(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Setup

    /// SDL games/emulators launched from the Finder/Dock inherit launchd's environment.
    /// SDL_JOYSTICK_MFI=0 lets SDL's IOKit backend claim the pad; the mapping makes it a gamepad.
    private func applySDL() {
        SDLLoginAgent.update(sdlEnabled ? sdlEnvironment() : nil)
        if sdlEnabled {
            launchctl(["setenv", "SDL_JOYSTICK_MFI", "0"])
            launchctl(["unsetenv", "SDL_JOYSTICK_HIDAPI"])         // set by 1.0 builds; only the N64 driver is needed
            launchctl(["setenv", "SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC", "1"])      // see gameSettings
            launchctl(["setenv", "SDL_GAMECONTROLLERCONFIG", SDLMapping.allLines(layout: buttonLayout)])
        } else {
            launchctl(["unsetenv", "SDL_JOYSTICK_MFI"])
            launchctl(["unsetenv", "SDL_JOYSTICK_HIDAPI"])
            launchctl(["unsetenv", "SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC"])
            launchctl(["unsetenv", "SDL_GAMECONTROLLERCONFIG"])
        }
    }

    /// The Finder-wide SDL settings (also restored at login by `SDLLoginAgent`).
    private func sdlEnvironment() -> [(String, String)] {
        [("SDL_JOYSTICK_MFI", "0"), ("SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC", "1"),
         ("SDL_GAMECONTROLLERCONFIG", SDLMapping.allLines(layout: buttonLayout))]
    }

    private func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Persistence

    private func save<T: Encodable>(_ key: String, _ v: T) {
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key)
    }

    static func load<T: Decodable>(_ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}
