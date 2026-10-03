---
title: Privacy
parent: Reference
nav_order: 4
---

# Privacy

**Nothing about you or your controllers leaves your Mac.** NS2 Bridge has no accounts, analytics or telemetry.

## Network

The only sockets are on the loopback interface (`127.0.0.1`), which other computers can't reach:

| Port | Purpose |
|---|---|
| `26761` | Games running NS2 Bridge's helper send rumble requests and driver reports; NS2 Bridge streams Bluetooth controllers back to each game's helper on a port the helper picks. |
| `26760` | The DSU server that emulators on this Mac read controllers from. |

## Internet

The only internet access is the **update check**: one HTTPS request to GitHub's public Releases API
(`api.github.com/repos/info-moed/NS2Bridge/releases/latest`) asking for the latest version. It happens only when you
click **Check for Updates** or, if you turn on **Setup → Check for updates automatically** (off by default; also
offered in the welcome tour), at most once a day. Updates are never downloaded or installed by themselves. Help and
"Report an Issue" links open in your browser.

## What's stored, and where

| What | Where |
|---|---|
| Settings, profiles, calibration, gyro offsets | NS2 Bridge's preferences (`local.ns2bridge`) |
| Battery history | `~/Library/Application Support/NS2Bridge/battery.json` |
| Per-game SDL settings, game backups | `~/Library/Application Support/NS2Bridge/games/`, `…/Backups/` |
| Login item for the SDL settings | `~/Library/LaunchAgents/local.ns2bridge.sdl-env.plist` |

To remember each controller, NS2 Bridge reads its serial number (read-only, from the controller's own memory) and
stores only a one-way **fingerprint**. N64 controllers are identified by their Bluetooth address. Full list:
[Settings and files](settings-and-files.md). **Setup → Reset NS2 Bridge…** deletes all of it.

## Sharing data with others

- **Diagnostics reports** remove your home folder path, serial numbers and Bluetooth addresses, and show you the text
  before saving.
- **Recordings** (`.ns2cap`, Diagnostics tab) can contain your controller's serial number: check them before sharing.
- **Bluetooth diagnostics** go to the macOS system log on your Mac only; replies carrying the serial number aren't logged.

## Permissions macOS asks for

**Bluetooth** (wireless controllers), **Notifications** (battery alert, optional) and **App Management** (only when
installing the helper into a game). All can be revoked in System Settings.

The legal version is [LEGAL.md](https://github.com/info-moed/NS2Bridge/blob/main/LEGAL.md) §6.
