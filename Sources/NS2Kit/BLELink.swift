import CoreBluetooth
import Foundation
import os

/// Bluetooth diagnostics, in the system log: `log show --predicate 'subsystem == "local.ns2bridge"' --last 10m`
let bleLog = Logger(subsystem: "local.ns2bridge", category: "ble")

/// How often the controller reports over Bluetooth (the connection interval). The controller never asks for a
/// faster interval and macOS defaults to 30 ms; NS2 Bridge requests one through a private CoreBluetooth call
/// (bluetoothd latency levels, verified on hardware with the Pro: 7.5 ms → 133 reports/s, gyro included).
public enum BluetoothSpeed: String, CaseIterable, Identifiable, Sendable {
    case fastest, fast, standard
    public var id: String { rawValue }
    public var title: String { self == .fastest ? "Fastest" : self == .fast ? "Fast" : "Standard" }
    public var intervalMs: Double { self == .fastest ? 7.5 : self == .fast ? 15 : 30 }
    /// bluetoothd level: -12 "midi v2" (7.5 ms, events long enough for a 63-byte report; -25 "super-low" isn't),
    /// -7 "very-low" (15 ms), 0 "low" (10–30 ms, the chip picks 30: macOS's default).
    var latencyLevel: Int64 { self == .fastest ? -12 : self == .fast ? -7 : 0 }
}

/// Bluetooth LE link to a Switch 2-family controller (Pro Controller 2, NSO GameCube) — CoreBluetooth
/// central, no pairing/SMP (the controller drops the link if SMP is attempted). Layout per ndeadly
/// bluetooth_interface.md and hid_reports.md: each controller has its own input and rumble characteristics.
///
/// Latency: macOS picks the connection interval (the controller never requests one), so the
/// report rate is whatever bluetoothd grants — `measuredRate` / `measuredIntervalMs` report it.
public final class BLELink: NSObject, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case off, unauthorized, idle, scanning, connecting(String), connected(String), failed(String)
    }

    static let service = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0")
    static let input05 = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2")
    static let input09 = CBUUID(string: "7492866C-EC3E-4619-8258-32755FFCC0F8")      // Pro Controller 2
    static let input0A = CBUUID(string: "8261CBA1-9435-420C-84D6-F0C75A2C8E4D")      // NSO GameCube
    static let rumble = CBUUID(string: "CC483F51-9258-427D-A939-630C31F72B05")       // Pro: output 0x02
    static let rumble03 = CBUUID(string: "3F8FB670-AB25-45BF-B540-38C72834D064")     // GameCube: output 0x03

    /// Product ID of the controller being connected / connected (from its advertisement).
    public private(set) var productID = NS2Device.proController2
    private var inputChar: CBUUID { productID == NS2Device.gameCubeNSO ? Self.input0A : Self.input09 }
    private var inputReportID: UInt8 { productID == NS2Device.gameCubeNSO ? GameCubeReport.inputID : ControllerState.reportID }
    private var rumbleChar: CBUUID { productID == NS2Device.gameCubeNSO ? Self.rumble03 : Self.rumble }
    static let command = CBUUID(string: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")
    static let commandAck = CBUUID(string: "C765A961-D9D8-4D36-A20A-5315B111836A")
    static let reportRate = CBUUID(string: "679D5510-5A24-4DEE-9557-95DF80486ECB")

    /// Called on the BLE queue with a report normalized to the USB layout (report ID 0x09 prepended).
    public var onReport: (([UInt8]) -> Void)?
    /// Called on the BLE queue.
    public var onState: ((State) -> Void)?
    public var onAck: (([UInt8]) -> Void)?

    public private(set) var state: State = .off { didSet { if state != oldValue { onState?(state) } } }
    public private(set) var measuredRate = 0.0          // reports/s
    /// Wanted speed (applied at connect and when changed) and the one in effect: Fastest drops to Fast by
    /// itself if reports collapse at 7.5 ms (seen with bluetoothd's other 7.5 ms level).
    public var speed: BluetoothSpeed = .fastest {
        didSet { queue.async { [self] in if let p = peripheral { applySpeed(speed, to: p) } } }
    }
    public private(set) var effectiveSpeed: BluetoothSpeed = .standard
    private var reportsSinceSpeed = 0
    public private(set) var measuredIntervalMs = 0.0    // mean gap between notifications
    public private(set) var jitterMs = 0.0              // std-dev of the gap

    private let queue = DispatchQueue(label: "ns2.ble", qos: .userInteractive)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var wantScan = false
    private var gaps: [Double] = []
    private var notifyCounts: [String: Int] = [:]
    private var lastCountLog = Date.distantPast
    private var lastNotify: UInt64 = 0
    private var imuStamp: UInt32 = 0            // IMU timestamp of the latest 0x05 notification (0 = no motion)
    private var imuRetried = false
    /// Commands sent one at a time, each after the previous one's reply (or a timeout): sent 30 ms apart,
    /// replies went missing and a command could land before the previous one had taken effect.
    private enum Step { case command([UInt8]), run(() -> Void) }
    private var steps: [Step] = []
    private var awaiting: (command: UInt8, sub: UInt8)?
    private var stepTimeout: DispatchWorkItem?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        if UserDefaults.standard.bool(forKey: "BLEDebugCommands") {       // the app's domain: local.ns2bridge
            DistributedNotificationCenter.default().addObserver(forName: .init("local.ns2bridge.debug.ble"), object: nil,
                                                                queue: nil) { [weak self] n in
                if let text = n.object as? String { self?.debugCommand(text) }
            }
            bleLog.notice("debug commands on")
        }
    }

    /// Research aid, off unless `defaults write local.ns2bridge BLEDebugCommands -bool true`. Takes a
    /// distributed notification "local.ns2bridge.debug.ble" whose object is one of:
    /// `cmd <hex>` (0x91 command, see `debugAllowed`) · `sub 05` / `sub own` ·
    /// `rate <hex>` (report-rate descriptor on both inputs) · `latency <level>` (bluetoothd level, see
    /// `setConnectionLatency`) · `hps 1 <ms>` (private high-priority stream; didn't change the interval).
    private func debugCommand(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        let hex = { (words: ArraySlice<String>) in words.joined().chunked2().compactMap { UInt8($0, radix: 16) } }
        bleLog.notice("debug: \(text, privacy: .public)")
        queue.async { [self] in
            guard let p = peripheral else { bleLog.notice("debug: not connected"); return }
            switch verb {
            case "cmd":
                let b = hex(parts.dropFirst())
                guard b.count >= 8, Self.debugAllowed(b) else { bleLog.notice("debug: refused"); return }
                command(b)
            case "sub":
                motionReports = parts.dropFirst().first == "05"
                applyInputSubscription()
            case "rate":
                let b = hex(parts.dropFirst())
                for uuid in [inputChar, Self.input05] {
                    if let d = chars[uuid]?.descriptors?.first(where: { $0.uuid == Self.reportRate }) { p.writeValue(Data(b), for: d) }
                }
            case "latency":
                guard let level = Int64(parts.dropFirst().first ?? "") else { return }
                setConnectionLatency(level, for: p)
            case "hps":                                   // private: -[CBPeripheral setHighPriorityStream:duration:]
                let sel = NSSelectorFromString("setHighPriorityStream:duration:")
                guard parts.count >= 3, let ms = Int(parts[2]), p.responds(to: sel) else { return }   // hps 1 <ms>
                typealias F = @convention(c) (AnyObject, Selector, ObjCBool, NSNumber) -> Void
                unsafeBitCast(p.method(for: sel), to: F.self)(p, sel, ObjCBool(parts[1] == "1"), NSNumber(value: ms))  // integer: bluetoothd rejects a double
            default:
                bleLog.notice("debug: unknown verb")
            }
        }
    }

    /// Commands the research channel may send: setup, lights, vibration, battery, features, and flash *reads*.
    /// Never flash write/erase (0x02 0x02/0x03), firmware update (0x0D), pairing (0x15), USB init with a host
    /// address (0x03) or NFC (0x01): NS2 Bridge doesn't write to the controller's memory (LEGAL.md).
    static func debugAllowed(_ b: [UInt8]) -> Bool {
        guard b.count >= 4 else { return false }
        switch b[0] {
        case 0x07, 0x09, 0x0A, 0x0B, 0x0C, 0x10, 0x11, 0x16: return true
        case 0x02: return b[3] == 0x01 || b[3] == 0x04          // read memory block
        default: return false
        }
    }

    private func applySpeed(_ s: BluetoothSpeed, to p: CBPeripheral) {
        // Standard makes no private call at connect (macOS's own choice); switching to it mid-connection
        // undoes an earlier request with the public level 0 ("low", macOS's default range).
        if s != .standard || effectiveSpeed != .standard { setConnectionLatency(s.latencyLevel, for: p) }
        effectiveSpeed = s
        reportsSinceSpeed = 0
        guard s == .fastest else { return }
        queue.asyncAfter(deadline: .now() + 3) { [self] in
            // Expect ≈ 400 reports in 3 s; the collapse seen at 7.5 ms left a handful.
            guard effectiveSpeed == .fastest, peripheral === p, reportsSinceSpeed < 150 else { return }
            bleLog.notice("only \(self.reportsSinceSpeed, privacy: .public) reports in 3 s at 7.5 ms: dropping to 15 ms")
            setConnectionLatency(BluetoothSpeed.fast.latencyLevel, for: p)
            effectiveSpeed = .fast
        }
    }

    /// Private: -[CBCentralManager setDesiredConnectionLatency:forPeripheral:] (no entitlement needed; bluetoothd
    /// levels -25…2, see `BluetoothSpeed`). Level -22 "LEHID-5ms" is accepted but not applied on this Mac's chip.
    private func setConnectionLatency(_ level: Int64, for p: CBPeripheral) {
        let sel = NSSelectorFromString("setDesiredConnectionLatency:forPeripheral:")
        guard central.responds(to: sel) else { bleLog.notice("setDesiredConnectionLatency unavailable"); return }
        typealias F = @convention(c) (AnyObject, Selector, Int64, CBPeripheral) -> Void
        unsafeBitCast(central.method(for: sel), to: F.self)(central, sel, level, p)
        bleLog.notice("connection latency level \(level, privacy: .public) requested")
    }

    /// Start looking for a controller in sync mode (small button on top) or reconnecting.
    public func connect() {
        queue.async { [self] in
            wantScan = true
            if central.state == .poweredOn { startScan() }
        }
    }

    public func disconnect() {
        queue.async { [self] in
            wantScan = false
            central.stopScan()
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil
            state = .idle
        }
    }

    public var isConnected: Bool { if case .connected = state { return true } else { return false } }

    /// Over Bluetooth the input report is chosen by which characteristic is subscribed, not by the USB
    /// "select input report" command: the controller streams one input characteristic at a time.
    /// true = the common report 0x05 (buttons, sticks and plain motion data); false = the controller's own
    /// report (0x09 Pro, 0x0A GameCube).
    public private(set) var motionReports = false

    public func setMotionReports(_ on: Bool) {
        queue.async { [self] in
            let switchedOn = on && !motionReports
            motionReports = on
            applyInputSubscription()
            if switchedOn { checkMotionData() }
        }
    }

    /// Feature flags: 0x01 buttons, 0x02 sticks, 0x04 IMU, 0x20 rumble (ndeadly commands.md, command 0x0C).
    static let featureMask: [UInt8] = [0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00]
    static let enableFeatures: [UInt8] = [0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00]
    /// Motion over Bluetooth (verified on hardware): the IMU needs "configure features" (ndeadly's example
    /// parameters, meaning unknown), which the controller refuses (reply `0C 02`) while the IMU is enabled.
    /// So: IMU off, configure, IMU on. Until then report 0x05 streams with its IMU fields all zero.
    static let imuSetup: [[UInt8]] = [
        [0x0C, 0x91, 0x01, 0x05, 0x00, 0x04, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00],                          // disable IMU
        [0x0C, 0x91, 0x01, 0x06, 0x00, 0x0A, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x02, 0x01, 0x00, 0x8A, 0x00],  // configure
        [0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00],                          // enable IMU
    ]
    /// "Get feature info" (read-only): reply byte 14 is the IMU's entry, 0x07 once motion is flowing
    /// (0x05 while it is enabled but not configured).
    static let featureInfo: [UInt8] = [0x0C, 0x91, 0x01, 0x01, 0x00, 0x04, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00]

    /// Safety net: if no motion data shows up 2 s after switching to 0x05, run the IMU setup once more.
    private func checkMotionData() {
        imuStamp = 0
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            guard motionReports, peripheral != nil, productID == NS2Device.proController2 else { return }
            if imuStamp != 0 { bleLog.notice("motion data present"); return }
            guard !imuRetried else { bleLog.notice("motion data still zero after re-running the IMU setup"); return }
            imuRetried = true
            bleLog.notice("motion data zero 2 s after switching to 0x05: re-running the IMU setup")
            enqueue((Self.imuSetup + [Self.featureInfo]).map { .command($0) })
        }
    }

    /// Queue commands (and actions) to run in order, each command waiting for its reply (max 300 ms).
    private func enqueue(_ new: [Step]) {
        let idle = steps.isEmpty && awaiting == nil
        steps += new
        if idle { nextStep() }
    }

    private func nextStep() {
        stepTimeout?.cancel()
        awaiting = nil
        guard peripheral != nil else { steps.removeAll(); return }
        while !steps.isEmpty {
            switch steps.removeFirst() {
            case .run(let action):
                action()
            case .command(let c):
                command(c)
                awaiting = (c[0], c[3])
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, let a = self.awaiting else { return }
                    bleLog.notice("no reply to \(String(format: "%02X %02X", a.command, a.sub), privacy: .public)")
                    self.nextStep()
                }
                stepTimeout = timeout
                queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: timeout)
                return
            }
        }
    }

    private func applyInputSubscription() {
        guard let p = peripheral, let own = chars[inputChar] else { return }
        let motion = chars[Self.input05]
        if motionReports, let motion {
            p.setNotifyValue(false, for: own)
            p.setNotifyValue(true, for: motion)
        } else {
            if let motion { p.setNotifyValue(false, for: motion) }
            p.setNotifyValue(true, for: own)
        }
        bleLog.notice("input subscription: \(self.motionReports ? "0x05 (motion)" : "own report", privacy: .public)")
    }

    /// Rumble: the USB output report (0x02 Pro, 0x03 GameCube, 64 B) → the controller's BLE rumble
    /// characteristic (first byte 0x00 instead of the report ID). Frames are dropped (not queued) when the
    /// link is busy, so rumble never lags behind.
    public func sendRumble(usbReport r: [UInt8]) {
        queue.async { [self] in
            guard let p = peripheral, let c = chars[rumbleChar], p.canSendWriteWithoutResponse else { return }
            var b = Array(r.prefix(productID == NS2Device.gameCubeNSO ? 42 : 41))
            b[0] = 0x00
            p.writeValue(Data(b), for: c, type: .withoutResponse)
        }
    }

    /// Send a 0x91-family command (byte 2 is forced to 0x01 = Bluetooth transport).
    public func command(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard let p = peripheral, let c = chars[Self.command] else { return }
            var b = bytes
            if b.count > 2 { b[2] = 0x01 }
            if b.first != 0x0B {                      // not the periodic battery reads
                bleLog.notice("command \(b.prefix(18).map { String(format: "%02X", $0) }.joined(separator: " "), privacy: .public)")
            }
            p.writeValue(Data(b), for: c, type: c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        }
    }

    private func startScan() {
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Nintendo company ID 0x0553, then 01 00 03, VID 057E, PID (LE).
    static func productID(fromManufacturerData d: Data) -> Int? {
        let b = [UInt8](d)
        guard b.count >= 9, b[0] == 0x53, b[1] == 0x05, b[5] == 0x7E, b[6] == 0x05 else { return nil }
        let pid = Int(b[7]) | Int(b[8]) << 8
        return NS2Device.names[pid] != nil ? pid : nil
    }

    private func runInit() {
        // Mirrors the console's Pro Controller bring-up (ndeadly bluetooth_interface.md), minus pairing.
        let seq: [[UInt8]] = [
            [0x07, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00],
            [0x16, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00],
            NS2Command.setPlayerLED(0x01),
            Self.featureMask,
            [0x11, 0x91, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00],
            [0x0A, 0x91, 0x01, 0x08, 0x00, 0x14, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
             0x35, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            Self.enableFeatures,
        ] + (productID == NS2Device.proController2 ? Self.imuSetup + [Self.featureInfo] : []) + [
            [0x0A, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00],  // "connected" vibration
        ]
        // Then the "set report rate?" descriptor write the console does (meaning unconfirmed), on both input
        // characteristics: the controller's own report and the common 0x05 one (motion).
        enqueue(seq.map { .command($0) } + [.run { [self] in
            guard let p = peripheral else { return }
            for uuid in [inputChar, Self.input05] {
                guard let c = chars[uuid], let d = c.descriptors?.first(where: { $0.uuid == Self.reportRate }) else {
                    bleLog.notice("no report-rate descriptor on \(uuid.uuidString, privacy: .public)")
                    continue
                }
                p.writeValue(Data([0x85, 0x00]), for: d)
                bleLog.notice("report-rate descriptor written on \(uuid.uuidString, privacy: .public)")
            }
        }])
    }

    private func recordTiming() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastNotify != 0 { gaps.append(Double(now - lastNotify) / 1e6) }
        lastNotify = now
        if gaps.count >= 120 {
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            let varc = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)
            measuredIntervalMs = mean
            jitterMs = varc.squareRoot()
            measuredRate = mean > 0 ? 1000 / mean : 0
            gaps.removeAll(keepingCapacity: true)
        }
    }
}

extension BLELink: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: if wantScan { startScan() } else { state = .idle }
        case .unauthorized: state = .unauthorized
        default: state = .off
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData ad: [String: Any], rssi: NSNumber) {
        guard peripheral == nil, let d = ad[CBAdvertisementDataManufacturerDataKey] as? Data,
              let pid = Self.productID(fromManufacturerData: d) else { return }
        c.stopScan()
        peripheral = p
        productID = pid
        p.delegate = self
        state = .connecting(NS2Device.names[pid] ?? "Controller")
        // Research: private connect option, off unless `defaults write local.ns2bridge BLELatencyCritical -bool true`.
        let latencyCritical = UserDefaults.standard.bool(forKey: "BLELatencyCritical")
        c.connect(p, options: latencyCritical ? ["kCBConnectOptionLatencyCritical": true] : nil)
        if latencyCritical { bleLog.notice("connecting with kCBConnectOptionLatencyCritical") }
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.service])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        peripheral = nil
        state = .failed(error?.localizedDescription ?? "connection failed")
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        peripheral = nil
        chars.removeAll()
        imuRetried = false
        effectiveSpeed = .standard
        steps.removeAll()
        stepTimeout?.cancel()
        awaiting = nil
        measuredRate = 0
        if wantScan { startScan() } else { state = .idle }   // auto-rescan: press sync again to reconnect
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
            state = .failed("Nintendo service not found"); return
        }
        p.discoverCharacteristics(nil, for: s)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] { chars[c.uuid] = c }
        guard let input = chars[inputChar] else { state = .failed("input characteristic not found"); return }
        p.discoverDescriptors(for: input)
        if let motion = chars[Self.input05] { p.discoverDescriptors(for: motion) }
        bleLog.notice("characteristics: \(self.chars.keys.map(\.uuidString).sorted().joined(separator: ", "), privacy: .public)")
        if let ack = chars[Self.commandAck] { p.setNotifyValue(true, for: ack) }
        applyInputSubscription()                  // the controller's own report, or 0x05 if motion is wanted
        applySpeed(speed, to: p)
        runInit()
        if case .connecting(let name) = state { state = .connected(name) }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        bleLog.notice("notify \(c.isNotifying ? "on" : "off", privacy: .public) for \(c.uuid.uuidString, privacy: .public)\(error.map { " error: \($0.localizedDescription)" } ?? "", privacy: .public)")
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor d: CBDescriptor, error: Error?) {
        if let error { bleLog.notice("descriptor write failed: \(error.localizedDescription, privacy: .public)") }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        notifyCounts[c.uuid.uuidString, default: 0] += 1
        let now = Date()
        if now.timeIntervalSince(lastCountLog) > 5 {
            lastCountLog = now
            let imu = c.uuid == Self.input05 && v.count >= 46 ? " imu-ts \(v[42]) \(v[43]) \(v[44]) \(v[45])" : ""
            bleLog.notice("notifications in 5 s: \(self.notifyCounts.map { "\($0.key.prefix(8))=\($0.value)" }.sorted().joined(separator: " "), privacy: .public)\(imu, privacy: .public)")
            notifyCounts.removeAll()
        }
        if c.uuid == inputChar || c.uuid == Self.input05 { reportsSinceSpeed += 1 }
        if c.uuid == inputChar {
            recordTiming()
            onReport?([inputReportID] + [UInt8](v))    // BLE omits the report ID
        } else if c.uuid == Self.input05 {
            recordTiming()
            if v.count >= 46 { imuStamp = Report05.u32([UInt8](v), 42) }
            onReport?([Report05.id] + [UInt8](v))
        } else if c.uuid == Self.commandAck {
            let r = [UInt8](v)
            if r.first == 0x0C {                      // feature replies (flash replies carry the serial: not logged)
                bleLog.notice("reply \(r.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " "), privacy: .public)")
            }
            if let a = awaiting, r.count >= 4, r[0] == a.command, r[3] == a.sub { nextStep() }
            onAck?(r)
        }
    }
}

private extension String {
    /// "0C9101" → ["0C", "91", "01"]
    func chunked2() -> [String] {
        var out: [String] = [], i = startIndex
        while i < endIndex { let j = index(i, offsetBy: 2, limitedBy: endIndex) ?? endIndex; out.append(String(self[i..<j])); i = j }
        return out
    }
}
