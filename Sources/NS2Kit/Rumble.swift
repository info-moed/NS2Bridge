import Foundation

/// HD Rumble 2 output report 0x02 (procon2tool format).
/// [0]=0x02, [1]=0x50|counter, [2..6]=slot A, [17]=counter again, [18..22]=slot B. 64 bytes, 250 Hz.
public enum Rumble {
    public static let neutral: [UInt8] = [0x00, 0x01, 0x40, 0x00, 0x00]
    public static let gentle: [UInt8]  = [0x50, 0x18, 0x18, 0x08, 0x04]
    public static let medium: [UInt8]  = [0x70, 0x28, 0x28, 0x14, 0x09]
    public static let strong: [UInt8]  = [0x93, 0x35, 0x36, 0x1C, 0x0D]
    public static let fade: [UInt8]    = [0x40, 0x10, 0x10, 0x04, 0x02]

    public static let presets: [String: [UInt8]] = [
        "neutral": neutral, "gentle": gentle, "medium": medium, "strong": strong, "fade": fade,
    ]

    public static func report(left: [UInt8], right: [UInt8], counter: Int) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 64)
        let c = 0x50 | UInt8(counter & 0x0F)
        r[0] = 0x02
        r[1] = c
        r[17] = c
        for i in 0..<min(5, left.count) { r[2 + i] = left[i] }
        for i in 0..<min(5, right.count) { r[18 + i] = right[i] }
        return r
    }
}
