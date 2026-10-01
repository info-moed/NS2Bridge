import Foundation

/// Measures transport timing for whichever link is delivering reports.
/// - interval: gap between consecutive reports on arrival (what the link actually delivers)
/// - drops: gaps in the controller's 8-bit report counter (byte 1)
/// - host delay (USB only): IOKit's report timestamp → our handler, i.e. time spent inside macOS
public final class LatencyMonitor: @unchecked Sendable {
    public enum Link: String, Sendable { case usb = "USB", bluetooth = "Bluetooth" }

    public struct Expectation: Sendable {
        public let intervalMs: Double
        public let acceptableMs: Double
        public let note: String
    }

    /// `bluetoothIntervalMs`: the Bluetooth speed in effect for Switch 2 controllers (BLELink.effectiveSpeed).
    public static func expectation(for link: Link, kind: ControllerKind = .switch2Pro,
                                   bluetoothIntervalMs: Double = 30) -> Expectation {
        switch link {
        case _ where kind == .n64:
            return Expectation(intervalMs: 15.0, acceptableMs: 17.0,
                               note: "The N64 controller produces a full report every 15 ms (66.7 Hz) on USB and Bluetooth alike: the original Switch protocol's fixed rate (measured). macOS polls USB every 8 ms, and polling faster doesn't help because the controller is the limit.")
        case .usb where kind == .gameCube:
            return Expectation(intervalMs: 4.0, acceptableMs: 4.5,
                               note: "Same USB interface as the Pro Controller 2: one report every 4 ms (measured ≈ 252 Hz).")
        case .usb: return Expectation(intervalMs: 4.0, acceptableMs: 4.5,
                                      note: "USB full-speed interrupt endpoint, bInterval 4 → one report every 4 ms (250 Hz).")
        case .bluetooth: return Expectation(intervalMs: bluetoothIntervalMs, acceptableMs: bluetoothIntervalMs * 1.1,
                                            note: "One report per Bluetooth connection event. NS2 Bridge asks macOS for a short interval (Wireless → Speed): 7.5 ms (133 Hz, measured) at Fastest, 15 ms at Fast; macOS's own default is 30 ms. The Switch 2 console uses 5 ms, which this Mac's Bluetooth chip doesn't accept.")
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var link: Link = .usb
        public var samples = 0
        public var rateHz = 0.0
        public var meanMs = 0.0
        public var p50Ms = 0.0
        public var p99Ms = 0.0
        public var maxMs = 0.0
        public var jitterMs = 0.0
        public var dropped = 0
        public var received = 0
        public var hostDelayMs: Double?           // USB only
        /// Report-interval histogram, 2 ms buckets: [0-2), [2-4), … [38-40), ≥40.
        public var histogram = [Int](repeating: 0, count: 21)

        public init(link: Link = .usb) { self.link = link }

        public var dropPercent: Double { received + dropped > 0 ? Double(dropped) * 100 / Double(received + dropped) : 0 }
        /// Added latency from waiting for the next report: average = half an interval, worst = one interval.
        public var addedAverageMs: Double { meanMs / 2 + (hostDelayMs ?? 0) }
        public var addedWorstMs: Double { p99Ms + (hostDelayMs ?? 0) }
    }

    private let lock = NSLock()
    private var link: Link = .usb
    private var lastArrival: UInt64 = 0
    private var lastCounter: UInt8?
    private var gaps: [Double] = []
    private var hostDelays: [Double] = []
    private var dropped = 0
    private var received = 0
    private static let window = 1000   // most recent reports kept for stats

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    public init() {}

    public func reset() {
        lock.withLock {
            lastArrival = 0; lastCounter = nil; gaps.removeAll(); hostDelays.removeAll(); dropped = 0; received = 0
        }
    }

    /// Record one report. `hidTimestamp` is IOKit's mach-absolute timestamp (USB), or nil.
    public func record(_ report: [UInt8], link: Link, hidTimestamp: UInt64? = nil) {
        let now = mach_absolute_time()
        lock.withLock {
            if link != self.link { self.link = link; lastArrival = 0; lastCounter = nil; gaps.removeAll(); hostDelays.removeAll(); dropped = 0; received = 0 }
            if lastArrival != 0 {
                gaps.append(Self.ms(now - lastArrival))
                if gaps.count > Self.window { gaps.removeFirst(gaps.count - Self.window) }
            }
            lastArrival = now
            if let ts = hidTimestamp, ts > 0, ts <= now {
                hostDelays.append(Self.ms(now - ts))
                if hostDelays.count > Self.window { hostDelays.removeFirst(hostDelays.count - Self.window) }
            }
            if report.count > 1 {
                let c = report[1]
                if let last = lastCounter {
                    let step = Int(c &- last)
                    if step > 1 && step < 128 { dropped += step - 1 }
                }
                lastCounter = c
            }
            received += 1
        }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            var s = Snapshot(link: link)
            s.samples = gaps.count
            s.received = received
            s.dropped = dropped
            guard !gaps.isEmpty else { return s }
            let sorted = gaps.sorted()
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            s.meanMs = mean
            s.rateHz = mean > 0 ? 1000 / mean : 0
            s.p50Ms = sorted[sorted.count / 2]
            s.p99Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            s.maxMs = sorted.last ?? 0
            s.jitterMs = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
            for g in gaps { s.histogram[min(20, Int(g / 2))] += 1 }
            if !hostDelays.isEmpty { s.hostDelayMs = hostDelays.reduce(0, +) / Double(hostDelays.count) }
            return s
        }
    }

    static func ms(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }
}
