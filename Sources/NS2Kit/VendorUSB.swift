import Foundation
import IOKit
import IOUSBHost

public enum NS2Error: Error, CustomStringConvertible {
    case notFound(String)
    case open(String)
    case io(String)
    public var description: String {
        switch self {
        case .notFound(let s): return "not found: \(s)"
        case .open(let s): return "open failed: \(s)"
        case .io(let s): return "I/O error: \(s)"
        }
    }
}

/// The vendor-specific interface (bInterfaceNumber 1) carrying the 0x91 command family.
/// No kernel driver binds to it on macOS 27, so a non-sandboxed app can claim it directly.
public final class VendorUSB {
    public let productID: Int
    public private(set) var config: USBConfigInfo
    private let interface: IOUSBHostInterface
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe?
    private let queue = DispatchQueue(label: "ns2.vendor-usb", qos: .userInteractive)

    /// `locationID` picks one specific controller when several of the same model are plugged in.
    public static func matchingService(productID: Int, interfaceNumber: Int, locationID: Int? = nil) -> io_service_t {
        let dict = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        var props: [String: Any] = [
            "idVendor": NS2Device.vendorID,
            "idProduct": productID,
            "bInterfaceNumber": interfaceNumber,
        ]
        if let locationID { props["locationID"] = locationID }
        dict[kIOPropertyMatchKey] = props as NSDictionary
        return IOServiceGetMatchingService(kIOMainPortDefault, dict)
    }

    /// Find the first supported NS2-family product currently attached.
    public static func attachedProductID() -> Int? {
        for pid in NS2Device.names.keys.sorted() {
            let svc = matchingService(productID: pid, interfaceNumber: NS2Device.vendorInterface)
            if svc != IO_OBJECT_NULL { IOObjectRelease(svc); return pid }
        }
        return nil
    }

    public init(productID: Int, locationID: Int? = nil) throws {
        self.productID = productID
        let svc = VendorUSB.matchingService(productID: productID, interfaceNumber: NS2Device.vendorInterface, locationID: locationID)
        guard svc != IO_OBJECT_NULL else {
            throw NS2Error.notFound(String(format: "USB interface %d on 057E:%04X", NS2Device.vendorInterface, productID))
        }
        defer { IOObjectRelease(svc) }

        do {
            interface = try IOUSBHostInterface(__ioService: svc, options: [], queue: queue, interestHandler: nil)
        } catch {
            let code = (error as NSError).code
            var hint = ""
            if UInt32(truncatingIfNeeded: code) == UInt32(bitPattern: kIOReturnExclusiveAccess) {
                hint = " — another process holds interface 1 (close Brave/Chrome tabs using WebUSB, e.g. procon2tool)"
            }
            throw NS2Error.open("\(error.localizedDescription) (0x\(String(UInt32(truncatingIfNeeded: code), radix: 16)))\(hint)")
        }

        let cd = interface.configurationDescriptor
        let total = Int(UInt16(littleEndian: cd.pointee.wTotalLength))
        let raw = UnsafeRawPointer(cd).bindMemory(to: UInt8.self, capacity: total)
        config = USBConfigInfo(bytes: Array(UnsafeBufferPointer(start: raw, count: total)))

        let vendorItf = config.interfaces.first(where: { $0.number == UInt8(NS2Device.vendorInterface) && $0.alternate == 0 })
        let eps: [USBConfigInfo.Endpoint] = vendorItf?.endpoints ?? []
        guard let outEP = eps.first(where: { !$0.isIn }) else {
            interface.destroy()
            throw NS2Error.notFound("bulk OUT endpoint on interface 1")
        }
        outPipe = try interface.copyPipe(withAddress: Int(outEP.address))
        if let inEP = eps.first(where: { $0.isIn }) {
            inPipe = try? interface.copyPipe(withAddress: Int(inEP.address))
        } else {
            inPipe = nil
        }
    }

    deinit { interface.destroy() }

    public func close() { interface.destroy() }

    @discardableResult
    public func write(_ bytes: [UInt8], timeout: TimeInterval = 0.2) throws -> Int {
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var sent = 0
        do {
            try outPipe.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: timeout)
        } catch {
            throw NS2Error.io("bulk OUT: \(error.localizedDescription)")
        }
        return sent
    }

    /// Read one reply from bulk IN. Returns nil on timeout.
    public func read(maxLength: Int = 64, timeout: TimeInterval = 0.2) -> [UInt8]? {
        guard let inPipe else { return nil }
        let data = NSMutableData(length: maxLength)!
        var got = 0
        do {
            try inPipe.__sendIORequest(with: data, bytesTransferred: &got, completionTimeout: timeout)
        } catch {
            return nil
        }
        return Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: UInt8.self), count: got))
    }

    /// Read 0x40 bytes of the controller's flash (read-only; SDL's `ReadFlashBlock`).
    public func readFlash(_ address: UInt32, timeout: TimeInterval = 0.3) throws -> [UInt8]? {
        try write(NS2Command.flashRead(address: address), timeout: timeout)
        return read(maxLength: 0x50, timeout: timeout)
    }

    /// Send a command and wait for its reply.
    public func command(_ bytes: [UInt8], timeout: TimeInterval = 0.2) throws -> [UInt8]? {
        try write(bytes, timeout: timeout)
        return read(timeout: timeout)
    }
}
