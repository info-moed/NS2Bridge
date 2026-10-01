import CryptoKit
import Foundation
import IOKit

// MARK: - Controller kinds

/// Controllers NS2 Bridge drives. (Joy-Con 2 comes later.)
public enum ControllerKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case switch2Pro
    case n64
    case gameCube

    public var id: String { rawValue }

    public init?(productID: Int) {
        switch productID {
        case NS2Device.proController2: self = .switch2Pro
        case ClassicDevice.n64: self = .n64
        case NS2Device.gameCubeNSO: self = .gameCube
        default: return nil
        }
    }

    public var productID: Int {
        switch self {
        case .switch2Pro: return NS2Device.proController2
        case .n64: return ClassicDevice.n64
        case .gameCube: return NS2Device.gameCubeNSO
        }
    }
    public var displayName: String {
        switch self {
        case .switch2Pro: return "Switch 2 Pro Controller"
        case .n64: return "N64 Controller"
        case .gameCube: return "GameCube Controller"
        }
    }
    public var shortName: String {
        switch self {
        case .switch2Pro: return "Switch 2 Pro"
        case .n64: return "N64"
        case .gameCube: return "GameCube"
        }
    }
    /// Tiny label for the menu bar: GC, N64, PC2 (Pro Controller 2).
    public var menuCode: String {
        switch self {
        case .switch2Pro: return "PC2"
        case .n64: return "N64"
        case .gameCube: return "GC"
        }
    }
    public var stickNames: [String] {
        switch self {
        case .switch2Pro: return ["Left stick", "Right stick"]
        case .n64: return ["Stick"]
        case .gameCube: return ["Control stick", "C-stick"]
        }
    }
    public var buttonNames: [String] {
        switch self {
        case .switch2Pro: return ProButtons.named.map(\.1)
        case .n64: return N64Buttons.named.map(\.1)
        case .gameCube: return GCButtons.named.map(\.1)
        }
    }
    /// Switch 2 family (0x91 commands on the vendor interface, battery level 0–9).
    public var isSwitch2Family: Bool { self != .n64 }
    /// HD Rumble 2 exposes per-band pitch; the N64 and GameCube have simpler motors.
    public var hasPitchControl: Bool { self == .switch2Pro }
    /// Switch 2 controllers need the 0x91 wake-up; macOS already wakes the N64 controller.
    public var needsInit: Bool { isSwitch2Family }
    /// Has a gyro and accelerometer NS2 Bridge can read (report 0x05).
    public var hasMotion: Bool { self == .switch2Pro }
    /// Input report format selected at wake-up: the one macOS's HID descriptor describes, so SDL's
    /// generic backend can read it. (The Pro switches to 0x05 while motion is on.)
    public var nativeReportFormat: UInt8 { self == .gameCube ? GameCubeReport.inputID : ControllerState.reportID }
    /// Stick gate shape: the N64's octagonal notches, or a round gate.
    public var octagonalGate: Bool { self == .n64 }
    /// N64 gate: diagonal notches reach 69 of 85 on each axis.
    public static let n64Diagonal = 69.0 / 85.0

    /// How often the controller produces a new report (ms), measured on hardware:
    /// Switch 2 Pro and GameCube 4 ms (≈ 252 Hz); N64 15 ms (66.7 Hz) on USB and Bluetooth.
    public var usbIntervalMs: Double { self == .n64 ? 15 : 4 }

    /// Sensible starting calibration (the user refines it in Calibrate).
    public var defaultCalibration: StickCalibration {
        switch self {
        case .switch2Pro: return .default
        case .gameCube:
            // Measured: ≈ 1200 from center at the gate on both sticks (a near-round octagon).
            let a = AxisCal(min: 850, center: 2048, max: 3250)
            return StickCalibration(x: a, y: a, deadzone: 0.06)
        case .n64:
            let a = AxisCal(min: 900, center: 2048, max: 3200)
            return StickCalibration(x: a, y: a, deadzone: 0.06)
        }
    }
}

// MARK: - Unified input

/// One report, normalized across controller kinds.
public struct ControllerInput: Sendable {
    public var kind: ControllerKind
    public var pressed: Set<String>
    public var sticks: [Stick]
    public var battery: Double          // 0…1
    public var charging: Bool
    public var externalPower: Bool
    /// Analog triggers 0…1 (GameCube: L, R). Empty for controllers without them.
    public var triggers: [Double] = []
    /// Gyro/accelerometer (Switch 2 Pro while motion is on), bias-corrected.
    public var motion: MotionSample?

    public static func parse(_ r: [UInt8], kind: ControllerKind) -> ControllerInput? {
        switch kind {
        case .switch2Pro:
            guard let s = ControllerState(report: r) else { return nil }
            return ControllerInput(kind: kind, pressed: Set(s.buttons.names), sticks: [s.left, s.right],
                                   battery: Double(s.batteryLevel) / 9, charging: s.charging, externalPower: s.externalPower)
        case .gameCube:
            guard let s = GCState(report: r) else { return nil }
            return ControllerInput(kind: kind, pressed: Set(s.buttons.names), sticks: [s.main, s.cStick],
                                   battery: Double(s.batteryLevel) / 9, charging: s.charging, externalPower: s.externalPower,
                                   triggers: [Double(s.leftTrigger) / 255, Double(s.rightTrigger) / 255])
        case .n64:
            guard let s = N64State(report: r) else { return nil }
            return ControllerInput(kind: kind, pressed: Set(s.buttons.names), sticks: [s.stick],
                                   battery: Double(s.batteryLevel) / 4, charging: s.charging,
                                   externalPower: s.externalPower || s.charging)
        }
    }
}

// MARK: - One connected controller

public final class ConnectedController: @unchecked Sendable, Identifiable {
    public let id: String                 // "usb:<registry id>" or "ble"
    public let kind: ControllerKind
    public let transport: LatencyMonitor.Link
    public let hidID: UInt64?
    public let locationID: Int
    public internal(set) var player: Int
    public let latency = LatencyMonitor()
    public internal(set) var haptics: HapticsEngine!
    public internal(set) var lastInput: ControllerInput?
    public internal(set) var lastRaw: [UInt8] = []
    public internal(set) var reportsPerSecond = 0
    public internal(set) var ready = false          // reports are flowing
    public internal(set) var battery: BatteryReading?
    public internal(set) var mac: String?           // N64: from device info (same on USB and Bluetooth)
    /// Switch 2 family: the factory serial number from flash 0x13000 (same on USB and Bluetooth).
    /// Kept in memory only; `deviceKey` stores a fingerprint of it.
    public internal(set) var serial: String?
    public internal(set) var firmware: String?
    var lastMillivolts: Int?
    var lastStatusRaw: [UInt8] = []
    /// Gyro zero-rate offset to subtract (set from a calibration; see GyroCalibrator).
    public var gyroBias = GyroBias.zero
    let motionDecoder = MotionDecoder()
    var triggerCals = [TriggerCal(), TriggerCal()]
    /// Measured trigger ranges (from the profile); nil = learn from what arrives.
    public var triggerRanges: [TriggerRange]? {
        didSet {
            guard triggerRanges != oldValue else { return }
            triggerCals = triggerRanges.map { $0.map(TriggerCal.init(range:)) } ?? [TriggerCal(), TriggerCal()]
        }
    }

    /// Identifies the physical controller across connections (for battery history).
    public var identityKey: String { deviceKey ?? kind.rawValue }

    /// Stable identity of this physical controller, on any transport: the N64's Bluetooth address, or a
    /// one-way fingerprint of a Switch 2 controller's serial number. nil until it has been read.
    public var deviceKey: String? {
        if let mac { return "\(kind.rawValue)-\(mac)" }
        if let serial { return "\(kind.rawValue)-\(Self.fingerprint(serial))" }
        return nil
    }

    /// Short label that tells two controllers of the same kind apart, e.g. "#3F2A". Not the serial itself.
    public var tag: String? {
        if let mac { return "#" + String(Self.fingerprint(mac).prefix(4)) }
        if let serial { return "#" + String(Self.fingerprint(serial).prefix(4)) }
        return nil
    }

    static func fingerprint(_ s: String) -> String {
        SHA256.hash(data: Data(("ns2bridge:" + s).utf8)).prefix(8).map { String(format: "%02X", $0) }.joined()
    }

    var lastReport = Date()
    var reportCount = 0
    var initInFlight = false
    var stopWork: DispatchWorkItem?

    init(id: String, kind: ControllerKind, transport: LatencyMonitor.Link, hidID: UInt64?, locationID: Int, player: Int) {
        self.id = id; self.kind = kind; self.transport = transport
        self.hidID = hidID; self.locationID = locationID; self.player = player
    }

    public var name: String { kind.displayName }
    public var label: String { "P\(player) · \(kind.shortName)\(transport == .bluetooth ? " · Bluetooth" : "")" }
}

// MARK: - Game rumble routing

/// Which connected controller a game's rumble request is for.
public struct RumbleRoute<Item>: @unchecked Sendable {
    public var productID: Int
    public var player: Int
    public var deviceID: UInt64?          // IORegistry entry ID of the HID device (nil: Bluetooth LE)
    public var item: Item

    /// Device ID the game helper sends for rumble on its virtual gamepad (a Bluetooth LE controller).
    public static var bluetoothDevice: UInt64 { .max }

    public init(productID: Int, player: Int, deviceID: UInt64?, item: Item) {
        self.productID = productID; self.player = player; self.deviceID = deviceID; self.item = item
    }

    /// 1. `deviceID` (from SDL's device path "DevSrvsID:<id>", or the force-feedback plug-in's device) → that device.
    /// 2. `rank` (the controller's position among the game's controllers of this kind, in connection order)
    ///    → the same position among NS2 Bridge's, ordered by registry ID (which grows with connection time).
    /// 3. Otherwise the lowest-numbered player of that kind. `productID` 0 = any kind (old helpers).
    /// `bluetoothDevice` as the device = the Bluetooth LE controller of that kind (the helper's virtual gamepad).
    public static func choose(_ routes: [RumbleRoute], productID: Int, deviceID: UInt64, rank: Int) -> Item? {
        let candidates = routes.filter { productID == 0 || $0.productID == productID }
        if deviceID == bluetoothDevice { return candidates.first { $0.deviceID == nil }?.item }
        if deviceID != 0, let exact = candidates.first(where: { $0.deviceID == deviceID }) { return exact.item }
        if rank >= 0, candidates.count > 1 {
            let ordered = candidates.sorted { ($0.deviceID ?? .max) < ($1.deviceID ?? .max) }
            if rank < ordered.count { return ordered[rank].item }
        }
        return candidates.min { $0.player < $1.player }?.item
    }
}

// MARK: - Hub

/// Finds, wakes, and reads every supported controller; assigns players; routes rumble.
/// Start on the main thread. All callbacks arrive on the main thread.
public final class ControllerHub {
    public private(set) var controllers: [ConnectedController] = []
    /// List, players, or readiness changed.
    public var onChange: (() -> Void)?
    /// A report arrived from a controller (≈100–250/s per controller).
    public var onInput: ((ConnectedController) -> Void)?
    public var onRawReport: ((ConnectedController, [UInt8]) -> Void)?
    public var onError: ((String) -> Void)?
    public var onBLEState: ((BLELink.State) -> Void)?
    /// ForceFeedback plug-in to attach to every controller (nil = off). See ForceFeedbackRegistration.
    public var forceFeedbackPlugin: URL? {
        didSet {
            for c in controllers {
                guard let hid = c.hidID, let svc = link.service(for: hid) else { continue }
                if let p = forceFeedbackPlugin { ForceFeedbackRegistration.register(p, on: svc) }
                else { ForceFeedbackRegistration.unregister(on: svc) }
            }
        }
    }

    /// Detach the plug-in from every controller (call when the app quits).
    public func unregisterForceFeedback() {
        for c in controllers {
            if let hid = c.hidID, let svc = link.service(for: hid) { ForceFeedbackRegistration.unregister(on: svc) }
        }
    }

    /// A fresh battery reading (about every 10 s per controller).
    public var onBattery: ((ConnectedController) -> Void)?

    /// Motion (gyro + accelerometer) on: the Switch 2 Pro is switched to report 0x05, which carries plain
    /// IMU data. macOS's HID description only covers 0x09, so while this is on, games that read the Pro
    /// through SDL's generic backend see no input: use a DSU (Cemuhook) client instead.
    public var motionEnabled = false {
        didSet {
            guard motionEnabled != oldValue else { return }
            for c in controllers where c.kind.hasMotion {
                c.motionDecoder.reset()
                selectReportFormat(c)
            }
        }
    }

    /// Motion for Bluetooth controllers regardless of `motionEnabled` (Motion not Off): over Bluetooth games
    /// can't read the controller directly anyway (they get it through the helper's virtual gamepad), so 0x05
    /// costs nothing there, and the virtual gamepad's gyro works without a DSU client.
    public var bluetoothMotion = false {
        didSet {
            guard bluetoothMotion != oldValue else { return }
            for c in controllers where c.kind.hasMotion && c.transport == .bluetooth {
                c.motionDecoder.reset()
                selectReportFormat(c)
            }
        }
    }

    /// The input report format a controller should stream right now.
    public func reportFormat(for c: ConnectedController) -> UInt8 {
        let motion = motionEnabled || (bluetoothMotion && c.transport == .bluetooth)
        return c.kind.hasMotion && motion ? Report05.id : c.kind.nativeReportFormat
    }

    public let ble = BLELink()
    private let link = HIDLink(productIDs: ControllerKind.allCases.map(\.productID))
    private let initQueue = DispatchQueue(label: "ns2.hub.init", qos: .userInitiated)
    private let rumbleQueue = DispatchQueue(label: "ns2.hub.rumble", qos: .userInteractive)
    private var watchdog: Timer?
    private var pollCounter = 0
    /// productID → (player, controller) snapshot, readable from any thread for low-latency game rumble.
    private let routeLock = NSLock()
    private var rumbleRoutes: [RumbleRoute<ConnectedController>] = []

    private func refreshRoutes() {
        let routes = controllers.map { RumbleRoute(productID: $0.kind.productID, player: $0.player, deviceID: $0.hidID, item: $0) }
        routeLock.withLock { rumbleRoutes = routes }
    }

    public init() {}

    public func controller(id: String?) -> ConnectedController? { controllers.first { $0.id == id } }

    private func changed() {
        refreshRoutes()
        onChange?()
    }
    public var playerOne: ConnectedController? { controllers.min { $0.player < $1.player } }

    public func start() {
        link.onDeviceChange = { [weak self] up, info in self?.deviceChanged(up, info) }
        link.onDeviceReport = { [weak self] r, ts, hid in
            guard let self, let c = self.controllers.first(where: { $0.hidID == hid }) else { return }
            c.latency.record(r, link: c.transport, hidTimestamp: ts)
            self.handle(r, from: c)
        }
        ble.onReport = { [weak self] r in
            guard let self else { return }
            // Arrival time, on the BLE queue: the route snapshot is the thread-safe view of the controllers.
            self.routeLock.withLock { self.rumbleRoutes.first { $0.item.id == "ble" }?.item }?.latency.record(r, link: .bluetooth)
            DispatchQueue.main.async {
                guard let c = self.controller(id: "ble") else { return }
                self.handle(r, from: c)
            }
        }
        ble.onState = { [weak self] st in DispatchQueue.main.async { self?.bleChanged(st) } }
        ble.onAck = { [weak self] r in DispatchQueue.main.async {
            guard let self, let c = self.controller(id: "ble") else { return }
            if r.first == 0x02, c.serial == nil, let s = NS2Command.serial(fromFlashReply: r) {
                c.serial = s                                   // flash read reply (identity)
                self.changed()
                return
            }
            self.handleSwitch2BatteryReply(r, for: c)
        } }
        do { try link.start() } catch { onError?("\(error)") }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: Devices

    private func nextFreePlayer() -> Int {
        let used = Set(controllers.map(\.player))
        return (1...8).first { !used.contains($0) } ?? controllers.count + 1
    }

    private func deviceChanged(_ up: Bool, _ info: HIDDeviceInfo) {
        let id = "hid:\(info.id)"
        if up {
            guard let kind = ControllerKind(productID: info.productID), controller(id: id) == nil else { return }
            let c = ConnectedController(id: id, kind: kind, transport: info.isBluetooth ? .bluetooth : .usb,
                                        hidID: info.id, locationID: info.locationID, player: nextFreePlayer())
            c.haptics = makeHaptics(for: c)
            controllers.append(c)
            sortPlayers()
            // Attach the ForceFeedback plug-in as early as possible, before games enumerate the device.
            if let p = forceFeedbackPlugin, let svc = link.service(for: info.id) { ForceFeedbackRegistration.register(p, on: svc) }
            if kind.needsInit && c.transport == .usb {
                initialize(c)                                   // (over Bluetooth HID macOS brought it up)
            } else {
                if c.transport == .bluetooth { switch1BluetoothBringUp(c) }
                setPlayerLights(c)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.switch1Subcommand(c, 0x02, [])                // device info → firmware + MAC
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.requestBattery(c) }
            changed()
        } else if let i = controllers.firstIndex(where: { $0.id == id }) {
            controllers[i].haptics.stopAll()
            controllers.remove(at: i)
            changed()
        }
    }

    private func bleChanged(_ st: BLELink.State) {
        onBLEState?(st)
        if case .connected = st, controller(id: "ble") == nil {
            let kind = ControllerKind(productID: ble.productID) ?? .switch2Pro
            let c = ConnectedController(id: "ble", kind: kind, transport: .bluetooth, hidID: nil,
                                        locationID: 0, player: nextFreePlayer())
            c.haptics = makeHaptics(for: c)
            controllers.append(c)
            sortPlayers()
            setPlayerLights(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.ble.command(NS2Command.flashRead(address: 0x13000))      // serial → identity (read-only)
            }
            if kind.hasMotion { selectReportFormat(c) }       // motion reports if wanted, else its own
            changed()
        } else if !ble.isConnected, let i = controllers.firstIndex(where: { $0.id == "ble" }) {
            controllers.remove(at: i)
            changed()
        }
    }

    private func makeHaptics(for c: ConnectedController) -> HapticsEngine {
        switch (c.kind, c.transport) {
        case (.switch2Pro, .bluetooth):
            return HapticsEngine { [weak self] r in self?.ble.sendRumble(usbReport: r) }
        case (.switch2Pro, .usb):
            let hid = c.hidID!
            return HapticsEngine { [weak self] r in self?.link.sendOutput(r, to: hid) }
        case (.gameCube, .bluetooth) where c.id == "ble":
            return .gameCube { [weak self] r in self?.ble.sendRumble(usbReport: r) }
        case (.gameCube, _):
            let hid = c.hidID ?? 0
            return .gameCube { [weak self] r in self?.link.sendOutput(r, to: hid) }
        case (.n64, _):
            let hid = c.hidID ?? 0, size = Self.switch1PacketSize(c)
            return .switch1 { [weak self] r in self?.link.sendOutput(Self.pad(r, to: size), to: hid) }
        }
    }

    private func handle(_ r: [UInt8], from c: ConnectedController) {
        if c.kind == .n64, r.first == 0x21, r.count >= 17 {
            handleSwitch1Reply(r, for: c)
            onRawReport?(c, r)
            return
        }
        c.lastRaw = r
        guard var input = ControllerInput.parse(r, kind: c.kind) else { onRawReport?(c, r); return }
        if c.kind == .switch2Pro, r.first == Report05.id {
            // 0x05 has a voltage but no power flags: keep the last ones 0x09 reported.
            if let prev = c.lastInput {
                input.charging = prev.charging
                input.externalPower = prev.externalPower
                if prev.battery > 0 { input.battery = prev.battery }
            } else {
                input.externalPower = c.transport == .usb
            }
            if let mv = Report05.millivolts(r) { c.lastMillivolts = mv }
            if var m = c.motionDecoder.decode(r) {
                m.gyro -= c.gyroBias.vector
                input.motion = m
            }
        }
        for i in input.triggers.indices where i < c.triggerCals.count {
            input.triggers[i] = c.triggerCals[i].normalize(UInt8(max(0, min(255, (input.triggers[i] * 255).rounded()))))
        }
        c.lastInput = input
        c.lastReport = Date()
        c.reportCount += 1
        if !c.ready { c.ready = true; changed() }
        onRawReport?(c, r)
        onInput?(c)
    }

    // MARK: Switch 2 wake-up

    /// Re-send the wake-up sequence to one controller (UI "Reconnect").
    public func reinitialize(_ c: ConnectedController) {
        if c.kind.needsInit, c.transport == .usb { initialize(c) }
    }

    private func initialize(_ c: ConnectedController) {
        guard !c.initInFlight else { return }
        c.initInFlight = true
        c.motionDecoder.reset()
        let pid = c.kind.productID, loc = c.locationID, led = Self.ledMask(c.player), format = reportFormat(for: c)
        let needSerial = c.serial == nil
        // Give IOKit a moment to finish matching the controller's other interfaces.
        initQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            var err: String?
            var serial: String?
            do {
                let usb = try VendorUSB(productID: pid, locationID: loc)
                for step in NS2Command.initSequence(led: led, format: format) {
                    _ = try usb.command(step.bytes)
                    usleep(20_000)
                }
                if needSerial, let reply = try? usb.readFlash(0x13000) { serial = NS2Command.serial(fromFlashReply: reply) }
                usb.close()
            } catch { err = "\(error)" }
            DispatchQueue.main.async {
                if let serial, c.serial == nil { c.serial = serial; self?.changed() }
                c.initInFlight = false
                c.lastReport = Date()
                if let err { self?.onError?(err) }
            }
        }
    }

    /// Switch a running controller between report formats (0x09 ↔ 0x05 for motion).
    private func selectReportFormat(_ c: ConnectedController) {
        let format = reportFormat(for: c)
        switch c.transport {
        case .bluetooth:
            ble.setMotionReports(format == Report05.id)             // Bluetooth: chosen by subscription
        case .usb:
            let pid = c.kind.productID, loc = c.locationID
            initQueue.async { [weak self] in
                do {
                    let usb = try VendorUSB(productID: pid, locationID: loc)
                    _ = try usb.command(NS2Command.setReportFormat(format))
                    usb.close()
                } catch {
                    DispatchQueue.main.async { self?.onError?("\(error)") }
                }
            }
        }
    }

    private func tick() {
        link.sweep()            // drop anything macOS no longer lists
        pollCounter += 1
        if pollCounter % 10 == 0 { for c in controllers where c.ready { requestBattery(c) } }
        for c in controllers {
            c.reportsPerSecond = c.reportCount
            c.reportCount = 0
            let silent = Date().timeIntervalSince(c.lastReport)
            if silent > 1.5, c.ready { c.ready = false }       // shows as "no signal" until reports return
            if c.kind.needsInit, c.transport == .usb, !c.initInFlight, silent > 2 {
                initialize(c)       // stream stopped (sleep/wake, host reset) — wake it again
            } else if c.kind == .n64, c.transport == .bluetooth, silent > 2, Int(silent) % 3 == 0 {
                switch1BluetoothBringUp(c)                     // still in simple mode? ask again
            }
        }
        changed()
    }

    // MARK: Disconnect

    /// Can NS2 Bridge turn this controller off? Only wireless ones: on USB the controller is powered (and
    /// charging) by the Mac, so it isn't using its battery; unplugging is the way to disconnect it.
    public func canDisconnect(_ c: ConnectedController) -> Bool { c.transport == .bluetooth }

    /// Turn a wireless controller off to save its battery. It reconnects when you press a button (N64) or
    /// the sync button (Switch 2 family).
    public func disconnect(_ c: ConnectedController) {
        guard canDisconnect(c) else { return }
        c.haptics.stopAll()
        if c.id == "ble" {
            ble.disconnect()                                   // controller idles, then sleeps
        } else if c.kind == .n64 {
            // Original-Switch subcommand 0x06 "set HCI state", 0x00 = disconnect: the controller drops the
            // link and powers down (dekuNukem/Nintendo_Switch_Reverse_Engineering, bluetooth_hid_subcommands.md).
            switch1Subcommand(c, 0x06, [0x00])
        }
    }

    // MARK: Players

    /// Player lights: P1 ▮▯▯▯, P2 ▮▮▯▯, P3 ▮▮▮▯, P4 ▮▮▮▮.
    static func ledMask(_ player: Int) -> UInt8 { [0x1, 0x3, 0x7, 0xF][max(0, min(3, player - 1))] }

    private func sortPlayers() { controllers.sort { $0.player < $1.player } }

    /// Move a controller to a player slot, swapping with whoever had it.
    public func assign(_ c: ConnectedController, toPlayer p: Int) {
        if let other = controllers.first(where: { $0.player == p && $0 !== c }) {
            other.player = c.player
            setPlayerLights(other)
        }
        c.player = p
        setPlayerLights(c)
        sortPlayers()
        changed()
    }

    private func setPlayerLights(_ c: ConnectedController) {
        let mask = Self.ledMask(c.player)
        switch (c.kind, c.transport) {
        case (.n64, _):
            switch1Subcommand(c, 0x30, [mask])      // set player lights
        case (_, .bluetooth):
            ble.command(NS2Command.setPlayerLED(mask))
        case (_, .usb):
            let loc = c.locationID, pid = c.kind.productID
            initQueue.async {
                guard let usb = try? VendorUSB(productID: pid, locationID: loc) else { return }
                _ = try? usb.command(NS2Command.setPlayerLED(mask))
                usb.close()
            }
        }
    }

    // MARK: Original-Switch protocol (NSO N64)

    /// SDL pads Switch 1 output reports to 49 bytes over Bluetooth and 64 over USB; do the same.
    static func switch1PacketSize(_ c: ConnectedController) -> Int { c.transport == .bluetooth ? 49 : 64 }

    static func pad(_ r: [UInt8], to size: Int) -> [UInt8] {
        r.count >= size ? r : r + [UInt8](repeating: 0, count: size - r.count)
    }

    private var subcommandCounter = 0

    /// Output report 0x01: [0x01, counter, neutral rumble ×2, subcommand, args…].
    private func switch1Subcommand(_ c: ConnectedController, _ sub: UInt8, _ args: [UInt8]) {
        guard let hid = c.hidID else { return }
        subcommandCounter = (subcommandCounter + 1) & 0x0F
        let r = [0x01, UInt8(subcommandCounter)] + Switch1Rumble.neutral + Switch1Rumble.neutral + [sub] + args
        link.sendOutput(Self.pad(r, to: Self.switch1PacketSize(c)), to: hid)
    }

    /// Over Bluetooth, Switch 1 controllers start in the simple 0x3F report mode. Ask for the full
    /// 0x30 reports (sticks at full resolution, same layout as USB) and turn vibration on.
    private func switch1BluetoothBringUp(_ c: ConnectedController) {
        switch1Subcommand(c, 0x03, [0x30])                         // input report mode: full (0x30)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.switch1Subcommand(c, 0x48, [0x01])               // enable vibration
        }
    }

    // MARK: Battery

    /// Ask the controller for its battery voltage (and charge status on Switch 2).
    public func requestBattery(_ c: ConnectedController) {
        switch (c.kind, c.transport) {
        case (.n64, _):
            switch1Subcommand(c, 0x50, [])                        // regulated voltage
        case (_, .bluetooth):
            ble.command([0x0B, 0x91, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.ble.command([0x0B, 0x91, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00])
            }
        case (_, .usb):
            let loc = c.locationID, pid = c.kind.productID
            initQueue.async { [weak self] in
                guard let usb = try? VendorUSB(productID: pid, locationID: loc) else { return }
                let v = try? usb.command([0x0B, 0x91, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00])
                let st = try? usb.command([0x0B, 0x91, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00])
                usb.close()
                DispatchQueue.main.async {
                    if let v = v ?? nil { self?.handleSwitch2BatteryReply(v, for: c) }
                    if let st = st ?? nil { self?.handleSwitch2BatteryReply(st, for: c) }
                }
            }
        }
    }

    /// Switch 2 replies: 0B 01 00 03 … data[8..9] = mV; 0B 01 00 04 … data[8..11] = charge status.
    private func handleSwitch2BatteryReply(_ r: [UInt8], for c: ConnectedController) {
        guard r.count >= 10, r[0] == 0x0B else { return }
        if r[3] == 0x03 {
            let mv = Int(r[8]) | Int(r[9]) << 8
            if (2500...4600).contains(mv) { c.lastMillivolts = mv }
            publishBattery(c)
        } else if r[3] == 0x04 {
            c.lastStatusRaw = Array(r[8..<min(r.count, 12)])
        }
    }

    /// Original-Switch subcommand replies (input report 0x21): [13] ack, [14] subcommand, [15…] data.
    private func handleSwitch1Reply(_ r: [UInt8], for c: ConnectedController) {
        switch r[14] {
        case 0x50:                                               // voltage, ×2.5 mV
            let raw = Int(r[15]) | Int(r[16]) << 8
            let mv = Int((Double(raw) * 2.5).rounded())
            if (2500...4600).contains(mv) { c.lastMillivolts = mv }
            publishBattery(c)
        case 0x02 where r.count >= 25:                           // device info: fw major/minor, type, ?, MAC
            c.firmware = "\(r[15]).\(r[16])"
            c.mac = r[19...24].map { String(format: "%02X", $0) }.joined(separator: ":")
            changed()
        default:
            break
        }
    }

    private func publishBattery(_ c: ConnectedController) {
        guard let i = c.lastInput else { return }
        c.battery = BatteryReading(millivolts: c.lastMillivolts, level: i.battery, charging: i.charging,
                                   externalPower: i.externalPower || (c.kind == .n64 && c.transport == .usb),
                                   statusRaw: c.lastStatusRaw)
        onBattery?(c)
    }

    // MARK: Game rumble

    /// Rumble from a game (SDL semantics), routed by `RumbleRoute.choose`: the exact device when the game
    /// side knows it, else by connection order, else the lowest-numbered player of that kind.
    /// Safe to call from any thread — the network listener calls it directly, skipping the main thread.
    public func gameRumble(productID: Int, deviceID: UInt64 = 0, rank: Int = -1,
                           low: Double, high: Double, milliseconds: UInt32) {
        let target = routeLock.withLock { RumbleRoute.choose(rumbleRoutes, productID: productID, deviceID: deviceID, rank: rank) }
        guard let c = target else { return }
        rumbleQueue.async {
            c.stopWork?.cancel(); c.stopWork = nil
            let level = HapticLevel(low: low, high: high)
            c.haptics.setContinuous(left: level, right: level)
            if (low > 0 || high > 0), milliseconds > 0 {
                let w = DispatchWorkItem { c.haptics.setContinuous(left: .off, right: .off) }
                c.stopWork = w
                self.rumbleQueue.asyncAfter(deadline: .now() + .milliseconds(Int(min(milliseconds, 65535))), execute: w)
            }
        }
    }
}
