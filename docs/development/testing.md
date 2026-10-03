---
title: Testing
parent: For developers
nav_order: 1
---

# Testing

## Automated (no controller needed)

```bash
swift test
```

The unit tests (`Tests/NS2KitTests/`) cover the parts that can be checked without hardware: report parsing for all
three controllers, HD Rumble 2 and original-Switch rumble encoding, stick and trigger calibration, motion decoding
(scales, axes, clock detection, timestamp wrap), the orientation filter, the DSU protocol (framing, pad layout, a
full server round trip), SDL mappings, the game installer's Mach-O patching, rumble routing (including the Bluetooth
target), the Bluetooth speed levels, the research channel's command allowlist, the virtual-gamepad packet layout the
helper parses, and the demo's synthetic report 0x05. One test replays a real GameCube capture from `research/`.

CI runs these on every push and pull request, plus a warnings-as-errors build of the helper and plug-in, the check
tools for SDL2 and SDL3, `shellcheck`, a link check and a privacy scan (see `.github/workflows/ci.yml`).

## With a game's own SDL

| Script | Checks |
|---|---|
| `./scripts/sdl-check.sh <Game.app>` | With a controller on USB: the game's SDL gives each Nintendo controller SDL's own driver, with no phantom input, even when the game tries to switch drivers off. |
| `./scripts/vpad-check.sh <Game.app>` | With a Switch 2 controller on Bluetooth: the game's SDL sees NS2 Bridge's virtual gamepad, with live values and (SDL3) motion. |

## Hardware QA checklist (each release)

Run on a real Mac with real controllers; record the result in the release's tracking issue. Mark anything not tried
as 🧪 in the docs.

**Every controller, USB and Bluetooth**
- [ ] Connects; menu bar pill shows the right player number and battery; player lights match.
- [ ] Controller tab: every button lights up (Button Test reaches all buttons); sticks and GameCube triggers move.
- [ ] Calibrate Sticks completes; GameCube trigger test passes.
- [ ] Haptics test effects play (Pro: both motors, both bands; GameCube: three strengths).
- [ ] Turn off (double-click the pill) drops a wireless controller.

**Switch 2 Pro**
- [ ] Motion tab: 3D view follows the controller over USB and Bluetooth; gravity points up; Calibrate gyro succeeds.
- [ ] Bluetooth: Latency Test shows ~133 Hz at Fastest, ~67 at Fast, ~34 at Standard.

**Games** (BattleShip, Wave Race 64 Recompiled, or similar)
- [ ] Launched from the Games tab: input, rumble, full stick range; the checklist confirms the helper.
- [ ] Over Bluetooth: the controller appears in the game, rumble works; gyro in an SDL3 game.
- [ ] Installed helper: works when the game is opened from Finder; Update and Remove restore cleanly.
- [ ] N64: the game's row shows SDL's own driver.

**Emulators**
- [ ] A DSU client receives buttons, sticks, GameCube triggers and Pro gyro (`research/scripts/dsu_motion_monitor.py`
      or a real emulator).

**App**
- [ ] A fresh install shows the welcome tour; Demo mode works without a controller.
- [ ] Diagnostics report exports with no home path, serial or full Bluetooth address.
- [ ] Reset NS2 Bridge removes everything in [Settings and files](../reference/settings-and-files.md).
