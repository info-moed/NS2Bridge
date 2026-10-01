# Changelog

## 1.0.1

- **Bluetooth controllers in games** ✅, like Steam Input: in games launched from the Games tab or with the
  helper installed, a Switch 2 Pro or GameCube controller connected over Bluetooth appears as a normal SDL
  gamepad, with rumble, and gyro/accelerometer in SDL3 games (including sdl2-compat ones). It appears and
  disappears with the controller, no setup. Verified in BattleShip (with gyro) and Wave Race 64 Recompiled.
  Helper version 8: update installed copies from the Games tab.
- Over Bluetooth, motion streams whenever Motion isn't Off (no emulator needed).
- **Setup → Reset NS2 Bridge**: removes the helper from games (originals restored), the SDL settings and
  login items, and all settings and data, then relaunches fresh.
- The **welcome guide** opens on every new installation, also over settings macOS kept from an earlier one.
- Updated "coming later" texts.

## 1.0.0

First complete release: three controller families, verified on hardware where marked in the README.

**Controllers**
- **Switch 2 Pro over Bluetooth** ✅: input, gyro and rumble without Nintendo pairing. Gyro needs the IMU
  configured while it is disabled (the controller refuses otherwise); NS2 Bridge does this at every connect,
  and motion then matches USB.
- **Fast Bluetooth** ✅: **Speed** setting (Wireless tab). **Fastest**, the default, asks macOS for a 7.5 ms
  connection interval: **133 reports/s** instead of ≈ 34 at macOS's own 30 ms, gyro included. Fast = 15 ms;
  Standard = macOS's choice, documented interfaces only. Fastest steps down to Fast by itself if reports stop
  arriving.
- **Latency Test** for USB and Bluetooth; its expected values follow the Speed setting.
- **NSO GameCube controller** (new): USB and Bluetooth LE, all 16 buttons, analog L/R, both sticks,
  rumble (on/off motor driven at three strengths), live view, trigger test. Verified on hardware,
  including in a game. Corrects the public button table (Z/R-click and ZL/L-click were swapped).
- **Switch 2 Pro**: gyro and accelerometer via report 0x05, verified on hardware. **Automatic** mode (the
  default) turns motion on only while an emulator uses the Pro over DSU, so games reading the Pro directly
  keep working. Live **3D view** of the controller in the Motion tab.
- **Each controller remembers its own profile** (calibration, vibration, gyro offset, battery history),
  identified by a fingerprint of its serial number (Switch 2 family) or its Bluetooth address (N64).
- **NSO N64**: kept on SDL's own driver in every game, so it can no longer read as random input in games
  that switch that driver off (e.g. BattleShip). SDL3/sdl2-compat button numbering handled.

**Games**
- The helper (v5) now also: keeps SDL's N64 driver on even against override-priority hints; rescales stick
  values of controllers SDL reads through IOKit so full tilt reads 100% (GameCube was ≈ 60%, Pro ≈ 81%);
  reports each Nintendo controller's SDL driver to NS2 Bridge, with a warning in the Games tab.
- **Update helper in game** for installed copies; installed games' settings refresh automatically.
- Analyzer: flags games that change SDL's controller drivers, detects sdl2-compat, and hides the N64 from
  games whose SDL is too old to read it.
- Firmware-independent SDL mappings for the Pro and GameCube.

**Emulators**
- **DSU (CemuHook) server** on `127.0.0.1:26760` for every controller: buttons, sticks, analog triggers,
  motion (Switch 2 Pro). Verified with the GameCube over USB and Bluetooth through a DSU client.

**Fixes and polish**
- N64 driver override is now N64-only: games that switch SDL's other drivers off (e.g. for Raphnet
  adapters) keep that choice.
- Menu bar: one item holds all controller pills (no flicker, remembers its place), faster click menu, and a
  hint if the menu bar is too full to show it.
- Rumble goes to the exact controller when two of the same kind are in one game.
- DSU slots for players 5 and up; the Finder-wide game settings survive logout (login agent).
- Capture tool asks for confirmation when a press disagrees with the button table; supports the GameCube.
- Trigger test only fails on real faults; a fast press gives a tip instead.
- People updating from an earlier version start in Advanced mode. US English throughout.

**App**
- **Welcome guide** on first launch (five short pages: connect, play, adjust, choose a mode) and
  **Basic / Advanced** modes: Basic shows the everyday tabs, Advanced adds Button Test, Motion,
  Latency Test and Diagnostics. Switch in the sidebar or Setup; reopen the guide from Setup.
- Menu bar: one pill per controller in its player color (P1 blue, P2 red, P3 yellow, P4 green…).
  Click for its menu, double-click to turn it off.
- **Turn off** wireless controllers to save battery, with a confirmation (also by double-click or
  right-click on a controller in the app).
- Redrawn GameCube live view; player colors unified.

**Docs and research**
- Rewritten README, install guide, architecture and development notes, legal notice and third-party notices.
- `research/`: raw captures, measurements and scripts behind every protocol finding, and how they were
  collected. The project is AI-assisted; this is stated in the README and research notes.
- Tools: `scripts/sdl-check.sh` (checks a game's own SDL against Nintendo controllers),
  `NS2Bridge --render-drawings`.

## 0.2.0 (not released separately; included in 1.0.0)

- **NSO N64 controller** support over USB:
  - live view, button test, stick calibration, rumble
  - rumble from games launched from NS2 Bridge
  - a correct N64 button layout (C-buttons, Z, R) for N64Recomp and libultraship ports
- **Multiple controllers at once:**
  - player slots P1–P4, with player lights set to match
  - a controller picker at the top of the window
  - every tool (Calibrate, Button Test, Haptics, Latency, Diagnostics) works on the selected controller
- **Profiles** per controller type: stick calibration, deadzones, vibration on/off and strength.
  Earlier settings carry over into the "Default" profile.
- Game analysis detects the N64Recomp and libultraship engines.
- **N64 over Bluetooth:** after pairing in macOS settings, NS2 Bridge switches the controller to full reports and enables vibration (untested).
- **Fixed:** unplugged or reconnected controllers stayed listed, or were added twice. HID removal now matches the device object itself, with a once-a-second sweep and a "no signal" state.
- **Battery tab:**
  - live voltage (N64: subcommand 0x50; Switch 2: command 0x0B) and a history chart
  - estimated cycles, charge/drain rate and time to full/empty
  - charge-limit alert (the controllers can't be told to stop charging)
  - per-controller voltage-curve calibration and a battery-life test
- **Rumble without changing games:** an NS2FF.plugin ForceFeedback plug-in, registered on the controller.
- **The rumble helper is rewritten:** one helper covers SDL2 and SDL3. It redirects the game's own
  symbol pointers, so it works under the hardened runtime and with SDL loaded late, and it reads
  per-game settings.
- **"Install rumble into game"** replaces rumble-ready copies. The originals are backed up, and
  "Remove helper from game" restores them.
- Octagonal N64 stick gate, in the calibration view and the output.
- The N64 diagram was fixed (Home/Capture swapped; stick and Z moved lower).
- Game rumble skips the main thread.

## 0.1.0 (first public version)

- Plug-and-play USB support for the Switch 2 Pro Controller. It's set up automatically on plug-in,
  and again after sleep.
- All 21 buttons and both sticks, verified on hardware.
- Menu-bar app with Controller, Calibrate Sticks, Button Test, Haptics, Games, Wireless, Latency Test,
  Diagnostics and Setup tabs.
- HD Rumble 2 encoder (low and high band per motor, amplitude cap 450).
- Games tab:
  - checks each game's rumble support
  - launches SDL2/SDL3 games with rumble forwarding
  - makes rumble-ready copies for games whose signing blocks the helper
  - confirms rumble live while you play
- Xbox compatibility mode and a choice of button layout (positions or labels).
- Experimental Bluetooth LE mode with a report-rate and interval readout.
- Latency test with expected vs. measured results.
- `ns2probe` command-line tool for reverse engineering.
- Universal build (Apple Silicon + Intel), ad-hoc signed. No Apple Developer account needed.
