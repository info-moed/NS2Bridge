import Foundation

/// Receives rumble requests from games running with ns2rumble.dylib (UDP 127.0.0.1:26761)
/// and hands them to `onRumble` (the hub routes each one to the right controller).
public final class GameRumbleServer: @unchecked Sendable {
    public static let port: UInt16 = 26761

    public struct Event: Sendable {
        public var low: Double       // 0…1 (SDL low_frequency_rumble)
        public var high: Double      // 0…1 (SDL high_frequency_rumble)
        public var durationMs: UInt32
        public var productID: Int      // 0 if the helper is older than the product-ID field
        public var deviceID: UInt64 = 0 // IORegistry entry ID of the device, if the sender knows it
        public var rank: Int = -1       // position among the game's controllers of this kind, -1 = unknown
    }


    /// Called on the listener's own high-priority queue for every rumble request (not the main thread).
    public var onRumble: ((Event) -> Void)?
    /// Called on the main queue.
    public var onHello: ((_ pid: Int32, _ sdlMajor: Int) -> Void)?
    /// A game opened a Nintendo controller: which SDL driver it got. Called on the main queue.
    public var onDriver: ((DriverReport) -> Void)?

    public struct DriverReport: Sendable, Equatable {
        public var pid: Int32
        public var productID: Int
        public var driver: UInt8          // SDL GUID byte 14: 'h' = SDL's HIDAPI driver, 0 = IOKit
        public var sdlMajor: Int
        public var usesSDLDriver: Bool { driver == UInt8(ascii: "h") }
        /// The NSO N64 controller reads garbage without SDL's own driver.
        public var isProblem: Bool { productID == ClassicDevice.n64 && !usesSDLDriver }
    }
    public var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "ns2.game-rumble", qos: .userInteractive)
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public init() {}

    public func start() throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw NS2Error.open("UDP socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(fd); fd = -1; throw NS2Error.open("port \(Self.port) is in use") }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.receive() }
        source = src
        src.resume()
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 64)
        let n = recv(fd, &buf, buf.count, 0)
        guard n >= 8 else { return }
        let magic = String(bytes: buf[0..<4], encoding: .ascii)
        func u16(_ o: Int) -> UInt16 { UInt16(buf[o]) | UInt16(buf[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(buf[o]) | UInt32(buf[o + 1]) << 8 | UInt32(buf[o + 2]) << 16 | UInt32(buf[o + 3]) << 24 }

        if magic == "NS2B", n >= 12 {
            let r = DriverReport(pid: Int32(bitPattern: u32(4)), productID: Int(u16(8)), driver: buf[10], sdlMajor: Int(buf[11]))
            DispatchQueue.main.async { self.onDriver?(r) }
        } else if magic == "NS2H" {
            let pid = Int32(bitPattern: u32(4))
            let sdl = n >= 9 ? Int(buf[8]) : 2
            DispatchQueue.main.async { self.onHello?(pid, sdl) }
        } else if magic == "NS2R", n >= 12 {
            let e = Event(low: Double(u16(4)) / 65535, high: Double(u16(6)) / 65535, durationMs: u32(8),
                          productID: n >= 14 ? Int(u16(12)) : 0,
                          deviceID: n >= 22 ? UInt64(u32(14)) | UInt64(u32(18)) << 32 : 0,
                          rank: n >= 23 && buf[22] != 0xFF ? Int(buf[22]) : -1)
            onRumble?(e)                                         // straight to the controller
            DispatchQueue.main.async { self.onEvent?(e) }        // UI bookkeeping only
        }
    }
}
