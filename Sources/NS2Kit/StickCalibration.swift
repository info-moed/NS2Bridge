import Foundation

/// One stick axis: raw 12-bit min / center / max.
public struct AxisCal: Codable, Equatable, Sendable {
    public var min: Double
    public var center: Double
    public var max: Double

    /// Measured on the user's controller: travel ≈ 384…3584 around ≈ 2048.
    public static let `default` = AxisCal(min: 384, center: 2048, max: 3584)

    public init(min: Double, center: Double, max: Double) {
        self.min = min; self.center = center; self.max = max
    }

    /// Raw → -1…1, scaled separately on each side of center.
    public func normalize(_ raw: UInt16) -> Double {
        let v = Double(raw)
        if v >= center { return Swift.min(1, (v - center) / Swift.max(1, max - center)) }
        return Swift.max(-1, (v - center) / Swift.max(1, center - min))
    }
}

/// Per-stick calibration with a radial inner deadzone.
public struct StickCalibration: Codable, Equatable, Sendable {
    public var x: AxisCal
    public var y: AxisCal
    public var deadzone: Double    // 0…0.3 of full travel

    public static let `default` = StickCalibration(x: .default, y: .default, deadzone: 0.06)

    public init(x: AxisCal, y: AxisCal, deadzone: Double) {
        self.x = x; self.y = y; self.deadzone = deadzone
    }

    /// Raw stick → calibrated, for a stick with an octagonal gate (N64): the diagonals keep their
    /// real reach (~0.81 on each axis) instead of being squashed onto a circle; each axis clamps to ±1.
    public func apply(_ s: Stick, octagonal: Bool) -> (x: Double, y: Double) {
        guard octagonal else { return apply(s) }
        let nx = x.normalize(s.x), ny = y.normalize(s.y)
        let mag = (nx * nx + ny * ny).squareRoot()
        guard mag > deadzone, mag > 0 else { return (0, 0) }
        let k = ((mag - deadzone) / (1 - deadzone)) / mag
        return (Swift.max(-1, Swift.min(1, nx * k)), Swift.max(-1, Swift.min(1, ny * k)))
    }

    /// Raw stick → calibrated (-1…1, -1…1). +y = up.
    public func apply(_ s: Stick) -> (x: Double, y: Double) {
        var nx = x.normalize(s.x), ny = y.normalize(s.y)
        let mag = (nx * nx + ny * ny).squareRoot()
        guard mag > deadzone, mag > 0 else { return (0, 0) }
        let k = Swift.min(1, (mag - deadzone) / (1 - deadzone)) / mag
        nx *= k; ny *= k
        return (nx, ny)
    }
}

/// Collects samples for a two-step calibration: center (sticks released) then range (full circles).
public struct CalibrationRecorder: Sendable {
    public private(set) var centerSamples: [(UInt16, UInt16)] = []
    public private(set) var minX = UInt16.max, maxX = UInt16.min
    public private(set) var minY = UInt16.max, maxY = UInt16.min

    public init() {}

    public mutating func addCenter(_ s: Stick) { centerSamples.append((s.x, s.y)) }

    public mutating func addRange(_ s: Stick) {
        minX = Swift.min(minX, s.x); maxX = Swift.max(maxX, s.x)
        minY = Swift.min(minY, s.y); maxY = Swift.max(maxY, s.y)
    }

    public var center: (x: Double, y: Double)? {
        guard !centerSamples.isEmpty else { return nil }
        let n = Double(centerSamples.count)
        return (centerSamples.map { Double($0.0) }.reduce(0, +) / n,
                centerSamples.map { Double($0.1) }.reduce(0, +) / n)
    }

    /// Travel must cover at least ~1/4 of the 12-bit range each side of center to be trusted.
    public var rangeIsGood: Bool {
        guard let c = center, maxX > minX, maxY > minY else { return false }
        let need = 700.0
        return Double(maxX) - c.x > need && c.x - Double(minX) > need
            && Double(maxY) - c.y > need && c.y - Double(minY) > need
    }

    /// Final calibration; a small inset keeps full tilt reachable despite noise at the rim.
    public func result(deadzone: Double) -> StickCalibration? {
        guard let c = center, rangeIsGood else { return nil }
        let inset = 0.97
        func axis(_ lo: UInt16, _ mid: Double, _ hi: UInt16) -> AxisCal {
            AxisCal(min: mid - (mid - Double(lo)) * inset, center: mid, max: mid + (Double(hi) - mid) * inset)
        }
        return StickCalibration(x: axis(minX, c.x, maxX), y: axis(minY, c.y, maxY), deadzone: deadzone)
    }
}

/// Stick calibration for NS2 Bridge's game helper, in SDL gamepad units.
///
/// SDL's generic IOKit backend maps the HID range 0…4095 linearly to −32768…32767, but the sticks only
/// travel part of it (GameCube ≈ 60%, Pro ≈ 80%), so a full tilt never reads full in games. The helper
/// rescales with these numbers. Y axes are inverted by the SDL mapping (`a1~`: up is negative in SDL).
public enum GameStickCalibration {
    /// SDL's IOKit scaling of a raw 12-bit value.
    static func joystick(_ raw: Double) -> Double { raw * 65535 / 4095 - 32768 }

    /// "center,neg,pos" per axis for left X, left Y, right X, right Y (missing sticks: unscaled).
    public static func envValue(_ sticks: [StickCalibration]) -> String {
        var fields: [Int] = []
        for i in 0..<2 {
            guard i < sticks.count else { fields += [0, 32768, 32767, 0, 32768, 32767]; continue }
            let s = sticks[i]
            let xc = joystick(s.x.center), yc = joystick(s.y.center)
            fields += [Int(xc.rounded()), Int((xc - joystick(s.x.min)).rounded()), Int((joystick(s.x.max) - xc).rounded())]
            // Inverted: SDL value = −joystick; pushing up (raw max) goes negative.
            fields += [Int((-yc).rounded()), Int((joystick(s.y.max) - yc).rounded()), Int((yc - joystick(s.y.min)).rounded())]
        }
        return fields.map(String.init).joined(separator: ",")
    }

    /// Environment key the helper reads for a product.
    public static func envKey(productID: Int) -> String { String(format: "NS2_STICKCAL_%04X", productID) }
}
