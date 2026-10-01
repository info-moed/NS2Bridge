import Foundation

// MARK: - Motion sample

/// One IMU sample in SDL's sensor frame (the frame SDL, Dolphin and most engines use):
/// +X right, +Y up out of the controller's face when it lies flat, +Z toward the player.
/// Accelerometer in g (flat on a table reads about (0, +1, 0)); gyro in °/s, right-hand rule
/// (x = pitch, y = yaw, z = roll).
public struct MotionSample: Sendable, Equatable {
    public var timestampMicros: UInt64      // controller clock, extended past 32-bit wrap
    public var accel: SIMD3<Double>
    public var gyro: SIMD3<Double>
    public var temperatureC: Double

    public init(timestampMicros: UInt64, accel: SIMD3<Double>, gyro: SIMD3<Double>, temperatureC: Double) {
        self.timestampMicros = timestampMicros; self.accel = accel; self.gyro = gyro; self.temperatureC = temperatureC
    }
}

/// Gyro zero-rate offset, measured by holding the controller still (°/s, SDL frame).
public struct GyroBias: Codable, Equatable, Sendable {
    public var x: Double, y: Double, z: Double
    public static let zero = GyroBias(x: 0, y: 0, z: 0)
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    public var vector: SIMD3<Double> { SIMD3(x, y, z) }
}

// MARK: - Report 0x05 (Switch 2 family, "common" format with plain IMU data)

/// Input report 0x05, USB layout (byte 0 = report ID). Offsets from ndeadly `hid_reports.md` (+1 for the
/// ID) and SDL `SDL_hidapi_switch2.c`, which reads the same bytes. Not yet verified on our hardware.
///
///     1–4 counter · 5–8 buttons · 11–16 sticks · 32–33 battery mV · 34 charge state
///     43–46 IMU timestamp · 47–48 temperature · 49–54 accel · 55–60 gyro · 61–62 GameCube triggers
public enum Report05 {
    public static let id: UInt8 = 0x05

    /// 0x05 button bits → the 0x09 bit order `ProButtons` uses.
    /// byte 5: Y X B A SR SL R ZR · byte 6: − + RS LS Home Capture C · byte 7: ↓ ↑ → ← SR SL L ZL · byte 8: GR GL
    public static func proButtons(_ r: [UInt8]) -> ProButtons {
        guard r.count >= 9 else { return [] }
        let table: [(Int, UInt8, ProButtons)] = [
            (5, 0x01, .y), (5, 0x02, .x), (5, 0x04, .b), (5, 0x08, .a), (5, 0x40, .r), (5, 0x80, .zr),
            (6, 0x01, .minus), (6, 0x02, .plus), (6, 0x04, .rightStick), (6, 0x08, .leftStick),
            (6, 0x10, .home), (6, 0x20, .capture), (6, 0x40, .c),
            (7, 0x01, .dpadDown), (7, 0x02, .dpadUp), (7, 0x04, .dpadRight), (7, 0x08, .dpadLeft),
            (7, 0x40, .l), (7, 0x80, .zl),
            (8, 0x01, .gr), (8, 0x02, .gl),
        ]
        var b: ProButtons = []
        for (byte, mask, button) in table where r[byte] & mask != 0 { b.insert(button) }
        return b
    }

    /// Battery voltage the controller reports in every 0x05 report (mV), if plausible.
    public static func millivolts(_ r: [UInt8]) -> Int? {
        guard r.count >= 34 else { return nil }
        let mv = Int(r[32]) | Int(r[33]) << 8
        return (2500...4600).contains(mv) ? mv : nil
    }

    static func i16(_ r: [UInt8], _ o: Int) -> Double { Double(Int16(bitPattern: UInt16(r[o]) | UInt16(r[o + 1]) << 8)) }
    static func u32(_ r: [UInt8], _ o: Int) -> UInt32 {
        UInt32(r[o]) | UInt32(r[o + 1]) << 8 | UInt32(r[o + 2]) << 16 | UInt32(r[o + 3]) << 24
    }
}

extension ControllerState {
    /// Report 0x05 into the same fields as 0x09. Power flags aren't in 0x05 (only a voltage), so the level
    /// is estimated from millivolts and the flags are left false; the hub carries them over from 0x09.
    init?(report05 r: [UInt8]) {
        guard r.count >= 17, r[0] == Report05.id else { return nil }
        counter = r[1]
        externalPower = false
        charging = false
        millivolts = Report05.millivolts(r)
        batteryLevel = millivolts.map { Int((BatteryCurve.typicalLiPo.percent(millivolts: $0) / 100 * 9).rounded()) } ?? 0
        buttons = Report05.proButtons(r)
        left = ControllerState.stick(r, 11)
        right = ControllerState.stick(r, 14)
        motionLength = 0
        motion = []
    }
}

// MARK: - Decoder

/// Turns report 0x05 IMU bytes into `MotionSample`s. One per controller (it keeps clock state).
///
/// Scales follow SDL: accel ±8 g over int16; gyro full scale 34.8 rad/s (≈ ±1994 °/s, 16.4 LSB per °/s)
/// when the IMU clock runs in microseconds. Some firmware runs the IMU clock at another rate, and SDL
/// then uses 40.0 rad/s; we detect it the same way, but against the Mac's clock (so it also works over
/// Bluetooth, where reports don't arrive every 4 ms).
public final class MotionDecoder {
    public static let accelScale = 8.0 / 32767                 // g per LSB
    static let microsecondGyroRange = 34.8                     // rad/s at int16 max
    static let otherClockGyroRange = 40.0

    public private(set) var gyroRangeRadPerSec = MotionDecoder.microsecondGyroRange
    public private(set) var ticksPerSecond = 1_000_000.0
    public private(set) var clockChecked = false

    private var samples = 0
    private var reference: (ticks: UInt32, host: UInt64)?
    private var lastTicks: UInt32?
    private var wraps: UInt64 = 0

    public init() {}

    public func reset() {
        samples = 0; reference = nil; lastTicks = nil; wraps = 0; clockChecked = false
        gyroRangeRadPerSec = Self.microsecondGyroRange; ticksPerSecond = 1_000_000
    }

    /// `hostNanos`: when the report arrived (defaults to now). Returns nil for reports without IMU data.
    public func decode(_ r: [UInt8], hostNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) -> MotionSample? {
        guard r.count >= 61, r[0] == Report05.id else { return nil }
        let ticks = Report05.u32(r, 43)
        guard ticks != 0 else { return nil }                   // IMU off (feature bit 2 not enabled)
        checkClock(ticks, hostNanos)
        if let last = lastTicks, ticks < last, last - ticks > 0x8000_0000 { wraps += 1 }
        lastTicks = ticks
        let extended = wraps << 32 | UInt64(ticks)

        let a = Self.accelScale
        let g = gyroRangeRadPerSec / 32767 * 180 / .pi
        return MotionSample(
            timestampMicros: UInt64(Double(extended) * 1_000_000 / ticksPerSecond),
            accel: SIMD3(Report05.i16(r, 49) * a, Report05.i16(r, 53) * a, -Report05.i16(r, 51) * a),
            gyro: SIMD3(Report05.i16(r, 55) * g, Report05.i16(r, 59) * g, -Report05.i16(r, 57) * g),
            temperatureC: 25 + Report05.i16(r, 47) / 126.9)
    }

    private func checkClock(_ ticks: UInt32, _ host: UInt64) {
        guard !clockChecked else { return }
        samples += 1
        if samples == 5 { reference = (ticks, host); return }
        guard let ref = reference, host > ref.host, host - ref.host >= 400_000_000, ticks > ref.ticks else { return }
        let rate = Double(ticks - ref.ticks) / (Double(host - ref.host) / 1e9)
        if abs(rate - 1_000_000) <= 100_000 {
            ticksPerSecond = 1_000_000
            gyroRangeRadPerSec = Self.microsecondGyroRange
        } else {
            ticksPerSecond = rate
            gyroRangeRadPerSec = Self.otherClockGyroRange
        }
        clockChecked = true
    }
}

// MARK: - Gyro calibration

/// Averages gyro readings while the controller is held still. Rejects the run if it moved.
public struct GyroCalibrator: Sendable {
    public private(set) var count = 0
    private var sum = SIMD3<Double>(repeating: 0)
    private var sumSq = SIMD3<Double>(repeating: 0)

    public init() {}

    public mutating func add(_ s: MotionSample) {
        count += 1; sum += s.gyro; sumSq += s.gyro * s.gyro
    }

    /// The bias, or nil if there are too few samples or the controller moved (std-dev above ~1.5 °/s).
    public func result(minSamples: Int = 100) -> GyroBias? {
        guard count >= minSamples else { return nil }
        let n = Double(count)
        let mean = sum / n
        let variance = sumSq / n - mean * mean
        guard variance.max() < 1.5 * 1.5 else { return nil }
        return GyroBias(x: mean.x, y: mean.y, z: mean.z)
    }
}
