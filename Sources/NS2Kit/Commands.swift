import Foundation

/// Device identities (VID 0x057E = Nintendo).
public enum NS2Device {
    public static let vendorID = 0x057E
    public static let proController2 = 0x2069
    public static let joyCon2R = 0x2066
    public static let joyCon2L = 0x2067
    public static let gameCubeNSO = 0x2073

    public static let names: [Int: String] = [
        proController2: "Switch 2 Pro Controller",
        joyCon2R: "Joy-Con 2 (R)",
        joyCon2L: "Joy-Con 2 (L)",
        gameCubeNSO: "NSO GameCube Controller",
    ]

    /// USB interface numbers — measured on this Mac via ioreg (0x2069, bcdDevice 0x0201).
    public static let hidInterface = 0      // HID class, claimed by Apple's AppleUserHIDDevice
    public static let vendorInterface = 1   // class 0xFF, no driver bound → ours
}

/// 0x91-family commands sent on the vendor interface bulk OUT endpoint.
/// Sources: procon2tool, SDL3 SDL_hidapi_switch2.c, and the author's earlier Windows prototype.
public enum NS2Command {
    /// "Start HID output at 4 ms intervals". Bytes 10..15 = host MAC (FF×6 = generic host).
    public static let initHIDOutput: [UInt8] = [
        0x03, 0x91, 0x00, 0x0D, 0x00, 0x08, 0x00, 0x00,
        0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    ]
    /// Purpose unknown; empirically needed on the earlier Windows prototype's HID-fallback path.
    public static let unknown07: [UInt8] = [0x07, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
    public static let unknown16: [UInt8] = [0x16, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
    public static let imuEnableA: [UInt8] = [0x0C, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00]
    public static let imuEnableB: [UInt8] = [0x0C, 0x91, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00]
    /// Select input report format (byte 8): 0x09 = format macOS's HID descriptor describes (IMU packed, undocumented);
    /// 0x05 = format SDL uses (documented s16 accel/gyro). Was mislabeled "HAPTIC_ENABLE" in the Windows build.
    public static func setReportFormat(_ id: UInt8) -> [UInt8] {
        [0x03, 0x91, 0x00, 0x0A, 0x00, 0x04, 0x00, 0x00, id, 0x00, 0x00, 0x00]
    }

    /// Player LED; byte 8 is the LED bitfield (bit0 = LED 1 … bit3 = LED 4).
    public static func setPlayerLED(_ mask: UInt8) -> [UInt8] {
        [0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, mask, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    }

    /// Flash read, as SDL does it (`ReadFlashBlock`): bytes 12–15 = address (LE). The reply is 0x50 bytes,
    /// the 0x40 data bytes start at offset 0x10. Read-only.
    public static func flashRead(address: UInt32) -> [UInt8] {
        [0x02, 0x91, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         UInt8(address & 0xFF), UInt8((address >> 8) & 0xFF), UInt8((address >> 16) & 0xFF), UInt8((address >> 24) & 0xFF)]
    }

    /// The controller's serial number from the flash-read reply for 0x13000 (data offset 2, up to 16 characters,
    /// NUL-terminated). nil if the reply is short or not printable text.
    public static func serial(fromFlashReply r: [UInt8]) -> String? {
        guard r.count >= 0x10 + 18 else { return nil }
        let bytes = r[(0x10 + 2)..<(0x10 + 18)].prefix { $0 != 0 }
        guard bytes.count >= 4, bytes.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// SPI flash read (EXPERIMENTAL — layout from the audit, unverified).
    /// Bytes 12..15 = address (LE); byte 8 = length.
    public static func spiRead(address: UInt32, length: UInt8) -> [UInt8] {
        [0x02, 0x91, 0x00, 0x04, 0x00, 0x08, 0x00, 0x00, length, 0x7E, 0x00, 0x00,
         UInt8(address & 0xFF), UInt8((address >> 8) & 0xFF),
         UInt8((address >> 16) & 0xFF), UInt8((address >> 24) & 0xFF)]
    }

    public struct Step {
        public let name: String
        public let bytes: [UInt8]
    }

    /// Default init sequence (procon2tool/SDL order plus the Windows build's extras).
    /// `format`: input report to stream (0x09 Pro, 0x0A GameCube, 0x05 with plain motion data).
    public static func initSequence(includeUnknown: Bool = true, led: UInt8 = 0x01, format: UInt8 = 0x09) -> [Step] {
        var s: [Step] = [Step(name: "INIT_HID_OUTPUT", bytes: initHIDOutput)]
        if includeUnknown {
            s.append(Step(name: "UNKNOWN_07", bytes: unknown07))
            s.append(Step(name: "UNKNOWN_16", bytes: unknown16))
        }
        s.append(Step(name: "SET_PLAYER_LED", bytes: setPlayerLED(led)))
        s.append(Step(name: "IMU_ENABLE_A", bytes: imuEnableA))
        s.append(Step(name: "IMU_ENABLE_B", bytes: imuEnableB))
        s.append(Step(name: String(format: "REPORT_FORMAT_%02X", format), bytes: setReportFormat(format)))
        return s
    }
}

public extension Collection where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
