import Foundation

/// Inspects a game .app to decide whether NS2 Bridge's rumble helper can hook it, and how.
public struct GameAnalysis: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case ready           // helper can load and the game calls SDL rumble
        case needsInstall    // game calls SDL rumble, but the hardened runtime blocks launch-time helpers → install into the game
        case staticSDL       // SDL is compiled into the game — calls can't be intercepted
        case hapticOnly      // game only uses SDL's haptic API (not hooked yet)
        case noRumbleCalls   // no SDL rumble calls found anywhere in the bundle
        case notAnApp
    }

    public var verdict: Verdict
    public var sdl2Calls: [String] = []
    public var sdl3Calls: [String] = []
    public var hapticCalls: [String] = []
    public var hardenedRuntime = false
    public var dyldEnvAllowed = false
    public var libraryValidationDisabled = false
    public var architectures: [String] = []
    /// Game engine family, when recognizable: drives the NSO N64 button layout.
    public var engine: Engine = .unknown
    /// SDL3 does the joystick work (native SDL3, or SDL2 through sdl2-compat): joystick layouts follow
    /// SDL3. nil = analyzed by an older version (re-analyze).
    public var sdl3Backend: Bool?
    /// The game's SDL has the HIDAPI driver the NSO N64 controller needs (nil = SDL not found in the bundle).
    public var n64DriverInSDL: Bool?
    /// Code outside SDL names the hints that switch SDL's N64 driver off, i.e. the game may do it
    /// (BattleShip does). Environment variables beat a normal hint; only the helper beats an override.
    public var changesControllerDrivers: Bool?

    public enum Engine: String, Codable, Sendable {
        case n64recomp = "N64Recomp"
        case libultraship = "libultraship"
        case unknown
    }
    public var findings: [String] = []

    /// Helper to inject (one helper handles SDL2 and SDL3).
    public var hooks: [String] { (sdl2Calls.isEmpty && sdl3Calls.isEmpty) ? [] : ["ns2rumble"] }

    public var headline: String {
        switch verdict {
        case .ready: return "Ready — rumble can be forwarded"
        case .needsInstall: return "Install the rumble helper into this game (macOS blocks launch-time helpers for this build)"
        case .staticSDL: return "Not supported — SDL is built into the game"
        case .hapticOnly: return "Not supported yet — uses SDL's haptic API"
        case .noRumbleCalls: return "No SDL rumble calls found"
        case .notAnApp: return "Not an app bundle"
        }
    }
}

public enum GameAnalyzer {
    static let sdl2Rumble = ["_SDL_GameControllerRumble", "_SDL_JoystickRumble"]
    static let sdl3Rumble = ["_SDL_RumbleGamepad", "_SDL_RumbleJoystick"]
    static let haptic = ["_SDL_HapticRumblePlay", "_SDL_HapticRunEffect"]

    public static func analyze(_ app: URL) -> GameAnalysis {
        guard let bundle = Bundle(url: app), let exe = bundle.executableURL else {
            return GameAnalysis(verdict: .notAnApp)
        }
        var a = GameAnalysis(verdict: .noRumbleCalls)

        // Architectures (the helper is universal, but note Intel-only games).
        let lipo = run("/usr/bin/lipo", ["-archs", exe.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        a.architectures = lipo.split(separator: " ").map(String.init)
        let arch = a.architectures.contains("arm64") ? "arm64" : (a.architectures.first ?? "arm64")

        // Code signature: hardened runtime strips DYLD_* unless allow-dyld-environment-variables is granted.
        let cs = run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        a.hardenedRuntime = cs.contains("(runtime)") || cs.range(of: #"flags=0x\w*1\d{4}\("#, options: .regularExpression) != nil
        let ents = run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path])
        a.dyldEnvAllowed = ents.contains("com.apple.security.cs.allow-dyld-environment-variables")
        a.libraryValidationDisabled = ents.contains("com.apple.security.cs.disable-library-validation")
        if a.hardenedRuntime {
            a.findings.append(a.dyldEnvAllowed
                ? "Hardened runtime, but it allows injected libraries."
                : "Hardened runtime without allow-dyld-environment-variables — macOS strips the rumble helper.")
        } else {
            a.findings.append("No hardened runtime — the rumble helper can load.")
        }

        // Scan every Mach-O in the bundle's code folders for SDL rumble imports / definitions.
        var staticDefs: [String] = []
        let exePath = exe.resolvingSymlinksInPath().standardizedFileURL.path
        for file in machOFiles(in: app) {
            let isMain = file.resolvingSymlinksInPath().standardizedFileURL.path == exePath
            let out = run("/usr/bin/nm", ["-m", "-arch", arch, file.path])
            if isMain {
                if out.contains("__ZN4Ship") { a.engine = .libultraship }
                else if out.contains("ultramodern") || out.contains("recomp") { a.engine = .n64recomp }
            }
            let name = file.lastPathComponent
            for line in out.split(separator: "\n") {
                let undefined = line.contains("(undefined)")
                guard let sym = line.split(separator: " ").first(where: { $0.hasPrefix("_SDL_") }).map(String.init) else { continue }
                if sdl2Rumble.contains(sym) {
                    if undefined { a.sdl2Calls.append("\(sym.dropFirst()) in \(name)") }
                    else if isMain { staticDefs.append(String(sym.dropFirst())) }
                } else if sdl3Rumble.contains(sym) {
                    if undefined { a.sdl3Calls.append("\(sym.dropFirst()) in \(name)") }
                    else if isMain { staticDefs.append(String(sym.dropFirst())) }
                } else if haptic.contains(sym), undefined {
                    a.hapticCalls.append("\(sym.dropFirst()) in \(name)")
                }
            }
        }
        checkControllerDrivers(app, exePath: exePath, staticSDL: !staticDefs.isEmpty, into: &a)
        a.sdl3Backend = !a.sdl3Calls.isEmpty || machOFiles(in: app).contains { $0.lastPathComponent.hasPrefix("libSDL3") }
        if a.sdl3Backend == true, !a.sdl2Calls.isEmpty { a.findings.append("SDL2 runs on SDL3 here (sdl2-compat): controllers use SDL3's layouts.") }
        a.sdl2Calls = Array(Set(a.sdl2Calls)).sorted()
        a.sdl3Calls = Array(Set(a.sdl3Calls)).sorted()
        a.hapticCalls = Array(Set(a.hapticCalls)).sorted()

        if !a.sdl2Calls.isEmpty { a.findings.append("SDL2 rumble calls: " + a.sdl2Calls.joined(separator: ", ")) }
        if !a.sdl3Calls.isEmpty { a.findings.append("SDL3 rumble calls: " + a.sdl3Calls.joined(separator: ", ")) }
        if !a.hapticCalls.isEmpty { a.findings.append("SDL haptic API calls: " + a.hapticCalls.joined(separator: ", ")) }
        if a.engine != .unknown { a.findings.append("Engine: \(a.engine.rawValue) — N64 controller buttons are laid out for it.") }
        if !staticDefs.isEmpty { a.findings.append("SDL is compiled into the game binary (\(staticDefs.joined(separator: ", ")))") }

        if !a.hooks.isEmpty {
            a.verdict = (a.hardenedRuntime && !a.dyldEnvAllowed) ? .needsInstall : .ready
        } else if !staticDefs.isEmpty {
            a.verdict = .staticSDL
        } else if !a.hapticCalls.isEmpty {
            a.verdict = .hapticOnly
        }
        return a
    }

    static let n64DriverHint = Data("SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC".utf8)
    /// Complete hint names (C strings, NUL-terminated) that can switch the N64's driver off. Other
    /// HIDAPI hints, e.g. SDL_JOYSTICK_HIDAPI_PS4_RUMBLE, are harmless and common.
    static let driverHints = [Data("SDL_JOYSTICK_HIDAPI\0".utf8), Data("SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC\0".utf8)]

    static func isSDL(_ file: URL) -> Bool {
        let n = file.lastPathComponent
        return n.hasPrefix("libSDL2") || n.hasPrefix("libSDL3") || n == "SDL2" || n == "SDL3"
    }

    static func contains(_ file: URL, _ needle: Data) -> Bool {
        guard let d = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return d.range(of: needle) != nil
    }

    /// Can this game's SDL read the NSO N64 controller, and does the game tamper with SDL's drivers?
    static func checkControllerDrivers(_ app: URL, exePath: String, staticSDL: Bool, into a: inout GameAnalysis) {
        let files = machOFiles(in: app)
        let sdlFiles = files.filter(isSDL)
        let exe = files.first { $0.resolvingSymlinksInPath().standardizedFileURL.path == exePath }
        if !sdlFiles.isEmpty {
            a.n64DriverInSDL = sdlFiles.contains { contains($0, n64DriverHint) }
        } else if staticSDL, let exe {
            a.n64DriverInSDL = contains(exe, n64DriverHint)
        }
        // Game code (not SDL itself) that names the HIDAPI hints. Skipped when SDL is built into the
        // executable, since SDL's own copy of the names would count.
        let gameCode = files.filter { !isSDL($0) && !$0.lastPathComponent.hasPrefix("ns2rumble") && !(staticSDL && $0 == exe) }
        a.changesControllerDrivers = gameCode.contains { f in driverHints.contains { contains(f, $0) } }

        if a.n64DriverInSDL == false {
            a.findings.append("This game's SDL is too old for the NSO N64 controller (no HIDAPI driver for it): it would read the N64 as garbage, so NS2 Bridge hides the N64 from this game. Other controllers work.")
        }
        if a.changesControllerDrivers == true {
            a.findings.append("The game changes SDL's controller drivers itself. NS2 Bridge keeps the N64 driver on: fully with the helper (Play with rumble, or installed), and against most games from Finder too.")
        }
    }

    /// Location of a "rumble-ready copy" made by NS2 Bridge 0.1 (superseded by installing into the game).
    public static func legacyCopy(of app: URL) -> URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/NS2 Bridge Games").appendingPathComponent(app.lastPathComponent)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: - Helpers

    static func machOFiles(in app: URL) -> [URL] {
        let roots = ["Contents/MacOS", "Contents/Frameworks", "Contents/PlugIns", "Contents/Resources"]
            .map { app.appendingPathComponent($0) }
        var out: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let u as URL in e {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let h = try? FileHandle(forReadingFrom: u) else { continue }
                let magic = h.readData(ofLength: 4)
                try? h.close()
                let m = [UInt8](magic)
                let isMachO = m == [0xCF, 0xFA, 0xED, 0xFE] || m == [0xCA, 0xFE, 0xBA, 0xBE] || m == [0xBE, 0xBA, 0xFE, 0xCA]
                if isMachO { out.append(u) }
                if out.count > 200 { return out }
            }
        }
        return out
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> String { runStatus(tool, args).output }

    static func runStatus(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
