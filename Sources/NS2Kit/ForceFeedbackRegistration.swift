import Foundation
import IOKit

/// Attaches NS2 Bridge's ForceFeedback plug-in (NS2FF.plugin) to a controller's HID device, so SDL's
/// generic (IOKit) joystick backend in *any* game reports rumble support and sends rumble to NS2 Bridge —
/// without modifying the game.
///
/// Rules learned on hardware (macOS 27):
/// - `IOCFPlugInTypes` on the HID device already holds macOS's own IOHIDLib entries, which every app
///   needs to open the device. Always MERGE; never replace (replacing makes the device unopenable
///   until it's replugged).
/// - The ForceFeedback framework only accepts plug-in paths relative to /System/Library/Extensions,
///   so an absolute location is expressed as "../../.." + path.
/// - The property lives on the device object: it disappears when the controller is unplugged, so it
///   is re-applied on every connect.
public enum ForceFeedbackRegistration {
    public static let forceFeedbackTypeID = "F4545CE5-BF5B-11D6-A4BB-0003933E3E3E"
    static let key = "IOCFPlugInTypes" as CFString

    public static func relativePath(for plugin: URL) -> String {
        "../../.." + plugin.standardizedFileURL.path
    }

    /// Adds (or updates) only the ForceFeedback entry. Returns true on success.
    @discardableResult
    public static func register(_ plugin: URL, on service: io_service_t) -> Bool {
        guard service != IO_OBJECT_NULL else { return false }
        var types = (IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: String]) ?? [:]
        guard !types.isEmpty else { return false }          // no IOHIDLib entries? don't touch this device
        let path = relativePath(for: plugin)
        if types[forceFeedbackTypeID] == path { return true }
        types[forceFeedbackTypeID] = path
        return IORegistryEntrySetCFProperty(service, key, types as CFDictionary) == KERN_SUCCESS
    }

    /// Removes only the ForceFeedback entry, leaving macOS's own entries untouched.
    public static func unregister(on service: io_service_t) {
        guard service != IO_OBJECT_NULL,
              var types = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: String],
              types[forceFeedbackTypeID] != nil else { return }
        types[forceFeedbackTypeID] = nil
        IORegistryEntrySetCFProperty(service, key, types as CFDictionary)
    }
}
