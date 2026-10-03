import Foundation

/// One actuator (LRA) target. Each LRA plays two bands at once, like XInput's strong/weak motors:
/// `low` / `high` are strengths 0…1; `lowFreq` / `highFreq` are raw 10-bit pitch codes (Hz mapping undocumented).
public struct HapticLevel: Equatable, Sendable {
    public var low: Double
    public var high: Double
    public var lowFreq: UInt16
    public var highFreq: UInt16

    /// Band pitch codes used by SDL and the Linux hid-nintendo patch (v12).
    public static let defaultLowFreq: UInt16 = 0x112
    public static let defaultHighFreq: UInt16 = 0x187
    public static let off = HapticLevel(low: 0, high: 0)

    public init(low: Double, high: Double, lowFreq: UInt16 = defaultLowFreq, highFreq: UInt16 = defaultHighFreq) {
        self.low = max(0, min(1, low)); self.high = max(0, min(1, high))
        self.lowFreq = lowFreq & 0x3FF; self.highFreq = highFreq & 0x3FF
    }

    /// Both bands at the same strength.
    public init(_ amplitude: Double) { self.init(low: amplitude, high: amplitude) }

    public var peak: Double { max(low, high) }

    func scaled(_ k: Double) -> HapticLevel {
        HapticLevel(low: low * k, high: high * k, lowFreq: lowFreq, highFreq: highFreq)
    }
}

/// Converts a level into the 5-byte HD Rumble 2 payload for one actuator.
public protocol HapticEncoder: Sendable {
    func encode(_ level: HapticLevel) -> [UInt8]
}

/// HD Rumble 2 payload: four 10-bit fields packed into 5 bytes —
/// hi_freq | hi_amp | lo_freq | lo_amp (LSB-first). Source: SDL EncodeHDRumble + Linux hid-nintendo v12.
public struct HDRumble2Encoder: HapticEncoder {
    /// Amplitude ceiling (of 1023). The kernel patch caps at 450: higher levels may damage the controller.
    public static let maxAmplitude: Double = 450
    public init() {}

    public func encode(_ l: HapticLevel) -> [UInt8] {
        Self.pack(hiFreq: l.highFreq, hiAmp: UInt16((l.high * Self.maxAmplitude).rounded()),
                  loFreq: l.lowFreq, loAmp: UInt16((l.low * Self.maxAmplitude).rounded()))
    }

    public static func pack(hiFreq: UInt16, hiAmp: UInt16, loFreq: UInt16, loAmp: UInt16) -> [UInt8] {
        let hf = hiFreq & 0x3FF, ha = hiAmp & 0x3FF, lf = loFreq & 0x3FF, la = loAmp & 0x3FF
        return [
            UInt8(hf & 0xFF),
            UInt8((hf >> 8) & 0x03) | UInt8((ha << 2) & 0xFC),
            UInt8((ha >> 6) & 0x0F) | UInt8((lf << 4) & 0xF0),
            UInt8((lf >> 4) & 0x3F) | UInt8((la << 6) & 0xC0),
            UInt8((la >> 2) & 0xFF),
        ]
    }

    public static func unpack(_ b: [UInt8]) -> (hiFreq: UInt16, hiAmp: UInt16, loFreq: UInt16, loAmp: UInt16) {
        let v = (0..<5).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) }
        return (UInt16(v & 0x3FF), UInt16((v >> 10) & 0x3FF), UInt16((v >> 20) & 0x3FF), UInt16((v >> 30) & 0x3FF))
    }
}

/// A timed effect: a list of (left, right, seconds) steps.
public struct HapticEffect: Sendable {
    public var steps: [(left: HapticLevel, right: HapticLevel, seconds: Double)]
    public init(_ steps: [(left: HapticLevel, right: HapticLevel, seconds: Double)]) { self.steps = steps }

    public static func both(_ a: Double, _ s: Double) -> (HapticLevel, HapticLevel, Double) {
        (HapticLevel(a), HapticLevel(a), s)
    }

    public static let tap = HapticEffect([both(0.9, 0.04)])
    public static let buzz = HapticEffect([both(0.6, 0.4)])
    public static let heartbeat = HapticEffect([both(0.9, 0.08), both(0, 0.12), both(0.6, 0.08), both(0, 0.5)])
    public static let ramp = HapticEffect((0..<20).map { both(Double($0 + 1) / 20, 0.05) })
    public static let leftOnly = HapticEffect([(HapticLevel(0.8), .off, 0.5)])
    /// Low band only (deep rumble) vs high band only (sharp buzz), both motors.
    public static let lowBand = HapticEffect([(HapticLevel(low: 0.9, high: 0), HapticLevel(low: 0.9, high: 0), 0.5)])
    public static let highBand = HapticEffect([(HapticLevel(low: 0, high: 0.9), HapticLevel(low: 0, high: 0.9), 0.5)])
    public static let rightOnly = HapticEffect([(.off, HapticLevel(0.8), 0.5)])
}

/// 250 Hz haptics sender. Continuous level (e.g. game rumble) and one-shot effects mix by taking the max.
/// Goes quiet on its own: after everything returns to zero it sends a few neutral frames, then stops ticking.
public final class HapticsEngine: @unchecked Sendable {
    public var encoder: HapticEncoder = HDRumble2Encoder()
    /// Master strength 0…1, applied to everything.
    public var intensity: Double {
        get { lock.withLock { _intensity } }
        set { lock.withLock { _intensity = max(0, min(1, newValue)) }; wake() }
    }
    public var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue }; wake() }
    }

    private let send: ([UInt8]) -> Void
    private let buildReport: (_ left: HapticLevel, _ right: HapticLevel, _ counter: Int, _ encoder: HapticEncoder) -> [UInt8]
    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "ns2.haptics", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var counter = 0
    private var neutralFramesLeft = 0

    // guarded by lock
    private var _intensity = 1.0
    private var _enabled = true
    private var continuous = (HapticLevel.off, HapticLevel.off)
    private var effect: HapticEffect?
    private var effectStep = 0
    private var effectStepEnds: TimeInterval = 0

    /// HD Rumble 2 (Switch 2 family): `send` receives 64-byte output reports 0x02 every 4 ms.
    public convenience init(send: @escaping ([UInt8]) -> Void) {
        self.init(interval: .milliseconds(4), send: send) { l, r, counter, enc in
            Rumble.report(left: enc.encode(l), right: enc.encode(r), counter: counter)
        }
    }

    /// Any controller: `buildReport` turns the current levels into one output report.
    /// Called on a background queue, every `interval` while something is playing.
    public init(interval: DispatchTimeInterval,
                send: @escaping ([UInt8]) -> Void,
                buildReport: @escaping (_ left: HapticLevel, _ right: HapticLevel, _ counter: Int, _ encoder: HapticEncoder) -> [UInt8]) {
        self.interval = interval
        self.send = send
        self.buildReport = buildReport
    }

    /// Original-Switch rumble (NSO N64 and other Switch 1 controllers): report 0x10 every 15 ms.
    public static func switch1(send: @escaping ([UInt8]) -> Void) -> HapticsEngine {
        HapticsEngine(interval: .milliseconds(15), send: send) { l, r, counter, _ in
            Switch1Rumble.report(left: Switch1Rumble.encode(high: l.high, low: l.low),
                                 right: Switch1Rumble.encode(high: r.high, low: r.low), counter: counter)
        }
    }

    /// Continuous rumble, e.g. from a game's motor values. Pass `.off` to stop.
    public func setContinuous(left: HapticLevel, right: HapticLevel) {
        lock.withLock { continuous = (left, right) }
        wake()
    }

    public func play(_ e: HapticEffect) {
        lock.withLock {
            effect = e; effectStep = 0
            effectStepEnds = ProcessInfo.processInfo.systemUptime + (e.steps.first?.seconds ?? 0)
        }
        wake()
    }

    public func stopAll() {
        lock.withLock { continuous = (.off, .off); effect = nil }
        wake()
    }

    private func wake() {
        queue.async { [self] in
            neutralFramesLeft = 4
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    private func currentLevels() -> (HapticLevel, HapticLevel) {
        lock.withLock {
            guard _enabled else { return (.off, .off) }
            var l = continuous.0, r = continuous.1
            if let e = effect {
                let now = ProcessInfo.processInfo.systemUptime
                while effectStep < e.steps.count, now >= effectStepEnds {
                    effectStep += 1
                    if effectStep < e.steps.count { effectStepEnds += e.steps[effectStep].seconds }
                }
                if effectStep >= e.steps.count {
                    effect = nil
                } else {
                    let s = e.steps[effectStep]
                    if s.left.peak > l.peak { l = s.left }
                    if s.right.peak > r.peak { r = s.right }
                }
            }
            return (l.scaled(_intensity), r.scaled(_intensity))
        }
    }

    private func tick() {
        let (l, r) = currentLevels()
        let active = l.peak > 0.01 || r.peak > 0.01
        if !active {
            if neutralFramesLeft <= 0 { timer?.cancel(); timer = nil; return }
            neutralFramesLeft -= 1
        } else {
            neutralFramesLeft = 4
        }
        send(buildReport(l, r, counter, encoder))
        counter &+= 1
    }
}
