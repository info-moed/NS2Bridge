import Foundation
import zlib

/// Cemuhook "DSU" server (UDP 127.0.0.1:26760): motion, buttons and sticks for Dolphin, Cemu, Ryujinx,
/// Citra/Lime3DS, PCSX2 and other emulators that accept a DSU (a.k.a. CemuHook UDP) controller.
///
/// Protocol per Dolphin's `DualShockUDPProto.h` (itself from DS4Windows' UdpServer.cs): 16-byte header
/// ("DSUS", version 1001, length, CRC32, server id), then a u32 message type and its payload. Clients
/// ask for version (0x100000), port info (0x100001) and pad data (0x100002); pad data is streamed to a
/// client for as long as it keeps re-requesting (every second; we drop it after 5 s of silence).
/// Slots 0–3 are players 1–4.
public final class DSUServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 26760
    static let protocolVersion: UInt16 = 1001
    static let msgVersion: UInt32 = 0x100000
    static let msgPorts: UInt32 = 0x100001
    static let msgPadData: UInt32 = 0x100002
    static let clientTimeout: TimeInterval = 5

    /// DualShock-shaped controller state. Buttons are placed by position (south = cross, east = circle…).
    public struct Pad: Sendable, Equatable {
        public var connected = true
        public var hasMotion = false
        public var bluetooth = false
        public var mac: [UInt8] = [0, 0, 0, 0, 0, 0]
        public var battery: UInt8 = 0x05            // 0x01 dying … 0x05 full, 0xEE charging, 0xEF charged
        // Digital
        public var dpadUp = false, dpadDown = false, dpadLeft = false, dpadRight = false
        public var south = false, east = false, west = false, north = false
        public var l1 = false, r1 = false, l2 = false, r2 = false
        public var l3 = false, r3 = false, share = false, options = false, home = false, touch = false
        // Analog: sticks −1…1 (+y = up), triggers 0…1 (nil = use the digital button)
        public var leftStick = SIMD2<Double>(0, 0)
        public var rightStick = SIMD2<Double>(0, 0)
        public var l2Analog: Double?
        public var r2Analog: Double?
        public var motion: MotionSample?
        public init() {}
    }

    /// DSU has four slots. Players 1–4 keep slots 1–4 (index 0–3); players 5 and up take any free slot, in
    /// player order, so a controller is never left out while a slot is empty.
    public static func slots(forPlayers players: [Int]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var used = Set<Int>()
        for p in players where (1...4).contains(p) { map[p] = p - 1; used.insert(p - 1) }
        var free = (0..<4).filter { !used.contains($0) }
        for p in players.filter({ $0 > 4 }).sorted() where !free.isEmpty { map[p] = free.removeFirst() }
        return map
    }

    public private(set) var clientCount = 0
    /// Called on the main queue when the number of listening clients changes.
    public var onClientsChanged: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "ns2.dsu", qos: .userInteractive)
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let serverID = UInt32.random(in: 1...UInt32.max)
    // guarded by lock
    private var pads: [Pad?] = [nil, nil, nil, nil]
    private var packetNumbers = [UInt32](repeating: 0, count: 4)
    private struct Client { var addr: sockaddr_in; var slots: Set<Int>?; var lastSeen: Date }   // nil = all slots
    private var clients: [String: Client] = [:]

    public init() {}

    public var isRunning: Bool { fd >= 0 }

    public func start(port: UInt16 = DSUServer.defaultPort) throws {
        guard fd < 0 else { return }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw NS2Error.open("UDP socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(s); throw NS2Error.open("port \(port) is in use (another DSU server running?)") }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.receive() }
        src.setCancelHandler { close(s) }
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        fd = -1
        lock.withLock { clients.removeAll() }
        publishClientCount()
    }

    /// Slots at least one client is listening to right now (clients that stopped asking expire after 5 s).
    public func listeningSlots() -> Set<Int> {
        lock.withLock {
            let now = Date()
            clients = clients.filter { now.timeIntervalSince($0.value.lastSeen) < Self.clientTimeout }
            return clients.values.reduce(into: Set<Int>()) { $0.formUnion($1.slots ?? [0, 1, 2, 3]) }
        }
    }

    /// Update a slot (0…3) and stream it to every client listening to that slot. Any thread.
    public func update(slot: Int, pad: Pad?) {
        guard (0..<4).contains(slot) else { return }
        let (packet, targets): ([UInt8]?, [sockaddr_in]) = lock.withLock {
            pads[slot] = pad
            guard let pad, pad.connected else { return (nil, []) }
            let now = Date()
            let targets = clients.values.filter { now.timeIntervalSince($0.lastSeen) < Self.clientTimeout && ($0.slots?.contains(slot) ?? true) }
            guard !targets.isEmpty else { return (nil, []) }
            packetNumbers[slot] &+= 1
            return (Self.message(Self.msgPadData, Self.padData(slot: slot, pad: pad, number: packetNumbers[slot]), serverID: serverID),
                    targets.map(\.addr))
        }
        guard let packet else { return }
        for a in targets { send(packet, to: a) }
    }

    // MARK: Requests

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 128)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n >= 20, buf[0..<4] == [0x44, 0x53, 0x55, 0x43][...] else { return }       // "DSUC"
        let msg = Array(buf[0..<n])
        guard Self.checkCRC(msg) else { return }
        let type = Self.u32(msg, 16)
        switch type {
        case Self.msgVersion:
            send(Self.message(Self.msgVersion, Self.le16(Self.protocolVersion) + [0, 0], serverID: serverID), to: from)
        case Self.msgPorts where n >= 24:
            let count = min(4, Int(Self.u32(msg, 20)))
            let requested = (0..<count).compactMap { 24 + $0 < n ? Int(msg[24 + $0]) : nil }
            let snapshot = lock.withLock { pads }
            for slot in requested where (0..<4).contains(slot) {
                send(Self.message(Self.msgPorts, Self.portInfo(slot: slot, pad: snapshot[slot]) + [0], serverID: serverID), to: from)
            }
        case Self.msgPadData where n >= 28:
            // flags: 0 = all pads, 1 = by slot, 2 = by MAC (treated as all)
            let flags = msg[20], slot = Int(msg[21])
            let key = "\(from.sin_addr.s_addr):\(from.sin_port)"
            lock.withLock {
                var c = clients[key] ?? Client(addr: from, slots: [], lastSeen: Date())
                if flags == 1 {
                    if c.slots != nil { c.slots!.insert(slot) }
                } else {
                    c.slots = nil
                }
                c.lastSeen = Date()
                clients[key] = c
                clients = clients.filter { Date().timeIntervalSince($0.value.lastSeen) < Self.clientTimeout }
            }
            publishClientCount()
        default:
            break
        }
    }

    private func publishClientCount() {
        let n = lock.withLock { clients.count }
        DispatchQueue.main.async { [self] in
            guard n != clientCount else { return }
            clientCount = n
            onClientsChanged?(n)
        }
    }

    private func send(_ packet: [UInt8], to addr: sockaddr_in) {
        var a = addr
        _ = packet.withUnsafeBytes { p in
            withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, p.baseAddress, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: Encoding (internal for tests)

    static func message(_ type: UInt32, _ payload: [UInt8], serverID: UInt32) -> [UInt8] {
        let body = le32(type) + payload
        var p = Array("DSUS".utf8) + le16(protocolVersion) + le16(UInt16(body.count)) + le32(0) + le32(serverID) + body
        let crc = p.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
        p.replaceSubrange(8..<12, with: le32(crc))
        return p
    }

    static func checkCRC(_ m: [UInt8]) -> Bool {
        var z = m
        let got = u32(m, 8)
        z.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        return z.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) } == got
    }

    /// Slot, state, model, connection, MAC, battery (11 bytes; shared by port info and pad data).
    static func portInfo(slot: Int, pad: Pad?) -> [UInt8] {
        guard let pad, pad.connected else { return [UInt8(slot), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] }
        return [UInt8(slot), 0x02, pad.hasMotion ? 0x02 : 0x00, pad.bluetooth ? 0x02 : 0x01]
            + pad.mac.prefix(6) + [pad.battery]
    }

    static func padData(slot: Int, pad p: Pad, number: UInt32) -> [UInt8] {
        func bit(_ on: Bool, _ v: UInt8) -> UInt8 { on ? v : 0 }
        func analog(_ on: Bool) -> UInt8 { on ? 255 : 0 }
        func axis(_ v: Double) -> UInt8 { UInt8(max(0, min(255, ((v + 1) * 127.5).rounded()))) }
        let buttons1 = bit(p.share, 0x01) | bit(p.l3, 0x02) | bit(p.r3, 0x04) | bit(p.options, 0x08)
            | bit(p.dpadUp, 0x10) | bit(p.dpadRight, 0x20) | bit(p.dpadDown, 0x40) | bit(p.dpadLeft, 0x80)
        let l2 = p.l2Analog.map { $0 > 0.5 } ?? p.l2, r2 = p.r2Analog.map { $0 > 0.5 } ?? p.r2
        let buttons2 = bit(l2, 0x01) | bit(r2, 0x02) | bit(p.l1, 0x04) | bit(p.r1, 0x08)
            | bit(p.north, 0x10) | bit(p.east, 0x20) | bit(p.south, 0x40) | bit(p.west, 0x80)
        var b = portInfo(slot: slot, pad: p)
        b += [1] + le32(number) + [buttons1, buttons2, p.home ? 1 : 0, p.touch ? 1 : 0]
        b += [axis(p.leftStick.x), axis(p.leftStick.y), axis(p.rightStick.x), axis(p.rightStick.y)]
        b += [analog(p.dpadLeft), analog(p.dpadDown), analog(p.dpadRight), analog(p.dpadUp),
              analog(p.west), analog(p.south), analog(p.east), analog(p.north),
              analog(p.r1), analog(p.l1),
              p.r2Analog.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) } ?? analog(p.r2),
              p.l2Analog.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) } ?? analog(p.l2)]
        b += [UInt8](repeating: 0, count: 12)                                  // two touch points
        if let m = p.motion {
            // SDL frame → DualShock/DSU frame (derived from Dolphin, which maps both into one frame):
            // accel is reported with the opposite sign; pitch as-is; yaw and roll negated.
            b += le64(m.timestampMicros)
            b += [-m.accel.x, -m.accel.y, -m.accel.z, m.gyro.x, -m.gyro.y, -m.gyro.z].flatMap { leFloat(Float($0)) }
        } else {
            b += le64(0) + [UInt8](repeating: 0, count: 24)
        }
        return b
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    static func leFloat(_ f: Float) -> [UInt8] { le32(f.bitPattern) }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
