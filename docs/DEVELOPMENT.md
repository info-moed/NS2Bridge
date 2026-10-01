# Development notes

For contributors and maintainers: how to build and test, what's verified, and the facts that took the
longest to find out. User-facing docs: [../README.md](../README.md). Design: [ARCHITECTURE.md](ARCHITECTURE.md).
Protocols: [PROTOCOL.md](PROTOCOL.md). Evidence: [../research/](../research/).

NS2 Bridge is developed with AI assistance (Anthropic's Claude via Claude Code), directed and
hardware-tested by the maintainer; see [research/README.md](../research/README.md#how-this-project-was-made-ai-assisted).

## Build, test, release

```bash
swift build && swift test            # 43 unit tests (one replays a real GameCube capture from research/)
./scripts/build-app.sh               # → build/NS2 Bridge.app (universal, ad-hoc signed)
./scripts/package.sh                 # clean → tests → icon → app → dist/NS2Bridge-<version>-macOS.zip + .sha256
```

- Version: `Resources/Info.plist` (`CFBundleShortVersionString`); the plug-in has its own in `Hooks/NS2FF/Info.plist`.
- Bump `NS2RUMBLE_VERSION` in `Hooks/ns2rumble.c` whenever the helper changes, so installed copies get
  an **Update helper in game** button.
- Settings live in the UserDefaults domain `local.ns2bridge`; data in
  `~/Library/Application Support/NS2Bridge/` (`battery.json`, `games/<bundle id>.env`, `Backups/<bundle id>/`).
- Build releases from a neutral path (e.g. a fresh clone in `/tmp`): Swift embeds source paths in the
  binary for runtime error messages.

### Test tools

| Tool | Use |
|---|---|
| `.build/debug/ns2probe` | Probe CLI: `info`, `init`, `stream --out x.ns2cap`, `buttons` (guided), `press`, `hid <pid>`, `rumble`, `analyze <App>`, `sdl-mapping`. No arguments prints help. |
| `scripts/sdl-check.sh <Game.app> [seconds]` | Links `tools/sdlcheck.c` against the game's own SDL, simulates a hostile game, prints each Nintendo controller's SDL driver and phantom input. `SDLCHECK_HOSTILE=none|normal|override`, `SDLCHECK_AXES=1` (stick range as the game sees it), `NO_HELPER=1`, `NO_SETTINGS=1`. |
| `NS2Bridge --render-drawings <dir>` | Saves the controller drawings and the five welcome pages as PNGs (light and dark) and quits, without touching controllers. (Buttons and switches show as placeholders off-screen.) |
| `defaults delete local.ns2bridge welcome.done` | Shows the welcome guide again on next launch. |
| `research/scripts/*.py` | Capture reader and the analyses behind FINDINGS.md; `dsu_monitor.py` is a minimal DSU client. |

## Status

✅ verified on hardware · 🧪 built and unit-tested only

| Area | Status |
|---|---|
| Switch 2 Pro, USB: wake-up, 21 buttons, sticks, battery, HD Rumble 2, game rumble | ✅ |
| Switch 2 Pro: gyro via 0x05 (scale checked against the accelerometer), Automatic motion, 3D view, serial read | ✅ |
| Switch 2 Pro over BLE: connect, input (≈ 34/s), input switched to 0x05 by subscription | ✅ |
| Switch 2 Pro over BLE: gyro (IMU fields stay zero; see research §2b) | ❌ in progress |
| Switch 2 Pro: stick rescaling in games, player lights, battery voltage | 🧪 |
| Per-controller profiles (Pro verified; N64 and GameCube by the same code path) | ✅ |
| NSO GameCube, USB and BLE: all buttons, analog triggers, sticks, rumble, game input + rumble, turn off | ✅ |
| NSO N64, USB: everything; SDL driver guard; BattleShip | ✅ |
| NSO N64 over classic Bluetooth, turn off | 🧪 |
| Helper installed into a game (install, update in place), launch-time helper | ✅ |
| Force-feedback plug-in in a real game | 🧪 (harness only) |
| DSU server | ✅ via a scripted client; 🧪 with a real emulator |
| Menu bar items, confirmations, trigger test UI | ✅ / 🧪 (trigger test: unit-tested and replayed on a real capture) |
| Welcome guide and Basic/Advanced modes | ✅ appears on first launch; pages checked with `--render-drawings` |
| Intel Macs | 🧪 never run |

## Hard-won facts

1. **`IOCFPlugInTypes` on a HID device already holds macOS's own plug-in entries.** Merge, never replace:
   replacing makes the controller unopenable by every app until it's replugged. The ForceFeedback framework
   rejects absolute plug-in paths; use a path relative to `/System/Library/Extensions` (`"../../.." + path`).
2. **Never rewrite a signed Mach-O in place.** The kernel kills processes that load a changed signed file.
   Write a new file and swap it in (`GameInstaller.atomicReplace`, `MachOPatcher … options: .atomic`).
3. **sdl2-compat:** some games' `libSDL2-2.0.0.dylib` is sdl2-compat, which loads `libSDL3.0.dylib` from the
   same folder and aborts if it's missing. Joysticks then follow SDL3's layouts (research §5).
4. **The hardened runtime strips `DYLD_*`**; disable-library-validation allows ad-hoc-signed libraries.
   Rewriting the game's symbol pointers works in both cases; `__interpose` is unreliable for libraries
   loaded through a load command in hardened processes.
5. **Switch 2 command replies** are `cmd, 0x01, 0x00, sub, 0x00, 0xF8, …`. `03 91 00 0A … <id>` **selects
   the input report format** (0x09 Pro, 0x0A GameCube, 0x05 common); it is not "haptic enable". Battery:
   `0B 91 00 03` → mV at reply[8..9]; `0B 91 00 04` → status bytes.
6. **IMU scales:** gyro at bytes 55–60 of report 0x05 (byte 47 is temperature), 16.4 LSB per °/s and
   4096 LSB per g; early public notes had this wrong. The 0x09 motion is packed (research §7).
7. **N64 polling:** the controller produces a report every 15 ms; USB polls at 8 ms and faster polling
   doesn't help. Setting `ReportInterval` changes the property but gives no reliable gain.
8. **SDL GUIDs:** Switch 2 Pro (IOKit) `030002697e0500006920000001020000`; N64 HIDAPI (SDL 2.32 and 3)
   `030070d67e050000192000001202680c`. SDL strips the CRC and retries without the version (research §9).
9. **The N64 must use SDL's HIDAPI driver.** Through IOKit its reports are misread (research §3). Some games
   switch HIDAPI off (BattleShip, research §4): environment variables beat normal-priority hints, only the
   helper beats override priority.
10. **Games see IOKit-read sticks at the raw range** (GameCube ≈ 60%, Pro ≈ 81%); the helper rescales
    (research §6).
11. **GameCube:** ndeadly's 0x0A table swaps Z/R-click and ZL/L-click; the motor is on/off only; BLE input
    and rumble use their own characteristics (research §1–2).
12. **libultraship games** pump events with `SDL_PeepEvents`, not `SDL_PollEvent`; N64Recomp games use
    `SDL_PollEvent`. Both read sticks by polling `SDL_GameControllerGetAxis`. libultraship takes the
    furthest-pushed of all connected pads per direction, then applies its own deadzone and N64 octagon.
13. **`launchctl setenv` is lost at logout/reboot**, so a per-user LaunchAgent
    (`~/Library/LaunchAgents/local.ns2bridge.sdl-env.plist` running `~/Library/Application Support/NS2Bridge/sdl-env.sh`)
    re-applies the Finder-wide SDL settings at login while the Setup switch is on.
14. **Identity:** the Pro's USB serial string is just "00"; the real serial is in flash at 0x13000
    (`02 91 00 01 … addr`, 0x50-byte reply, data from 0x10, serial at data+2; read-only, as SDL does). Only a
    SHA-256 fingerprint is stored.
15. **SceneKit's default camera near plane is 1 unit**: a model 0.15 units wide at 0.4 units is invisible
    until `zNear` is lowered.
17. **Bluetooth input reports are chosen by subscription**, one input characteristic at a time; the USB
    "select input report" command does nothing over BLE. In zsh, `log` is a builtin: use `/usr/bin/log`.
18. **Bluetooth motion needs the IMU configured while disabled** (`0C 05` → `0C 06` → `0C 04`, flag 0x04),
    and BLE commands must go one at a time, each after its reply (PROTOCOL §6).
19. **macOS lets a central ask for a 7.5 ms interval** through the private
    `setDesiredConnectionLatency:forPeripheral:` with bluetoothd level −12 (−25 looks faster on paper but
    collapses the stream). BLELink sends it at every connect (`BluetoothSpeed`).
20. **Research aid:** `defaults write local.ns2bridge BLEDebugCommands -bool true` makes NS2 Bridge accept
    distributed notifications `local.ns2bridge.debug.ble` (`cmd <hex>`, `sub 05|own`, `latency <level>`,
    `hps 1 <ms>`, `rate <hex>`; only setup, feature, light, vibration, battery and flash-*read* commands are accepted: `BLELink.debugAllowed`),
    for trying commands on a live connection without restarting. Off by default; see `BLELink.debugCommand`.
16. **Per-driver HIDAPI hints win over the master hint** in SDL2 and SDL3, which is what makes the N64-only
    override possible.

## Open questions and next steps

1. Switch 2 Pro on hardware: gyro in a real emulator (Dolphin's DSU client), stick rescaling in a game,
   player lights; controller battery drain at 7.5 ms; the GameCube at 7.5 ms. (C vs Capture and the gyro scale are settled: research §7a, §8.)
2. N64 over classic Bluetooth and its turn-off.
3. Force-feedback plug-in in a real game (a game that doesn't use the helper).
4. Controllers visible to games over Bluetooth (a virtual SDL controller inside the helper).
5. Gyro-to-mouse; decoding the 0x09 packed motion (starting point in `research/scripts/pro2_packed_motion.py`).
6. Joy-Con 2.

## Known issues and limits

- If NS2 Bridge crashes, the force-feedback registration stays on the controller until it's replugged
  (harmless: the plug-in only sends local UDP). It points into the app bundle, so restart the app after
  moving it.
- Ad-hoc signing: macOS privacy prompts can reappear after updates.
- Game rumble for two controllers of the same kind in one game goes to the lower-numbered player.
- Over Bluetooth, the Switch 2 Pro and GameCube are available to NS2 Bridge and DSU clients only, not to
  games reading SDL directly.

## Publishing to GitHub

Releases are published from a clean export (single commit, neutral author) so no personal paths or
identity end up in the history:

```bash
git init NS2Bridge && cd NS2Bridge            # a fresh copy of the tree, no build outputs
git config user.name "NS2 Bridge"
git config user.email "ns2bridge@users.noreply.github.com"
git add -A && git commit -m "NS2 Bridge 1.0.0"
git tag v1.0.0
git remote add origin https://github.com/<your-account>/NS2Bridge.git
git push -u origin main --tags
```

Then create a GitHub release for `v1.0.0` and attach `NS2Bridge-1.0.0-macOS.zip` (paste its SHA-256 in
the notes). Use a GitHub account that doesn't show your personal details if you want to stay anonymous.
