import Foundation

/// NSO GameCube Controller (Switch 2 family, 057E:2073, bcdDevice 0x0101). Same USB interfaces and 0x91
/// wake-up as the Pro Controller 2; streams input report 0x0A (~252 Hz, verified) and takes output
/// report 0x03 (a plain on/off motor). Layout from ndeadly `hid_reports.md` (+1 for the USB report ID),
/// corrected on hardware 2026-09-28: Z/R-click and ZL/L-click are swapped in that table.
public enum GameCubeReport {
    public static let inputID: UInt8 = 0x0A
    public static let rumbleID: UInt8 = 0x03
}

/// Buttons in report 0x0A, bytes 3–5 as a little-endian 24-bit word. All 16 verified one at a time on
/// hardware (capture: research/captures/gamecube-usb-buttons.ns2cap). L and R set their bit only at the end of the analog
/// travel (analog ≈ 216 of 255).
public struct GCButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let b       = GCButtons(rawValue: 1 << 0)
    public static let a       = GCButtons(rawValue: 1 << 1)
    public static let y       = GCButtons(rawValue: 1 << 2)
    public static let x       = GCButtons(rawValue: 1 << 3)
    public static let r       = GCButtons(rawValue: 1 << 4)      // R fully pressed (click)
    public static let z       = GCButtons(rawValue: 1 << 5)
    public static let start   = GCButtons(rawValue: 1 << 6)
    public static let down    = GCButtons(rawValue: 1 << 8)
    public static let right   = GCButtons(rawValue: 1 << 9)
    public static let left    = GCButtons(rawValue: 1 << 10)
    public static let up      = GCButtons(rawValue: 1 << 11)
    public static let l       = GCButtons(rawValue: 1 << 12)     // L fully pressed (click)
    public static let zl      = GCButtons(rawValue: 1 << 13)
    public static let home    = GCButtons(rawValue: 1 << 16)
    public static let capture = GCButtons(rawValue: 1 << 17)
    public static let c       = GCButtons(rawValue: 1 << 20)

    public static let named: [(GCButtons, String)] = [
        (.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"), (.z, "Z"), (.zl, "ZL"), (.l, "L"), (.r, "R"),
        (.start, "START"), (.home, "HOME"), (.capture, "CAPTURE"), (.c, "C"),
        (.up, "↑"), (.down, "↓"), (.left, "←"), (.right, "→"),
    ]

    public var names: [String] { GCButtons.named.filter { contains($0.0) }.map(\.1) }
}

/// Parsed report 0x0A.
public struct GCState: Sendable {
    public var counter: UInt8
    public var externalPower: Bool
    public var charging: Bool
    public var batteryLevel: Int            // 0…9, same power byte as the Pro Controller 2
    public var buttons: GCButtons
    public var main: Stick                  // control stick, 12-bit
    public var cStick: Stick
    public var leftTrigger: UInt8           // analog, uncalibrated: rests ≈ 33, full ≈ 220 (measured)
    public var rightTrigger: UInt8

    public init?(report r: [UInt8]) {
        guard r.count >= 15, r[0] == GameCubeReport.inputID else { return nil }
        counter = r[1]
        externalPower = r[2] & 0x01 != 0
        charging = r[2] & 0x02 != 0
        batteryLevel = Int((r[2] >> 2) & 0x0F)
        buttons = GCButtons(rawValue: UInt32(r[3]) | UInt32(r[4]) << 8 | UInt32(r[5]) << 16)
        main = ControllerState.stick(r, 6)
        cStick = ControllerState.stick(r, 9)
        leftTrigger = r[13]
        rightTrigger = r[14]
    }
}

/// Analog trigger → 0…1. Uncalibrated, the resting value differs per controller (SDL reads a factory zero
/// from flash), so the lowest value seen so far is used as zero and the range widens as values arrive.
/// Once the trigger test has measured it, the range is fixed (a full press = the click point = 100%).
public struct TriggerCal: Sendable, Equatable {
    public var zero: UInt8 = 255
    public var full: UInt8 = 200
    public private(set) var fixed = false
    public init() {}
    public init(range: TriggerRange) { zero = range.rest; full = range.full; fixed = true }

    public mutating func normalize(_ v: UInt8) -> Double {
        if !fixed {
            zero = min(zero, v)
            full = max(full, v)
        }
        guard full > zero, v > zero else { return 0 }
        let t = Double(v - zero) / Double(full - zero)
        return t < 0.04 ? 0 : min(1, t)
    }
}

/// Output report 0x03: [0x03, 0x50 | sequence, motor, 0…] where motor 1 = on, 0 = off, 2 = stop (brake).
/// The motor has no strength control, so strength is made by switching it on for a share of frames
/// (error diffusion, as SDL does).
public struct GameCubeRumble: Sendable {
    private var error = 0.0
    public init() {}

    public mutating func report(level: Double, counter: Int) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = GameCubeReport.rumbleID
        r[1] = 0x50 | UInt8(counter & 0x0F)
        let l = max(0, min(1, level))
        if l < 0.01 {
            r[2] = 2
            error = 0
        } else if error < l {
            r[2] = 1
            error += 1 - l
        } else {
            r[2] = 0
            error -= l
        }
        return r
    }
}

extension HapticsEngine {
    /// NSO GameCube controller: output report 0x03 every 4 ms, strength by duty cycle.
    public static func gameCube(send: @escaping ([UInt8]) -> Void) -> HapticsEngine {
        let lock = NSLock()
        var motor = GameCubeRumble()
        return HapticsEngine(interval: .milliseconds(4), send: send) { l, r, counter, _ in
            lock.withLock { motor.report(level: max(l.peak, r.peak), counter: counter) }
        }
    }
}

extension SDLMapping {
    /// CRC and firmware version zeroed: SDL (2.26+ and 3) falls back to these when no mapping matches the
    /// exact GUID, so they keep working with other firmware versions.
    public static let proAnyFirmwareGUID = "030000007e0500006920000000000000"
    public static let gameCubeGUID = "030000007e0500007320000000000000"

    /// The NSO GameCube controller through SDL's generic (IOKit) backend: HID button n = bit n of bytes
    /// 3–5 (Z b5, ZL b13, L click b12, R click b4). Report 0x0A has the same HID
    /// layout as the Pro's 0x09: 21 buttons, then four 12-bit axes. Analog trigger travel isn't in the
    /// HID description, so games see L and R as full-press buttons.
    public static func gameCubeLine(layout: Layout = .positions) -> String {
        let face = layout == .positions
            ? ["a:b1", "b:b3", "x:b0", "y:b2"]     // by position (Dolphin's default): A south, X east, B west, Y north
            : ["a:b1", "b:b0", "x:b3", "y:b2"]     // by label
        return ([gameCubeGUID, "Nintendo GameCube Controller"] + face + [
            "rightshoulder:b5", "leftshoulder:b13", "righttrigger:b4", "lefttrigger:b12",
            "start:b6", "back:b20", "guide:b16", "misc1:b17",
            "dpdown:b8", "dpright:b9", "dpleft:b10", "dpup:b11",
            "leftx:a0", "lefty:a1~", "rightx:a2", "righty:a3~",
            "platform:Mac OS X"]).joined(separator: ",") + ","
    }

    /// Everything NS2 Bridge hands to SDL, one mapping per line: the Pro Controller 2 (exact GUID, plus
    /// a firmware-independent copy) and the GameCube controller.
    public static func allLines(layout: Layout = .positions) -> String {
        [line(layout: layout), line(guid: proAnyFirmwareGUID, layout: layout), gameCubeLine(layout: layout)]
            .joined(separator: "\n")
    }
}
