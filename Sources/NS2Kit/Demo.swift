import Foundation
import simd

/// Demo mode and documentation screenshots: recorded controllers (`.ns2cap` captures, input reports only)
/// replayed through the hub as if they were connected, so every tab shows real data without hardware.
public struct DemoClip: Sendable {
    public var kind: ControllerKind
    public var reports: [(ms: UInt32, bytes: [UInt8])]

    public init(kind: ControllerKind, reports: [(ms: UInt32, bytes: [UInt8])]) { self.kind = kind; self.reports = reports }

    /// The clips bundled with the app (Resources/Demo/*.ns2cap), or from a folder of captures.
    public static func load(from folder: URL) -> [DemoClip] {
        [("pro2-usb-buttons.ns2cap", ControllerKind.switch2Pro), ("gamecube-usb-buttons.ns2cap", .gameCube)].compactMap { name, kind in
            guard let r = try? CaptureWriter.read(url: folder.appendingPathComponent(name)), !r.isEmpty else { return nil }
            return DemoClip(kind: kind, reports: r)
        }
    }
}

/// A slow, smooth rotation for the demo Pro's motion: pitch ±25° every 6 s, roll ±15° every 4 s.
public enum DemoMotion {
    static func orientation(_ t: Double) -> simd_quatd {
        let pitch = 25 * Double.pi / 180 * sin(2 * .pi * t / 6)
        let roll = 15 * Double.pi / 180 * sin(2 * .pi * t / 4)
        return simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0)) * simd_quatd(angle: roll, axis: SIMD3(0, 0, 1))
    }

    /// Accelerometer (g) and gyro (°/s) in the SDL frame at time `t` seconds, consistent with each other:
    /// gravity seen from the rotated controller, and the rotation rate between `t` and `t + dt`.
    public static func sample(at t: Double) -> (accel: SIMD3<Double>, gyro: SIMD3<Double>) {
        let q = orientation(t), dt = 0.001
        let step = q.inverse * orientation(t + dt)
        let gyro = step.angle > 0 ? step.axis * (step.angle / dt) * 180 / .pi : .zero
        return (q.inverse.act(SIMD3(0, 1, 0)), gyro)
    }
}

extension Report05 {
    /// Report 0x05 (USB layout) carrying a 0x09 report's buttons, sticks and battery plus the given motion:
    /// the inverse of `ControllerState(report05:)` and `MotionDecoder.decode` (microsecond IMU clock).
    public static func make(from r09: [UInt8], accel: SIMD3<Double>, gyro: SIMD3<Double>, micros: UInt32) -> [UInt8]? {
        guard let s = ControllerState(report: r09), r09[0] == ControllerState.reportID else { return nil }
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = id
        r[1] = s.counter
        let table: [(Int, UInt8, ProButtons)] = [
            (5, 0x01, .y), (5, 0x02, .x), (5, 0x04, .b), (5, 0x08, .a), (5, 0x40, .r), (5, 0x80, .zr),
            (6, 0x01, .minus), (6, 0x02, .plus), (6, 0x04, .rightStick), (6, 0x08, .leftStick),
            (6, 0x10, .home), (6, 0x20, .capture), (6, 0x40, .c),
            (7, 0x01, .dpadDown), (7, 0x02, .dpadUp), (7, 0x04, .dpadRight), (7, 0x08, .dpadLeft),
            (7, 0x40, .l), (7, 0x80, .zl),
            (8, 0x01, .gr), (8, 0x02, .gl),
        ]
        for (byte, mask, button) in table where s.buttons.contains(button) { r[byte] |= mask }
        r[11...13] = r09[6...8]                                         // sticks: same 12-bit packing
        r[14...16] = r09[9...11]
        let mv = UInt16(3500 + 70 * s.batteryLevel)                     // a plausible cell voltage for the level
        r[32] = UInt8(mv & 0xFF); r[33] = UInt8(mv >> 8)
        func put(_ v: Double, _ o: Int) {
            let i = Int16(max(-32768, min(32767, v.rounded())))
            r[o] = UInt8(UInt16(bitPattern: i) & 0xFF); r[o + 1] = UInt8(UInt16(bitPattern: i) >> 8)
        }
        let ts = micros == 0 ? 1 : micros
        r[43] = UInt8(ts & 0xFF); r[44] = UInt8(ts >> 8 & 0xFF); r[45] = UInt8(ts >> 16 & 0xFF); r[46] = UInt8(ts >> 24)
        let a = MotionDecoder.accelScale
        let g = MotionDecoder.microsecondGyroRange / 32767 * 180 / .pi
        put(accel.x / a, 49); put(-accel.z / a, 51); put(accel.y / a, 53)
        put(gyro.x / g, 55); put(-gyro.z / g, 57); put(gyro.y / g, 59)
        return r
    }
}
