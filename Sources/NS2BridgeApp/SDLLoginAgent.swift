import Foundation

/// Keeps the "Let SDL games and emulators use this controller" settings after logout and restart.
///
/// `launchctl setenv` only lasts until logout, so games opened from Finder right after logging in used to
/// miss the settings until NS2 Bridge ran. This writes a small per-user LaunchAgent that sets them again at
/// login, whether or not NS2 Bridge opens. Turning the switch off removes it.
///
/// Files: `~/Library/LaunchAgents/local.ns2bridge.sdl-env.plist` and
/// `~/Library/Application Support/NS2Bridge/sdl-env.sh` (plain `launchctl setenv` lines, readable).
enum SDLLoginAgent {
    static let label = "local.ns2bridge.sdl-env"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NS2Bridge/sdl-env.sh")
    }

    /// nil = remove the agent.
    static func update(_ environment: [(String, String)]?) {
        let fm = FileManager.default
        guard let environment else {
            try? fm.removeItem(at: plistURL)
            try? fm.removeItem(at: scriptURL)
            return
        }
        let quote = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\n# Written by NS2 Bridge: restores its SDL settings for games opened from Finder after login.\n"
            + environment.map { "/bin/launchctl setenv \($0.0) \(quote($0.1))" }.joined(separator: "\n") + "\n"
            + "/bin/launchctl unsetenv SDL_JOYSTICK_HIDAPI\n"
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sh", scriptURL.path], "RunAtLoad": true]
        do {
            try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            if (try? Data(contentsOf: plistURL)) != data { try data.write(to: plistURL, options: .atomic) }
        } catch {
            // Not fatal: the settings still apply until logout, as before.
        }
    }
}
