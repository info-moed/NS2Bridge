import Foundation

/// Nintendo Switch Online "classic" controllers that speak the original Switch (Switch 1) protocol.
/// Verified on hardware: NSO N64 controller over USB (057E:2019) — macOS's own driver already
/// performs the Switch 1 USB handshake, so it streams input report 0x30 at ~100–125 Hz by itself.
public enum ClassicDevice {
    public static let n64 = 0x2019
    public static let names: [Int: String] = [n64: "N64 Controller"]
}

/// NSO N64 controller buttons, decoded from the Pro-Controller-layout bytes 3–5 of report 0x30
/// (N64 button → Switch bit per the Linux hid-nintendo mapping).
public struct N64Buttons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let a       = N64Buttons(rawValue: 1 << 0)
    public static let b       = N64Buttons(rawValue: 1 << 1)
    public static let z       = N64Buttons(rawValue: 1 << 2)
    public static let l       = N64Buttons(rawValue: 1 << 3)
    public static let r       = N64Buttons(rawValue: 1 << 4)
    public static let zr      = N64Buttons(rawValue: 1 << 5)
    public static let start   = N64Buttons(rawValue: 1 << 6)
    public static let cUp     = N64Buttons(rawValue: 1 << 7)
    public static let cDown   = N64Buttons(rawValue: 1 << 8)
    public static let cLeft   = N64Buttons(rawValue: 1 << 9)
    public static let cRight  = N64Buttons(rawValue: 1 << 10)
    public static let up      = N64Buttons(rawValue: 1 << 11)
    public static let down    = N64Buttons(rawValue: 1 << 12)
    public static let left    = N64Buttons(rawValue: 1 << 13)
    public static let right   = N64Buttons(rawValue: 1 << 14)
    public static let home    = N64Buttons(rawValue: 1 << 15)
    public static let capture = N64Buttons(rawValue: 1 << 16)

    public static let named: [(N64Buttons, String)] = [
        (.a, "A"), (.b, "B"), (.z, "Z"), (.l, "L"), (.r, "R"), (.zr, "ZR"), (.start, "START"),
        (.cUp, "C↑"), (.cDown, "C↓"), (.cLeft, "C←"), (.cRight, "C→"),
        (.up, "↑"), (.down, "↓"), (.left, "←"), (.right, "→"), (.home, "HOME"), (.capture, "CAPTURE"),
    ]

    public var names: [String] { N64Buttons.named.filter { contains($0.0) }.map(\.1) }

    /// Switch 1 report 0x30 bytes 3 (right), 4 (shared), 5 (left).
    public init(switchBytes b3: UInt8, _ b4: UInt8, _ b5: UInt8) {
        var v: N64Buttons = []
        if b3 & 0x08 != 0 { v.insert(.a) }        // A
        if b3 & 0x04 != 0 { v.insert(.b) }        // B
        if b3 & 0x01 != 0 { v.insert(.cUp) }      // Y  → C-up
        if b3 & 0x02 != 0 { v.insert(.cLeft) }    // X  → C-left
        if b3 & 0x40 != 0 { v.insert(.r) }        // R
        if b3 & 0x80 != 0 { v.insert(.cDown) }    // ZR → C-down
        if b4 & 0x01 != 0 { v.insert(.cRight) }   // −  → C-right
        if b4 & 0x02 != 0 { v.insert(.start) }    // +  → Start
        if b4 & 0x08 != 0 { v.insert(.zr) }       // left-stick click → ZR
        if b4 & 0x10 != 0 { v.insert(.home) }
        if b4 & 0x20 != 0 { v.insert(.capture) }
        if b5 & 0x01 != 0 { v.insert(.down) }
        if b5 & 0x02 != 0 { v.insert(.up) }
        if b5 & 0x04 != 0 { v.insert(.right) }
        if b5 & 0x08 != 0 { v.insert(.left) }
        if b5 & 0x40 != 0 { v.insert(.l) }        // L
        if b5 & 0x80 != 0 { v.insert(.z) }        // ZL → Z
        self = v
    }
}

/// Parsed Switch 1 full input report 0x30 from an N64 controller.
public struct N64State: Sendable {
    public var timer: UInt8
    public var batteryLevel: Int            // 0…4 (Switch 1 byte 2 high nibble / 2)
    public var charging: Bool
    public var externalPower: Bool          // byte 2 bit 0: powered over USB
    public var buttons: N64Buttons
    public var stick: Stick                 // 12-bit, bytes 6–8

    public init?(report r: [UInt8]) {
        guard r.count >= 12, r[0] == 0x30 else { return nil }
        timer = r[1]
        batteryLevel = Int(r[2] >> 5)
        charging = r[2] & 0x10 != 0
        externalPower = r[2] & 0x01 != 0
        buttons = N64Buttons(switchBytes: r[3], r[4], r[5])
        stick = ControllerState.stick(r, 6)
    }
}

/// Original-Switch HD Rumble: 4 bytes per actuator (high band freq/amp, low band freq/amp).
/// Encoding from dekuNukem/Nintendo_Switch_Reverse_Engineering; the full-strength frame
/// `00 C9 40 72` was verified to vibrate the NSO N64 controller.
public enum Switch1Rumble {
    public static let neutral: [UInt8] = [0x00, 0x01, 0x40, 0x40]

    /// amplitude 0…1 → encoded amplitude index 0…100 (log curve from the reverse-engineering notes).
    static func ampIndex(_ amp: Double) -> Int {
        guard amp > 0 else { return 0 }
        let a = min(1, amp)
        let v = a > 0.23 ? log2(a * 8.7) * 32 : (a > 0.12 ? log2(a * 17) * 16 : log2(a * 17) * 16)
        return max(0, min(100, Int(v.rounded())))
    }

    /// Encode one actuator: high band 320 Hz, low band 160 Hz (the classic defaults).
    public static func encode(high: Double, low: Double, highHz: Double = 320, lowHz: Double = 160) -> [UInt8] {
        let hi = ampIndex(high), lo = ampIndex(low)
        if hi == 0 && lo == 0 { return neutral }
        let hf = (Int((log2(highHz / 10) * 32).rounded()) - 0x60) * 4     // 9-bit
        let lf = Int((log2(lowHz / 10) * 32).rounded()) - 0x40            // 7-bit
        let hfAmp = hi * 2                                                  // 0…200, even
        let lfAmp = lo / 2 + 0x40 + (lo & 1 == 1 ? 0x8000 : 0)             // bit 15 = odd half-step
        return [
            UInt8(hf & 0xFF),
            UInt8(hfAmp & 0xFE) | UInt8((hf >> 8) & 0x01),
            UInt8(lf & 0x7F) | UInt8((lfAmp >> 8) & 0x80),
            UInt8(lfAmp & 0xFF),
        ]
    }

    /// Rumble-only output report 0x10: [0x10, counter, left 4 bytes, right 4 bytes].
    public static func report(left: [UInt8], right: [UInt8], counter: Int) -> [UInt8] {
        [0x10, UInt8(counter & 0x0F)] + left.prefix(4) + right.prefix(4)
    }
}
