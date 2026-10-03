import Foundation

/// A Bluetooth controller as NS2 Bridge's game helper presents it inside a game: an SDL virtual gamepad
/// (games can't see Switch 2 controllers over Bluetooth on their own; NS2 Bridge holds the connection).
/// Sent to every running helper at the controller's report rate; the helper attaches a gamepad per slot
/// and detaches it when updates stop.
///
/// Packet (little-endian): "NS2V" u8 version (1) u8 count, then per gamepad 52 bytes:
///   u8 slot · u8 flags (bit 0: motion valid) · u16 product ID · u32 SDL gamepad buttons (bit n = SDL button n)
///   · i16 × 6 SDL axes (leftx, lefty, rightx, righty, left trigger, right trigger; triggers −32768 at rest)
///   · f32 × 3 accelerometer (m/s², SDL frame) · f32 × 3 gyro (rad/s, SDL frame) · u64 sensor time (µs)
public struct VirtualGamepad: Equatable, Sendable {
    public var slot: UInt8
    public var productID: UInt16
    public var buttons: UInt32 = 0
    public var axes: [Int16] = [0, 0, 0, 0, -32768, -32768]
    public var accel: SIMD3<Float>?
    public var gyro: SIMD3<Float> = .zero
    public var sensorMicros: UInt64 = 0

    /// SDL gamepad button numbers (same in SDL2 and SDL3).
    public enum Button: Int {
        case south, east, west, north, back, guide, start, leftStick, rightStick, leftShoulder, rightShoulder
        case dpadUp, dpadDown, dpadLeft, dpadRight, misc1
    }
    public static let buttonCount = 16

    public init(slot: UInt8, productID: UInt16) { self.slot = slot; self.productID = productID }

    /// From the positional pad NS2 Bridge builds for DSU (calibrated sticks, gyro bias removed): `south` is the
    /// bottom face button, as SDL's gamepad A. `layout` .labels puts the button printed "A" on SDL's A instead,
    /// like NS2 Bridge's USB mappings.
    public init(slot: UInt8, kind: ControllerKind, pad: DSUServer.Pad, layout: SDLMapping.Layout) {
        self.init(slot: slot, productID: UInt16(kind.productID))
        var south = pad.south, east = pad.east, west = pad.west, north = pad.north
        if layout == .labels {
            switch kind {
            case .switch2Pro: (south, east, west, north) = (pad.east, pad.south, pad.north, pad.west)   // A, B, X, Y
            case .gameCube: (east, west) = (pad.west, pad.east)                                       // B, X
            case .n64: break
            }
        }
        let held: [(Button, Bool)] = [
            (.south, south), (.east, east), (.west, west), (.north, north),
            (.back, pad.share), (.guide, pad.home), (.start, pad.options), (.leftStick, pad.l3), (.rightStick, pad.r3),
            (.leftShoulder, pad.l1), (.rightShoulder, pad.r1),
            (.dpadUp, pad.dpadUp), (.dpadDown, pad.dpadDown), (.dpadLeft, pad.dpadLeft), (.dpadRight, pad.dpadRight),
            (.misc1, pad.touch),
        ]
        for (b, on) in held where on { buttons |= 1 << UInt32(b.rawValue) }
        func axis(_ v: Double) -> Int16 { Int16(max(-32768, min(32767, (v * 32767).rounded()))) }
        func trigger(_ v: Double) -> Int16 { Int16(max(-32768, min(32767, (v * 65535 - 32768).rounded()))) }
        axes = [axis(pad.leftStick.x), axis(-pad.leftStick.y), axis(pad.rightStick.x), axis(-pad.rightStick.y),
                trigger(pad.l2Analog ?? (pad.l2 ? 1 : 0)), trigger(pad.r2Analog ?? (pad.r2 ? 1 : 0))]
        if let m = pad.motion {
            accel = SIMD3<Float>(m.accel * 9.80665)                     // g → m/s²
            gyro = SIMD3<Float>(m.gyro * (.pi / 180))                    // °/s → rad/s
            sensorMicros = m.timestampMicros
        }
    }

    public static func packet(_ pads: [VirtualGamepad]) -> [UInt8] {
        var p: [UInt8] = Array("NS2V".utf8) + [1, UInt8(min(pads.count, 8))]
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { p += $0 } }
        func put(_ f: Float) { put(f.bitPattern) }
        for g in pads.prefix(8) {
            p += [g.slot, g.accel != nil ? 1 : 0]
            put(g.productID); put(g.buttons)
            for a in g.axes { put(a) }
            let acc = g.accel ?? .zero
            put(acc.x); put(acc.y); put(acc.z); put(g.gyro.x); put(g.gyro.y); put(g.gyro.z)
            put(g.sensorMicros)
        }
        return p
    }
}
