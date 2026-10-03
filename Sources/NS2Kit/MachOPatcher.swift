import Foundation

/// Adds / removes an LC_LOAD_WEAK_DYLIB load command in a Mach-O file (thin or universal).
/// Used to make a game's own SDL library load NS2 Bridge's helper, without touching the game binary.
public enum MachOPatcher {
    static let LC_LOAD_WEAK_DYLIB: UInt32 = 0x8000_0018
    static let LC_LOAD_DYLIB: UInt32 = 0x0C
    static let LC_SEGMENT_64: UInt32 = 0x19
    static let MH_MAGIC_64: UInt32 = 0xFEED_FACF
    static let FAT_MAGIC: UInt32 = 0xCAFE_BABE          // stored big-endian

    public enum PatchError: Error, CustomStringConvertible {
        case notMachO, noSpace(arch: String), unsupported(String)
        public var description: String {
            switch self {
            case .notMachO: return "not a Mach-O file"
            case .noSpace(let a): return "no room for another load command (\(a) slice)"
            case .unsupported(let s): return s
            }
        }
    }

    /// Paths of every dylib the file loads (all slices; de-duplicated).
    public static func loadedDylibs(_ url: URL) throws -> [String] {
        let d = [UInt8](try Data(contentsOf: url))
        var out: [String] = []
        for off in try sliceOffsets(d) {
            forEachCommand(d, off) { cmd, at, size in
                if cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB, let s = dylibName(d, at, size) { out.append(s) }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Adds `LC_LOAD_WEAK_DYLIB <path>` to every slice (no-op if already present). Re-sign afterward.
    public static func addWeakDylib(_ path: String, to url: URL) throws {
        var d = [UInt8](try Data(contentsOf: url))
        for off in try sliceOffsets(d) { try addToSlice(&d, off, path) }
        try Data(d).write(to: url, options: .atomic)   // new file: never rewrite a signed binary in place
    }

    /// Dry run: would `addWeakDylib` succeed (every slice has room, or already has it)?
    public static func canAddWeakDylib(_ path: String, to url: URL) -> Bool {
        guard var d = try? [UInt8](Data(contentsOf: url)), let offs = try? sliceOffsets(d) else { return false }
        for off in offs { do { try addToSlice(&d, off, path) } catch { return false } }
        return true
    }

    /// Removes any load command for `path` from every slice. Re-sign afterward.
    public static func removeDylib(_ path: String, from url: URL) throws {
        var d = [UInt8](try Data(contentsOf: url))
        for off in try sliceOffsets(d) { removeFromSlice(&d, off, path) }
        try Data(d).write(to: url, options: .atomic)   // new file: never rewrite a signed binary in place
    }

    // MARK: - Internals

    static func u32le(_ d: [UInt8], _ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24 }
    static func u32be(_ d: [UInt8], _ o: Int) -> UInt32 { UInt32(d[o]) << 24 | UInt32(d[o+1]) << 16 | UInt32(d[o+2]) << 8 | UInt32(d[o+3]) }
    static func u64le(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(u32le(d, o)) | UInt64(u32le(d, o + 4)) << 32 }
    static func put32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0..<4 { d[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }

    static func sliceOffsets(_ d: [UInt8]) throws -> [Int] {
        guard d.count >= 32 else { throw PatchError.notMachO }
        if u32be(d, 0) == FAT_MAGIC {
            let n = Int(u32be(d, 4))
            return (0..<n).map { Int(u32be(d, 8 + $0 * 20 + 8)) }
        }
        guard u32le(d, 0) == MH_MAGIC_64 else { throw PatchError.notMachO }
        return [0]
    }

    static func forEachCommand(_ d: [UInt8], _ off: Int, _ body: (_ cmd: UInt32, _ at: Int, _ size: Int) -> Void) {
        guard u32le(d, off) == MH_MAGIC_64 else { return }
        let ncmds = Int(u32le(d, off + 16))
        var p = off + 32
        for _ in 0..<ncmds {
            let cmd = u32le(d, p), size = Int(u32le(d, p + 4))
            body(cmd, p, size)
            p += size
        }
    }

    static func dylibName(_ d: [UInt8], _ at: Int, _ size: Int) -> String? {
        let nameOff = Int(u32le(d, at + 8))
        guard nameOff < size else { return nil }
        let bytes = d[(at + nameOff)..<(at + size)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func archName(_ d: [UInt8], _ off: Int) -> String {
        switch u32le(d, off + 4) { case 0x0100000C: return "arm64"; case 0x01000007: return "x86_64"; default: return "unknown" }
    }

    static func addToSlice(_ d: inout [UInt8], _ off: Int, _ path: String) throws {
        guard u32le(d, off) == MH_MAGIC_64 else { throw PatchError.unsupported("only 64-bit Mach-O is supported") }
        var already = false
        var firstData = Int.max        // lowest file offset of any section's contents: load commands must end before it
        forEachCommand(d, off) { cmd, at, size in
            if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB), dylibName(d, at, size) == path { already = true }
            if cmd == LC_SEGMENT_64 {
                let nsects = Int(u32le(d, at + 64))
                for s in 0..<nsects {
                    let sect = at + 72 + s * 80
                    let fileOff = Int(u32le(d, sect + 48)), flags = u32le(d, sect + 64)
                    let zerofill = (flags & 0xFF) == 0x01 || (flags & 0xFF) == 0x0C
                    if fileOff > 0 && !zerofill { firstData = min(firstData, fileOff) }
                }
            }
        }
        if already { return }
        let name = Array(path.utf8) + [0]
        let cmdSize = (24 + name.count + 7) & ~7
        let ncmds = u32le(d, off + 16), sizeofcmds = Int(u32le(d, off + 20))
        let end = off + 32 + sizeofcmds
        guard firstData != Int.max, end + cmdSize <= off + firstData else { throw PatchError.noSpace(arch: archName(d, off)) }
        guard d[end..<(end + cmdSize)].allSatisfy({ $0 == 0 }) else { throw PatchError.noSpace(arch: archName(d, off)) }
        put32(&d, end, LC_LOAD_WEAK_DYLIB)
        put32(&d, end + 4, UInt32(cmdSize))
        put32(&d, end + 8, 24)                  // name offset
        put32(&d, end + 12, 2)                  // timestamp
        put32(&d, end + 16, 0x0001_0000)        // current version 1.0.0
        put32(&d, end + 20, 0x0001_0000)        // compatibility version 1.0.0
        for (i, b) in name.enumerated() { d[end + 24 + i] = b }
        put32(&d, off + 16, ncmds + 1)
        put32(&d, off + 20, UInt32(sizeofcmds + cmdSize))
    }

    static func removeFromSlice(_ d: inout [UInt8], _ off: Int, _ path: String) {
        guard u32le(d, off) == MH_MAGIC_64 else { return }
        var target: (at: Int, size: Int)?
        forEachCommand(d, off) { cmd, at, size in
            if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB), dylibName(d, at, size) == path { target = (at, size) }
        }
        guard let t = target else { return }
        let ncmds = u32le(d, off + 16), sizeofcmds = Int(u32le(d, off + 20))
        let end = off + 32 + sizeofcmds
        // Shift the following commands down and zero the freed tail.
        d.replaceSubrange(t.at..<(end - t.size), with: d[(t.at + t.size)..<end])
        for i in (end - t.size)..<end { d[i] = 0 }
        put32(&d, off + 16, ncmds - 1)
        put32(&d, off + 20, UInt32(sizeofcmds - t.size))
    }
}
