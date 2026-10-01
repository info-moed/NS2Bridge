import Foundation
import IOKit
import IOKit.hid

/// Identity of one attached HID device.
public struct HIDDeviceInfo: Sendable, Hashable {
    public let id: UInt64          // IORegistry entry ID — unique while attached
    public let productID: Int
    public let locationID: Int     // same value as the USB device/interfaces' locationID
    public let serial: String
    public let transport: String   // "USB", "Bluetooth", "BluetoothLowEnergy", …

    public var isBluetooth: Bool { transport.localizedCaseInsensitiveContains("bluetooth") }
}

/// Non-seizing IOHIDManager link (USB interface 0 / Bluetooth HID). Apple's HID driver keeps
/// ownership, so the pad stays visible to GameController.framework / SDL / Steam while we read raw
/// reports. Handles any number of matching devices at once.
public final class HIDLink {
    public typealias ReportHandler = (_ report: [UInt8], _ timestamp: UInt64) -> Void
    public typealias DeviceHandler = (_ connected: Bool, _ productID: Int) -> Void

    /// Reports from any device (single-device convenience).
    public var onReport: ReportHandler?
    public var onDevice: DeviceHandler?
    /// Per-device variants.
    public var onDeviceReport: ((_ report: [UInt8], _ timestamp: UInt64, _ device: UInt64) -> Void)?
    public var onDeviceChange: ((_ connected: Bool, _ info: HIDDeviceInfo) -> Void)?

    /// The most recently attached device (single-device convenience).
    public var device: IOHIDDevice? { devices.values.first?.device }
    public var productID: Int { devices.values.first?.info.productID ?? 0 }
    public var attached: [HIDDeviceInfo] { devices.values.map(\.info) }

    private final class Entry {
        let device: IOHIDDevice
        let info: HIDDeviceInfo
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        weak var link: HIDLink?
        init(device: IOHIDDevice, info: HIDDeviceInfo, link: HIDLink) { self.device = device; self.info = info; self.link = link }
        deinit { buffer.deallocate() }
    }

    private let manager: IOHIDManager
    private var devices: [UInt64: Entry] = [:]

    /// `productIDs`: Nintendo product IDs to match (default: the Switch 2 family).
    public init(productIDs: [Int] = Array(NS2Device.names.keys)) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = productIDs.map {
            [kIOHIDVendorIDKey: NS2Device.vendorID, kIOHIDProductIDKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    }

    deinit { stop() }

    /// Input Monitoring TCC state for this process (granted / denied / unknown).
    public static var accessStatus: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown"
        }
    }

    public func start(runLoop: CFRunLoop = CFRunLoopGetCurrent()) throws {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().detach(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            throw NS2Error.open(String(format: "IOHIDManagerOpen 0x%08X (Input Monitoring: %@)", r, HIDLink.accessStatus))
        }
    }

    public func stop() {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private static func registryID(_ dev: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(dev), &id)
        return id
    }

    private func attach(_ dev: IOHIDDevice) {
        guard !devices.values.contains(where: { CFEqual($0.device, dev) }) else { return }
        let id = Self.registryID(dev)
        guard id != 0, devices[id] == nil else { return }
        let info = HIDDeviceInfo(
            id: id,
            productID: (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0,
            locationID: (IOHIDDeviceGetProperty(dev, kIOHIDLocationIDKey as CFString) as? Int) ?? 0,
            serial: (IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String) ?? "",
            transport: (IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String) ?? "USB")
        let entry = Entry(device: dev, info: info, link: self)
        devices[id] = entry
        let ctx = Unmanaged.passUnretained(entry).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(dev, entry.buffer, 128, { ctx, _, _, _, reportID, report, length, ts in
            let entry = Unmanaged<Entry>.fromOpaque(ctx!).takeUnretainedValue()
            guard let me = entry.link else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // Normalize: always present the report ID as byte 0.
            if reportID != 0, bytes.first != UInt8(truncatingIfNeeded: reportID) {
                bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
            }
            me.onReport?(bytes, ts)
            me.onDeviceReport?(bytes, ts, entry.info.id)
        }, ctx)
        onDevice?(true, info.productID)
        onDeviceChange?(true, info)
    }

    private func detach(_ dev: IOHIDDevice) {
        // Match by the device object: by the time the removal callback runs, the registry entry
        // may already be gone, so looking its ID up again isn't reliable.
        guard let entry = devices.values.first(where: { CFEqual($0.device, dev) }) else { return }
        remove(entry)
    }

    private func remove(_ entry: Entry) {
        guard devices.removeValue(forKey: entry.info.id) != nil else { return }
        onDevice?(false, entry.info.productID)
        onDeviceChange?(false, entry.info)
    }

    /// Safety net: drop any device macOS no longer lists (e.g. a missed removal callback).
    public func sweep() {
        let current = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        for entry in Array(devices.values) where !current.contains(where: { CFEqual($0, entry.device) }) {
            remove(entry)
        }
    }

    /// The IOKit service of an attached device (for registry properties).
    public func service(for id: UInt64) -> io_service_t? {
        devices[id].map { IOHIDDeviceGetService($0.device) }
    }

    /// Send an output report to the first device. `bytes[0]` must be the report ID.
    @discardableResult
    public func sendOutput(_ bytes: [UInt8]) -> IOReturn {
        guard let id = devices.keys.first else { return kIOReturnNotAttached }
        return sendOutput(bytes, to: id)
    }

    /// Send an output report to a specific device.
    @discardableResult
    public func sendOutput(_ bytes: [UInt8], to id: UInt64) -> IOReturn {
        guard let entry = devices[id], let rid = bytes.first else { return kIOReturnNotAttached }
        return bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(entry.device, kIOHIDReportTypeOutput, CFIndex(rid), $0.baseAddress!, $0.count)
        }
    }
}
