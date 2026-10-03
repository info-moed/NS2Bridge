import Foundation

/// Buttons in input report 0x09, bytes 3..5 as a little-endian 24-bit word.
/// All 21 bits verified on hardware (ns2probe buttons, 2026-09-28); identical to ndeadly/switch2_controller_research.
public struct ProButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let b          = ProButtons(rawValue: 1 << 0)
    public static let a          = ProButtons(rawValue: 1 << 1)
    public static let y          = ProButtons(rawValue: 1 << 2)
    public static let x          = ProButtons(rawValue: 1 << 3)
    public static let r          = ProButtons(rawValue: 1 << 4)
    public static let zr         = ProButtons(rawValue: 1 << 5)
    public static let plus       = ProButtons(rawValue: 1 << 6)
    public static let rightStick = ProButtons(rawValue: 1 << 7)
    public static let dpadDown   = ProButtons(rawValue: 1 << 8)
    public static let dpadRight  = ProButtons(rawValue: 1 << 9)
    public static let dpadLeft   = ProButtons(rawValue: 1 << 10)
    public static let dpadUp     = ProButtons(rawValue: 1 << 11)
    public static let l          = ProButtons(rawValue: 1 << 12)
    public static let zl         = ProButtons(rawValue: 1 << 13)
    public static let minus      = ProButtons(rawValue: 1 << 14)
    public static let leftStick  = ProButtons(rawValue: 1 << 15)
    public static let home       = ProButtons(rawValue: 1 << 16)
    public static let capture    = ProButtons(rawValue: 1 << 17)
    public static let gr         = ProButtons(rawValue: 1 << 18)
    public static let gl         = ProButtons(rawValue: 1 << 19)
    public static let c          = ProButtons(rawValue: 1 << 20)

    public static let named: [(ProButtons, String)] = [
        (.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"), (.l, "L"), (.r, "R"), (.zl, "ZL"), (.zr, "ZR"),
        (.minus, "−"), (.plus, "+"), (.leftStick, "LS"), (.rightStick, "RS"), (.home, "HOME"),
        (.capture, "CAPTURE"), (.c, "C"), (.gl, "GL"), (.gr, "GR"),
        (.dpadUp, "↑"), (.dpadDown, "↓"), (.dpadLeft, "←"), (.dpadRight, "→"),
    ]

    public var names: [String] { ProButtons.named.filter { contains($0.0) }.map(\.1) }
}

public struct Stick: Sendable, Equatable {
    public var x: UInt16   // 12-bit raw, 0...4095
    public var y: UInt16
}

/// Parsed input report 0x09 (layout: ndeadly hid_reports.md, offsets +1 for the USB report ID).
public struct ControllerState: Sendable {
    public var counter: UInt8          // byte 1
    public var externalPower: Bool     // byte 2 bit 0
    public var charging: Bool          // byte 2 bit 1
    public var batteryLevel: Int       // byte 2 bits 2..5, 0...9
    public var buttons: ProButtons     // bytes 3..5
    public var left: Stick             // bytes 6..8
    public var right: Stick            // bytes 9..11
    public var motionLength: Int       // byte 15 (observed 30)
    public var motion: [UInt8]         // bytes 16..<16+len, packed format — not yet decoded
    public var millivolts: Int?        // report 0x05 only

    public static let reportID: UInt8 = 0x09

    /// Report 0x09 (normal) or 0x05 (selected while motion is on; see Motion.swift).
    public init?(report r: [UInt8]) {
        if r.first == Report05.id {
            guard let s = ControllerState(report05: r) else { return nil }
            self = s
            return
        }
        guard r.count >= 16, r[0] == ControllerState.reportID else { return nil }
        millivolts = nil
        counter = r[1]
        externalPower = r[2] & 0x01 != 0
        charging = r[2] & 0x02 != 0
        batteryLevel = Int((r[2] >> 2) & 0x0F)
        buttons = ProButtons(rawValue: UInt32(r[3]) | UInt32(r[4]) << 8 | UInt32(r[5]) << 16)
        left = ControllerState.stick(r, 6)
        right = ControllerState.stick(r, 9)
        motionLength = Int(r[15])
        let end = min(r.count, 16 + motionLength)
        motion = end > 16 ? Array(r[16..<end]) : []
    }

    static func stick(_ b: [UInt8], _ o: Int) -> Stick {
        Stick(x: UInt16(b[o]) | UInt16(b[o + 1] & 0x0F) << 8,
              y: UInt16(b[o + 1] >> 4) | UInt16(b[o + 2]) << 4)
    }
}

/// SDL gamecontrollerdb mapping for the generic IOKit joystick SDL exposes once the pad is streaming 0x09.
/// SDL button index == report bit index (HID usages 1...21 in order); axes: X, Y, Rx, Rz.
public enum SDLMapping {
    public static let macGUID = "030002697e0500006920000001020000"

    public enum Layout: String, CaseIterable, Codable, Sendable {
        /// Buttons keep their POSITION (Xbox style): bottom = A, right = B, left = X, top = Y.
        case positions
        /// Buttons keep their LABEL (Nintendo style): the button printed "A" is A.
        case labels
    }

    public static func line(guid: String = macGUID, layout: Layout = .positions) -> String {
        let face = layout == .positions
            ? ["a:b0", "b:b1", "x:b2", "y:b3"]     // Nintendo B (bottom) → A, A (right) → B, Y (left) → X, X (top) → Y
            : ["a:b1", "b:b0", "x:b3", "y:b2"]     // Nintendo A → A, B → B, X → X, Y → Y
        return ([guid, "Nintendo Switch 2 Pro Controller"] + face + [
         "rightshoulder:b4", "righttrigger:b5", "start:b6", "rightstick:b7",
         "dpdown:b8", "dpright:b9", "dpleft:b10", "dpup:b11",
         "leftshoulder:b12", "lefttrigger:b13", "back:b14", "leftstick:b15",
         "guide:b16", "misc1:b17", "paddle1:b18", "paddle2:b19", "misc2:b20",
         "leftx:a0", "lefty:a1~", "rightx:a2", "righty:a3~",
         "platform:Mac OS X"]).joined(separator: ",") + ","
    }
}


/// SDL mappings for the NSO N64 controller (SDL's HIDAPI driver; same GUID in SDL 2.32 and SDL 3, read on hardware).
/// SDL's default puts C-right on "back" and C-down on a trigger; these put each N64 button where the
/// engine's own N64 bindings expect it: C-buttons → right stick, Z → left trigger, R → right trigger.
public enum N64Mapping {
    public static let sdl2GUID = "030070d67e050000192000001202680c"

    /// HIDAPI raw inputs: b0 A, b1 B, b2 C-left, b3 C-up, b4 C-right, a5 C-down, a4 Z,
    /// b9 L, b10 R, b6 Start, b5 Home, b7 ZR. SDL2: D-pad b11–b14 (up, down, left, right), Capture b15.
    /// SDL3 (and sdl2-compat, which runs SDL3 underneath): D-pad is hat 0, Capture b11
    /// (SDL_hidapi_switch.c; matches SDL3's own default mapping read on hardware).
    public static func line(for engine: GameAnalysis.Engine, sdl3: Bool = false) -> String? {
        let pad = sdl3
            ? ["dpup:h0.1", "dpdown:h0.4", "dpleft:h0.8", "dpright:h0.2", "misc1:b11"]
            : ["dpup:b11", "dpdown:b12", "dpleft:b13", "dpright:b14", "misc1:b15"]
        let common = ["a:b0", "-rightx:b2", "-righty:b3", "+rightx:b4", "+righty:+a5",
                      "leftshoulder:b9", "lefttrigger:a4", "righttrigger:b10", "start:b6", "guide:b5",
                      "leftx:a0", "lefty:a1"] + pad
        switch engine {
        case .n64recomp:      // recomp binds N64 B to WEST; EAST/NORTH/rightstick/rightshoulder are extra C bindings → keep free
            return ([sdl2GUID, "Nintendo N64 Controller"] + common + ["x:b1", "leftstick:b7", "platform:Mac OS X"]).joined(separator: ",") + ","
        case .libultraship:   // libultraship binds N64 B to EAST
            return ([sdl2GUID, "Nintendo N64 Controller"] + common + ["b:b1", "rightshoulder:b7", "platform:Mac OS X"]).joined(separator: ",") + ","
        case .unknown:
            return nil        // leave SDL's own mapping (emulators have their own N64 profiles)
        }
    }
}
