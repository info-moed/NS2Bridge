import Foundation

/// Installs NS2 Bridge's helper *into* a game, in place — no copies of the game.
///
/// The helper is added next to the game's own bundled SDL library, and that library gets one weak
/// load command for it. The game's main executable is only re-signed when macOS would otherwise refuse
/// the modified SDL library (hardened runtime *without* the disable-library-validation entitlement).
/// Originals are backed up to ~/Library/Application Support/NS2Bridge/Backups/<bundle id>/ and
/// `uninstall` puts them back exactly.
public enum GameInstaller {
    public static let helperName = "ns2rumble.dylib"
    public static let loadPath = "@loader_path/ns2rumble.dylib"

    public enum InstallError: Error, CustomStringConvertible {
        case notAnApp
        case noBundledSDL
        case noHeaderSpace
        case gameRunning(String)
        case permission(String)
        case failed(String)

        public var description: String {
            switch self {
            case .notAnApp: return "That isn't an app bundle."
            case .noBundledSDL: return "The game doesn't ship its own SDL library inside the app, so there's nothing to attach the helper to."
            case .noHeaderSpace: return "The game's SDL library has no room for another load entry."
            case .gameRunning(let n): return "\(n) is running. Quit it first."
            case .permission(let p): return "macOS didn't allow NS2 Bridge to change the game (\(p)). Allow NS2 Bridge under System Settings → Privacy & Security → App Management, then try again."
            case .failed(let s): return s
            }
        }
    }

    public struct Manifest: Codable, Sendable {
        public var appPath: String
        public var sdlRelativePath: String       // relative to the .app
        public var resignedApp: Bool             // main executable + seal were re-signed (and backed up)
        public var installed: Date
    }

    // MARK: Locations

    public static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NS2Bridge", isDirectory: true)
    }
    public static func settingsURL(bundleID: String) -> URL {
        supportDir.appendingPathComponent("games", isDirectory: true).appendingPathComponent("\(bundleID).env")
    }
    static func backupDir(bundleID: String) -> URL {
        supportDir.appendingPathComponent("Backups", isDirectory: true).appendingPathComponent(bundleID, isDirectory: true)
    }

    // MARK: Inspection

    /// The SDL library bundled inside the app that the main executable loads.
    public static func bundledSDL(in app: URL) -> URL? {
        guard let exe = Bundle(url: app)?.executableURL, let deps = try? MachOPatcher.loadedDylibs(exe) else { return nil }
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        for dep in deps where dep.contains("libSDL2") || dep.contains("libSDL3") {
            let name = (dep as NSString).lastPathComponent
            let candidate = frameworks.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.resolvingSymlinksInPath() }
        }
        return nil
    }

    public static func isInstalled(_ app: URL) -> Bool {
        guard let sdl = bundledSDL(in: app) else { return false }
        let helper = sdl.deletingLastPathComponent().appendingPathComponent(helperName)
        return FileManager.default.fileExists(atPath: helper.path)
            && ((try? MachOPatcher.loadedDylibs(sdl).contains(loadPath)) ?? false)
    }

    /// Why the helper can't be installed, or nil if it can.
    public static func blocker(_ app: URL) -> InstallError? {
        guard Bundle(url: app)?.bundleIdentifier != nil else { return .notAnApp }
        guard let sdl = bundledSDL(in: app) else { return .noBundledSDL }
        if isInstalled(app) { return nil }
        return MachOPatcher.canAddWeakDylib(loadPath, to: sdl) ? nil : .noHeaderSpace
    }

    // MARK: Install / uninstall

    /// `settings` become KEY=VALUE lines the helper applies at game start-up.
    public static func install(_ app: URL, helper: URL, settings: [String: String],
                               hardened: Bool, libraryValidationDisabled: Bool) throws {
        guard let bundle = Bundle(url: app), let bid = bundle.bundleIdentifier, let exe = bundle.executableURL else { throw InstallError.notAnApp }
        guard let sdl = bundledSDL(in: app) else { throw InstallError.noBundledSDL }
        let fm = FileManager.default
        let backup = backupDir(bundleID: bid)
        let resignApp = !hardened || !libraryValidationDisabled   // see type comment
        let sdlRel = String(sdl.path.dropFirst(app.resolvingSymlinksInPath().path.count + 1))

        try writeSettings(settings, bundleID: bid)
        if isInstalled(app) {                                      // settings refreshed; update an outdated helper
            if helperNeedsUpdate(app, helper: helper) { try refreshHelper(app, helper: helper) }
            return
        }

        // 1. Back up originals (only the first time — never overwrite a pristine backup).
        let manifestURL = backup.appendingPathComponent("manifest.json")
        if !fm.fileExists(atPath: manifestURL.path) {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            try copyReplacing(sdl, to: backup.appendingPathComponent(sdl.lastPathComponent))
            if resignApp {
                try copyReplacing(exe, to: backup.appendingPathComponent("executable"))
                let seal = app.appendingPathComponent("Contents/_CodeSignature/CodeResources")
                if fm.fileExists(atPath: seal.path) { try copyReplacing(seal, to: backup.appendingPathComponent("CodeResources")) }
            }
            let m = Manifest(appPath: app.path, sdlRelativePath: sdlRel, resignedApp: resignApp, installed: Date())
            try JSONEncoder().encode(m).write(to: manifestURL)
        }

        do {
            // 2. Helper next to the SDL library.
            let helperDest = sdl.deletingLastPathComponent().appendingPathComponent(helperName)
            try atomicReplace(helperDest) { tmp in
                try fm.copyItem(at: helper, to: tmp)
                try sign(tmp)
            }
            // 3. SDL library: add the weak load command, re-sign (new file, swapped in atomically).
            try atomicReplace(sdl) { tmp in
                try fm.copyItem(at: sdl, to: tmp)
                try MachOPatcher.addWeakDylib(loadPath, to: tmp)
                try sign(tmp)
            }
            // 4. Re-sign the app only when macOS would reject the modified library otherwise.
            if resignApp { try signApp(app, keepEntitlements: true) }
        } catch let e as InstallError {
            throw e
        } catch {
            throw classify(error)
        }
    }

    /// The helper's version marker ("NS2RUMBLE_VERSION=<n>", a string constant in ns2rumble.c).
    /// Signatures differ per copy, so the marker, not the bytes, says whether a copy is current.
    public static func helperVersion(_ file: URL) -> Int {
        guard let d = try? Data(contentsOf: file, options: .mappedIfSafe),
              let r = d.range(of: Data("NS2RUMBLE_VERSION=".utf8)) else { return 0 }
        let digits = d[r.upperBound...].prefix(6).prefix { (0x30...0x39).contains($0) }
        return Int(String(decoding: digits, as: UTF8.self)) ?? 0
    }

    /// The copy inside the game is older than the one in NS2 Bridge.
    public static func helperNeedsUpdate(_ app: URL, helper: URL) -> Bool {
        guard isInstalled(app), let sdl = bundledSDL(in: app) else { return false }
        let installed = sdl.deletingLastPathComponent().appendingPathComponent(helperName)
        return helperVersion(installed) < helperVersion(helper)
    }

    /// Swap in the current helper (new file, then rename; re-sign the app if the install did).
    public static func refreshHelper(_ app: URL, helper: URL) throws {
        guard let bundle = Bundle(url: app), let bid = bundle.bundleIdentifier else { throw InstallError.notAnApp }
        guard let sdl = bundledSDL(in: app) else { throw InstallError.noBundledSDL }
        let fm = FileManager.default
        let dest = sdl.deletingLastPathComponent().appendingPathComponent(helperName)
        let manifestURL = backupDir(bundleID: bid).appendingPathComponent("manifest.json")
        let resigned = (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)))?.resignedApp ?? false
        do {
            try atomicReplace(dest) { tmp in
                try fm.copyItem(at: helper, to: tmp)
                try sign(tmp)
            }
            if resigned { try signApp(app, keepEntitlements: true) }
        } catch let e as InstallError {
            throw e
        } catch {
            throw classify(error)
        }
    }

    public static func uninstall(_ app: URL) throws {
        guard let bundle = Bundle(url: app), let bid = bundle.bundleIdentifier, let exe = bundle.executableURL else { throw InstallError.notAnApp }
        let fm = FileManager.default
        let backup = backupDir(bundleID: bid)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw InstallError.failed("No backup found for this game, so it can't be restored automatically. Reinstalling the game restores it.")
        }
        do {
            let sdl = app.appendingPathComponent(m.sdlRelativePath)
            let originalSDL = backup.appendingPathComponent(sdl.lastPathComponent)
            try atomicReplace(sdl) { tmp in try fm.copyItem(at: originalSDL, to: tmp) }
            try? fm.removeItem(at: sdl.deletingLastPathComponent().appendingPathComponent(helperName))
            if m.resignedApp {
                try atomicReplace(exe) { tmp in try fm.copyItem(at: backup.appendingPathComponent("executable"), to: tmp) }
                let seal = app.appendingPathComponent("Contents/_CodeSignature/CodeResources")
                let savedSeal = backup.appendingPathComponent("CodeResources")
                if fm.fileExists(atPath: savedSeal.path) { try atomicReplace(seal) { tmp in try fm.copyItem(at: savedSeal, to: tmp) } }
            }
        } catch {
            throw classify(error)
        }
        try? fm.removeItem(at: settingsURL(bundleID: bid))
        try? fm.removeItem(at: backup)
    }

    /// Rewrite a game's settings file (e.g. after the button layout or Xbox mode changes).
    public static func writeSettings(_ settings: [String: String], bundleID: String) throws {
        let url = settingsURL(bundleID: bundleID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = settings.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: "\\n"))" }
            .joined(separator: "\n")
        try ("# Written by NS2 Bridge. Applied by its helper when the game starts.\n" + body + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    /// Build the new file next to the target, then swap it in: a signed binary is never rewritten in place.
    static func atomicReplace(_ target: URL, build: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".ns2-\(UUID().uuidString)-" + target.lastPathComponent)
        defer { try? fm.removeItem(at: tmp) }
        try build(tmp)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: target)
        }
    }

    static func copyReplacing(_ src: URL, to dst: URL) throws {
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
    }

    static func sign(_ file: URL) throws {
        let r = GameAnalyzer.runStatus("/usr/bin/codesign", ["--force", "--sign", "-", file.path])
        guard r.status == 0 else { throw InstallError.failed("codesign failed: \(r.output)") }
    }

    /// Ad-hoc re-sign of the app (main executable + seal), keeping its entitlements, without the
    /// hardened runtime. Nested code keeps its own signatures.
    static func signApp(_ app: URL, keepEntitlements: Bool) throws {
        var args = ["--force", "--sign", "-"]
        if keepEntitlements { args += ["--preserve-metadata=entitlements"] }
        let r = GameAnalyzer.runStatus("/usr/bin/codesign", args + [app.path])
        guard r.status == 0 else { throw InstallError.failed("codesign failed: \(r.output)") }
    }

    static func classify(_ error: Error) -> InstallError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileWriteVolumeReadOnlyError)
            || (ns.underlyingErrors.first as NSError?)?.code == Int(EPERM) || ns.code == Int(EPERM) {
            return .permission(ns.localizedDescription)
        }
        return .failed(ns.localizedDescription)
    }
}
