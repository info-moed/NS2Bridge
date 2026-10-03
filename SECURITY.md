# Security policy

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/info-moed/NS2Bridge/security/advisories/new). Include the version,
macOS version, steps to reproduce, and what an attacker could do. You'll get a reply as soon as the maintainer
can, and credit in the release notes if you want it.

## Supported versions

Only the latest release gets fixes. Update from the
[Releases page](https://github.com/info-moed/NS2Bridge/releases/latest).

## What's in scope

NS2 Bridge runs locally and has no accounts or telemetry. The parts that matter for security:

| Area | What to look at |
|---|---|
| **Game helper** (`Hooks/ns2rumble.c`) | Loaded into games launched from NS2 Bridge (`DYLD_INSERT_LIBRARIES`) or installed into a game's SDL library. Parses packets from the loopback stream. |
| **Game installer** (`Sources/NS2Kit/GameInstaller.swift`, `MachOPatcher.swift`) | Modifies and re-signs a game's SDL library (with a backup) when the user asks. |
| **Loopback sockets** | `127.0.0.1:26761` (rumble and driver reports from games; Bluetooth controller state back to each game's helper on a port the helper picks) and `127.0.0.1:26760` (DSU server for emulators). Not reachable from other computers, but any program on the Mac can talk to them. |
| **Force-feedback plug-in** (`Hooks/NS2FF/`) | Registered on connected controllers; loaded into games by macOS. |
| **Research channel** (`BLEDebugCommands`, off by default) | When enabled, accepts commands from local programs and sends them to a Bluetooth controller (setup, feature and read commands only; never memory writes, firmware or pairing). |
| **Login agent** (`~/Library/LaunchAgents/local.ns2bridge.sdl-env.plist`) | Re-applies SDL environment settings at login. |
| **Update check** (`Sources/NS2Kit/UpdateCheck.swift`) | Opt-in HTTPS request to GitHub's Releases API; parses the reply; never downloads or runs anything. |

Out of scope: the controllers' own firmware, and games or emulators themselves.
