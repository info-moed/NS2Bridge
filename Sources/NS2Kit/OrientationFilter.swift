import Foundation
import simd

/// Estimates the controller's orientation from gyro + accelerometer samples (SDL sensor frame:
/// +X right, +Y up out of the face when flat, +Z toward the player), for the live 3D view.
///
/// Mahony-style complementary filter: the gyro is integrated for smooth, fast rotation; the accelerometer's
/// gravity direction slowly pulls tilt (pitch and roll) back to the truth, so it doesn't drift. Turning
/// around the vertical axis (yaw) has no reference without a compass, so it drifts slowly; `reset()`
/// re-centers it. The result maps the controller's frame into the world (world +Y = up).
public struct OrientationFilter: Sendable {
    public private(set) var orientation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    /// How strongly the accelerometer corrects tilt (per second). Higher = less drift, more jitter.
    public var gain = 2.0
    private var lastMicros: UInt64?

    public init() {}

    /// Level the controller to what the accelerometer says, with yaw set to "facing forward".
    public mutating func reset(accel: SIMD3<Double>? = nil) {
        orientation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        if let a = accel, simd_length(a) > 0.5 {
            // Rotate the measured up (device frame) onto world up.
            orientation = simd_quatd(from: simd_normalize(a), to: SIMD3(0, 1, 0))
        }
        lastMicros = nil
    }

    public mutating func update(_ m: MotionSample) {
        defer { lastMicros = m.timestampMicros }
        guard let last = lastMicros, m.timestampMicros > last else {
            if lastMicros == nil { reset(accel: m.accel) }
            return
        }
        let dt = min(0.05, Double(m.timestampMicros - last) / 1e6)       // ignore gaps (reconnects)
        var omega = m.gyro * (.pi / 180)                                    // °/s → rad/s, device frame
        // Accelerometer correction: only when it's measuring mostly gravity (not being shaken).
        let g = simd_length(m.accel)
        if g > 0.8, g < 1.2 {
            let measuredUp = m.accel / g
            let predictedUp = orientation.inverse.act(SIMD3(0, 1, 0))      // world up, seen from the device
            omega += gain * simd_cross(measuredUp, predictedUp)
        }
        // q̇ = ½ q ⊗ ω  (body-frame angular velocity)
        let w = simd_quatd(ix: omega.x, iy: omega.y, iz: omega.z, r: 0)
        let dq = orientation * w
        orientation = simd_normalize(simd_quatd(vector: orientation.vector + dq.vector * (0.5 * dt)))
    }

    /// Tilt in degrees: pitch (top edge up = positive) and roll (right grip down = positive), from the
    /// controller's up axis in the world. 0, 0 = flat and level.
    public var tilt: (pitch: Double, roll: Double) {
        let up = orientation.act(SIMD3(0, 1, 0))               // the controller's face normal, in world
        let pitch = atan2(up.z, up.y) * 180 / .pi                  // top edge up tips the face toward the player (+Z)
        let roll = atan2(up.x, sqrt(up.y * up.y + up.z * up.z)) * 180 / .pi   // right grip down tips it to +X
        return (pitch, roll)
    }
}
