import Foundation

/// Raw report recorder. Format: "NS2C" magic, then records of
/// u32 LE milliseconds-since-start, u16 LE length, bytes.
public final class CaptureWriter {
    private let handle: FileHandle
    private let start = DispatchTime.now().uptimeNanoseconds
    public private(set) var count = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data("NS2C".utf8))
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    public func append(_ report: [UInt8]) {
        let ms = UInt32(truncatingIfNeeded: (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        var d = Data()
        withUnsafeBytes(of: ms.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(report.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: report)
        handle.write(d)
        count += 1
    }

    public func close() { try? handle.close() }

    public static func read(url: URL) throws -> [(ms: UInt32, bytes: [UInt8])] {
        let d = [UInt8](try Data(contentsOf: url))
        guard d.count >= 4, d[0..<4] == [0x4E, 0x53, 0x32, 0x43][...] else { return [] }
        var out: [(UInt32, [UInt8])] = []
        var i = 4
        while i + 6 <= d.count {
            let ms = UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
            let len = Int(d[i+4]) | Int(d[i+5]) << 8
            i += 6
            guard i + len <= d.count else { break }
            out.append((ms, Array(d[i..<i+len])))
            i += len
        }
        return out
    }
}

/// Per-byte statistics across many reports — a cheap "heatmap" for locating fields.
public struct ByteStats {
    public private(set) var minV = [UInt8](repeating: 255, count: 64)
    public private(set) var maxV = [UInt8](repeating: 0, count: 64)
    public private(set) var changes = [Int](repeating: 0, count: 64)
    private var last: [UInt8]?
    public private(set) var n = 0

    public init() {}

    public mutating func add(_ r: [UInt8]) {
        for i in 0..<min(64, r.count) {
            minV[i] = min(minV[i], r[i]); maxV[i] = max(maxV[i], r[i])
            if let last, i < last.count, last[i] != r[i] { changes[i] += 1 }
        }
        last = r; n += 1
    }

    public func report(length: Int) -> String {
        var lines = ["off  min  max  changes   (bytes that never change omitted)"]
        for i in 0..<min(64, length) where changes[i] > 0 {
            lines.append(String(format: "%3d  %02X   %02X   %d", i, minV[i], maxV[i], changes[i]))
        }
        return lines.joined(separator: "\n")
    }
}
