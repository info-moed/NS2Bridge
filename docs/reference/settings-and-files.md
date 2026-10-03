---
title: Settings and files
parent: Reference
nav_order: 6
---

# Settings and files

Everything NS2 Bridge stores or sets up on a Mac, and therefore everything **Setup → Reset NS2 Bridge…** removes.

## Preferences (`local.ns2bridge`)

Read with `defaults read local.ns2bridge`.

| Key | What |
|---|---|
| `ui.advanced` | Advanced tools shown |
| `ui.intro` | Startup animation on (default) |
| `welcome.install`, `welcome.done` | Which installation finished the welcome tour |
| `profiles` | Controller profiles: stick calibration, deadzones, vibration, per controller |
| `gyro.bias` | Gyro offsets per physical controller |
| `motion.mode` | Motion: `automatic`, `on`, `off` (older versions: `motion.enabled`) |
| `dsu.enabled` | DSU server on |
| `sdl.enabled` | "Let SDL games and emulators use this controller" |
| `ff.enabled` | Rumble through macOS force feedback |
| `xbox.mode`, `button.layout` | Xbox mode; button layout (`positions` or `labels`) |
| `bluetooth.speed` | `fastest`, `fast` or `standard` |
| `battery.alert.enabled`, `battery.alert.percent` | Charge limit alert |
| `games`, `games.verified`, `games.analysis` | Games added in the Games tab, which ones were confirmed working, and their analysis |
| `reset.message` | Shown once after a reset that couldn't restore a game |
| `updates.auto`, `updates.lastCheck` | Check for updates automatically (off by default); when it last checked |
| `app.lastVersion` | The version that last ran (to show What's New once after an update) |
| `NSStatusItem …` | Menu bar item position (written by macOS) |

Research flags, off unless set by hand (see [DEVELOPMENT.md](../DEVELOPMENT.md)):

| Key | What |
|---|---|
| `BLEDebugCommands` | Accept research commands for a Bluetooth controller from local programs |
| `BLELatencyCritical` | Try a private Bluetooth connect option (needs an Apple entitlement; no effect) |

Older versions also used `cal.left`, `cal.right`, `haptics.enabled` and `haptics.intensity`; they're moved into
`profiles` and removed on first launch.

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/NS2Bridge/battery.json` | Battery history per controller |
| `~/Library/Application Support/NS2Bridge/games/<bundle id>.env` | Per-game SDL settings the helper applies |
| `~/Library/Application Support/NS2Bridge/Backups/<bundle id>/` | A game's original files before the helper was installed (with `manifest.json`) |
| `~/Library/Application Support/NS2Bridge/sdl-env.sh` | Script that re-applies the SDL settings at login |
| `~/Library/LaunchAgents/local.ns2bridge.sdl-env.plist` | The login agent that runs it |

## Outside these

- **Login item** ("Open NS2 Bridge at login"): registered with macOS (System Settings → General → Login Items).
- **SDL environment** (`SDL_GAMECONTROLLERCONFIG`, `SDL_JOYSTICK_MFI`, `SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC`):
  set for apps you open with `launchctl setenv` while "Let SDL games…" is on.
- **Games with the helper installed:** `ns2rumble.dylib` next to the game's SDL library, plus one load command in
  that library. Reset restores the originals from the backup.
- **Force-feedback plug-in:** registered on connected controllers while NS2 Bridge runs; removed when it quits.
