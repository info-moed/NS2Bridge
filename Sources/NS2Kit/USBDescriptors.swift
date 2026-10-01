import Foundation

/// Minimal parser for a raw USB configuration descriptor blob.
public struct USBConfigInfo {
    public struct Endpoint {
        public let address: UInt8
        public let attributes: UInt8
        public let maxPacketSize: UInt16
        public let interval: UInt8
        public var isIn: Bool { address & 0x80 != 0 }
        public var transfer: String { ["control", "isochronous", "bulk", "interrupt"][Int(attributes & 0x03)] }
    }
    public struct Interface {
        public let number: UInt8
        public let alternate: UInt8
        public let cls: UInt8
        public let subclass: UInt8
        public let proto: UInt8
        public var endpoints: [Endpoint] = []
    }
    public var interfaces: [Interface] = []

    public init(bytes: [UInt8]) {
        var i = 0
        while i + 1 < bytes.count {
            let len = Int(bytes[i]), type = bytes[i + 1]
            if len < 2 || i + len > bytes.count { break }
            if type == 0x04, len >= 9 {
                interfaces.append(Interface(number: bytes[i + 2], alternate: bytes[i + 3],
                                            cls: bytes[i + 5], subclass: bytes[i + 6], proto: bytes[i + 7]))
            } else if type == 0x05, len >= 7, !interfaces.isEmpty {
                let mps = UInt16(bytes[i + 4]) | (UInt16(bytes[i + 5]) << 8)
                interfaces[interfaces.count - 1].endpoints.append(
                    Endpoint(address: bytes[i + 2], attributes: bytes[i + 3],
                             maxPacketSize: mps & 0x7FF, interval: bytes[i + 6]))
            }
            i += len
        }
    }

    public var description: String {
        interfaces.map { itf in
            var s = String(format: "iface %d alt %d  class 0x%02X sub 0x%02X proto 0x%02X",
                           itf.number, itf.alternate, itf.cls, itf.subclass, itf.proto)
            for ep in itf.endpoints {
                s += String(format: "\n    EP 0x%02X %@ %@  maxPacket %d  interval %d",
                            ep.address, ep.isIn ? "IN " : "OUT", ep.transfer, ep.maxPacketSize, ep.interval)
            }
            return s
        }.joined(separator: "\n")
    }
}
