<p align="center"><img src="docs/icon.png" width="128" alt="NS2 Bridge icon"></p>

# NS2 Bridge

**Nintendo Switch 2 Pro, NSO GameCube and NSO N64 controllers on your Mac**: plug-and-play input for
SDL games and emulators, rumble in games, gyro for emulators, calibration, diagnostics and a
latency test. Native Swift app, no drivers to install, **no Apple Developer account needed**.

> **Unofficial.** Not affiliated with or endorsed by Nintendo, Microsoft or Apple. See [LEGAL.md](LEGAL.md).

---

## Why

- A **Switch 2 Pro** or **Switch 2 NSO GameCube** controller plugged into a Mac **sends nothing** until
  a host sends it a start-up command. NS2 Bridge sends it the moment you plug one in.
- Games read these controllers through SDL, which on macOS can't make them rumble, reads the
  GameCube's sticks at only ~60% of their travel, and in some games (e.g. BattleShip) is told to switch
  off the driver the **N64** controller needs, so its input goes haywire. NS2 Bridge fixes all three.
- Emulators want gyro over DSU (CemuHook). NS2 Bridge serves every connected controller that way.

## What works

✅ = verified on real hardware. 🧪 = built and unit-tested, not yet tried on a real controller.

| | Switch 2 Pro | NSO GameCube | NSO N64 |
|---|---|---|---|
| Plug-and-play USB (set up on plug-in and after sleep) | ✅ | ✅ | ✅ |
| All buttons, sticks (+ GameCube analog triggers) | ✅ 21 buttons | ✅ 16 buttons, analog L/R | ✅ 17 buttons |
| Rumble tests in the app | ✅ HD Rumble 2, both motors/bands | ✅ | ✅ |
| **Rumble in games** (helper: SDL2 and SDL3) | ✅ Wave Race 64 Recomp, BattleShip | ✅ BattleShip | ✅ Wave Race 64 Recomp, BattleShip |
| Full stick range in games (NS2 Bridge's calibration applied) | 🧪 | ✅ (was ~60%) | ✅ (SDL's own driver) |
| Bluetooth | ✅ input and gyro, **133 reports/s** (7.5 ms) | ✅ (7.5 ms setting 🧪) | 🧪 (pair in macOS settings) |
| **Games over Bluetooth** (helper's virtual gamepad, like Steam Input) | ✅ BattleShip (with gyro), Wave Race 64 Recomp | 🧪 | — (macOS shows it to games itself) |
| Turn off to save battery (wireless) | 🧪 | ✅ | 🧪 |
| Gyro / accelerometer (+ live 3D view) | ✅ USB and Bluetooth | — (none) | — (none) |
| DSU (CemuHook) server for emulators | ✅ incl. gyro | ✅ buttons, sticks, triggers | ✅ buttons, stick |
| Battery level / voltage | ✅ level | ✅ level | ✅ voltage |

And for every controller:

- **Games tab:** checks how a game does rumble and fixes what it can, launches games with rumble,
  or installs a small helper into games whose signing blocks that (originals backed up, one click to
  restore). ✅ Verified with BattleShip; the installed helper can be updated in place.
- **Protection against broken N64 input:** keeps SDL's N64 driver on in every game and warns you if a
  game still ends up misreading it. ✅ Verified against BattleShip, which switches the driver off.
- **Menu bar:** one pill per controller in its player color (**GC** blue = P1, **N64** red = P2,
  **PC2** yellow = P3, green = P4…). Click for its menu, double-click to turn it off. ✅
- **Each controller remembers its own settings:** its own profile (calibration, vibration, gyro offset)
  comes back whenever it reconnects, by cable or Bluetooth. ✅
- **Calibration:** sticks (live trace, deadzones), GameCube analog triggers (trigger test), gyro offset.
- **Diagnostics:** button test, live color-coded report bytes, recordings, latency test, battery history.
- **Multiple controllers:** players P1–P8 with player lights, per-type profiles. ✅ Tested with two at once.
- 🧪 Rumble with no changes to games (macOS force-feedback plug-in): works in a test harness, not yet
  confirmed in a real game.
- ❌ Native Mac games that use Apple's GameController framework: that needs a DriverKit driver, which
  needs a paid Apple Developer account.

## Install

**Short version:** download `NS2Bridge-1.0.1-macOS.zip` from [Releases](https://github.com/info-moed/NS2Bridge/releases), drag **NS2 Bridge.app** to
Applications, and allow it once in **System Settings → Privacy & Security → Open Anyway**. Plug in a
controller with a USB-C **data** cable.

Full instructions, permissions and uninstall steps: **[docs/INSTALL.md](docs/INSTALL.md)**.

### Build from source

```bash
git clone https://github.com/info-moed/NS2Bridge.git && cd NS2Bridge
./scripts/build-app.sh          # → build/NS2 Bridge.app
./scripts/package.sh            # clean build + tests → dist/NS2Bridge-<version>-macOS.zip + .sha256
```

Requires macOS 15+ and Xcode 16+ (or just its command-line tools). The result is a universal build
(Apple Silicon + Intel), ad-hoc signed.

## Using it

NS2 Bridge lives in the menu bar and has one window. On first launch a **five-page welcome guide**
walks you through connecting, playing and adjusting, then lets you pick **Basic** (the everyday tabs) or
**Advanced** (everything). Switch any time at the bottom of the sidebar or in Setup, where the guide can
also be reopened.

The chips across the top of the window are the connected controllers (P1, P2, …); the tools act on the
one you pick. Double-click a chip (or its menu bar pill) to turn that controller off; right-click for more.

Basic mode shows Players & Profiles, Controller, Calibrate Sticks, Haptics, Games, Wireless, Battery and
Setup. Advanced adds Button Test, Motion, Latency Test and Diagnostics.

| Tab | What it does |
|---|---|
| **Players & Profiles** | Player numbers (swap them here), each controller's own profile, turn off. |
| **Controller** | Live picture of the controller: buttons light up, sticks move, triggers fill. |
| **Calibrate Sticks** | Let go (center), then roll the sticks around the edge (range). GameCube: trigger test too. |
| **Button Test** | Every button turns green once it's been pressed. |
| **Haptics** | Test effects, left/right motors, low/high bands, strength. |
| **Motion** | Gyro (Automatic / Always on / Off), live 3D view, gyro calibration, DSU server for emulators. |
| **Latency Test** | 10-second test: measured vs expected, histogram, verdict. USB and Bluetooth. |
| **Battery** | Level, voltage, history chart, cycle estimate, charge alert, curve calibration, life test. |
| **Games** | Add games, see what works, launch with rumble, install/update/remove the helper. |
| **Wireless** | Bluetooth: N64 via macOS settings; Switch 2 Pro and GameCube via **Connect** + SYNC. |
| **Diagnostics** | Report rate, live report bytes, reconnect, record to file. |
| **Setup** | SDL switch, force-feedback rumble, Xbox mode, button layout, open at login. |

### Games

Games that use SDL (most emulators and PC ports) see the controllers as gamepads once **Setup →
Let SDL games and emulators use this controller** is on. For **rumble**, full **stick range** and the
**N64 driver guard**, the game needs NS2 Bridge's helper:

1. **Games → Add game…** and pick the app. NS2 Bridge checks it and shows one of:
   - **Ready:** click **Play with rumble** (the helper attaches at launch).
   - **Install the rumble helper into this game:** macOS blocks launch-time helpers for this build.
     One click installs it inside the game, with the originals backed up; then it works however you
     launch the game. **Update helper in game** appears when NS2 Bridge has a newer helper.
   - **Not supported:** SDL is built into the game, or it has no rumble. You can still play.
2. A live checklist confirms: game launched → helper attached → rumble received. Each game's row
   also shows which SDL driver the last run gave each controller.

Some games have their own stick sensitivity and deadzone settings (e.g. BattleShip: 20% deadzone).
Those still apply on top.

### Emulators with gyro (DSU / CemuHook)

The DSU server runs on `127.0.0.1:26760` (Motion tab). Player 1 is slot 1 (index 0), and so on.

- **Dolphin:** Controllers → Alternate Input Sources → DSU Client → add `127.0.0.1`, port `26760`.
- **Cemu:** Input settings → API "DSUController".
- **Ryujinx:** Input → Motion → "CemuHook compatible", `127.0.0.1:26760`.

Gyro on the Switch 2 Pro is **Automatic** by default (Motion tab): it turns on while an emulator is using
the Pro over DSU and off again when it stops, because while motion flows, games reading the Pro through
SDL directly can't see it. The Motion tab shows a live 3D model of the controller to check the readings.

### Wireless

- **N64:** pair once in macOS Bluetooth settings (hold SYNC); then press any button to reconnect.
- **Switch 2 Pro, GameCube:** Wireless → **Connect**, unplug the cable, hold the small **SYNC** button.
- **Speed** (Wireless tab): **Fastest** = one report every **7.5 ms** (133/s; USB: 4 ms), the default.
  macOS on its own would use 30 ms, because the controller never asks for faster; NS2 Bridge asks macOS for
  a shorter interval (a private macOS call, so a future macOS may ignore it; it then runs at 30 ms). Fast
  (15 ms) and Standard (30 ms) use less of the controller's battery. The Latency Test tab shows what you get.
- **Games over Bluetooth** work like Steam Input: in games launched from the Games tab or with the helper
  installed, NS2 Bridge's helper presents the Bluetooth controller as a normal SDL gamepad, with rumble, and
  gyro in SDL3 games (SDL 2.24 or later needed). Games started any other way don't see Bluetooth controllers.

## Troubleshooting

| Problem | Fix |
|---|---|
| Controller charges but never connects | Use a **data** USB-C cable; try another port. |
| No input in a game | Turn on **Setup → Let SDL games…**, then quit and reopen the game. |
| N64 input goes haywire in a game | Launch it from **Games** (or install the helper). The game switches SDL's N64 driver off; the helper keeps it on. The Games row shows a warning if it happens. |
| Sticks don't reach the edge in a game | Launch from **Games** or update the helper; calibrate the sticks. Check the game's own sensitivity/deadzone. |
| No rumble in a game | Start it from **Games → Play with rumble** and check the game's own rumble setting. |
| "…exclusive access" when connecting | Another app (often a browser tab using WebUSB) holds the controller. Close it, click **Reconnect**. |
| macOS asks for permissions again after an update | Expected with ad-hoc signing. Approve again. |

Developers: `./scripts/sdl-check.sh /path/to/Game.app` runs a game's own SDL, acts like the worst-case
game, and reports whether Nintendo controllers get SDL's own drivers with no phantom input.

## How it works

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**: the design.
- **[docs/PROTOCOL.md](docs/PROTOCOL.md)**: the controller protocols. Every fact is marked as verified
  on hardware, documented elsewhere, or unknown.
- **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**: maintainer notes, hard-won facts, test tools, releasing.

## Roadmap

1. Hardware confirmation of the remaining 🧪 items above (N64 over Bluetooth, the GameCube at 7.5 ms).
2. Gyro-to-mouse; decoding the motion data packed inside the Pro's normal report.
3. Bluetooth controllers in games that don't use SDL (a HID-level layer, like Steam Input's).
4. Joy-Con 2.

## Credits

Built on public research by the community, especially
[ndeadly's switch2_controller_research](https://github.com/ndeadly/switch2_controller_research),
[SDL](https://github.com/libsdl-org/SDL), [dekuNukem's Switch notes](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering),
[Dolphin](https://github.com/dolphin-emu/dolphin) and [libultraship](https://github.com/Kenix3/libultraship).
Details: **[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)**.

## Legal

MIT licensed (**[LICENSE](LICENSE)**). In short:

- Independent project, not affiliated with any company named here.
- No Nintendo code, firmware, keys, games or logos are included; the drawings and icon are original.
- The protocols were learned for interoperability from lawfully owned controllers and public documentation.
- A game with the helper installed is for your own use; don't redistribute modified games.

Full details and the privacy statement: **[LEGAL.md](LEGAL.md)**.
