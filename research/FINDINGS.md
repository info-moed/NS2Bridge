# Findings

Measured on real controllers (see [README.md](README.md) for hardware and methods). Each finding says
how it was measured and how to reproduce it. "SDL" means the SDL library that games bundle.

---

## 1. NSO GameCube controller over USB (report 0x0A)

*Reproduce:* `python3 scripts/gamecube_usb.py` (capture `captures/gamecube-usb-buttons.ns2cap`).

- **Wake-up:** same 0x91 start-up commands as the Switch 2 Pro, with report format `0A`. It then streams
  report `0x0A` at **≈ 252 per second** (one every 4 ms). Before that it sends nothing.
- **Buttons** (bytes 3–5 as one little-endian 24-bit word; every button pressed alone):

  | Bit | Button | Bit | Button | Bit | Button |
  |---|---|---|---|---|---|
  | 0 | B | 8 | D-pad ↓ | 16 | Home |
  | 1 | A | 9 | D-pad → | 17 | Capture |
  | 2 | Y | 10 | D-pad ← | 20 | C |
  | 3 | X | 11 | D-pad ↑ | | |
  | **4** | **R, full-press click** | **12** | **L, full-press click** | | |
  | **5** | **Z** | **13** | **ZL** | | |
  | 6 | Start | | | | |

  **Correction to the public notes:** ndeadly's table has Z and the R click (bits 4/5), and ZL and the
  L click (bits 12/13), swapped. The evidence: while bit 5 or 13 was held the analog triggers sat at
  rest (≈ 33); bit 4 and bit 12 only set with the matching analog trigger at ≈ 216–219 of 255.
- **Analog triggers** (bytes 13 = L, 14 = R): rest ≈ 30–36, full travel ≈ 219–223, click fires at ≈ 216–218.
- **Sticks** (bytes 6–8 control stick, 9–11 C-stick, 12-bit packed): center ≈ 1993/2111 and 2030/2033;
  reach ≈ 1160–1240 from center, with the gate only ≈ 4% longer on the diagonals (a near-round octagon).
- **Rumble:** output report `0x03`: `[03, 0x50 | sequence, motor]`, motor 1 = on, 0 = off, 2 = brake.
  The motor has no strength control. Sending it every 4 ms with on/off chosen by error diffusion gave
  full, half and 20 % strengths that a person could clearly tell apart.
- The report also carries packed motion data (length byte 15 = 30), although SDL exposes no sensors
  for this controller.

## 2. NSO GameCube controller over Bluetooth LE

*Data:* `data/gamecube-bluetooth-dsu-monitor.log` (seen through NS2 Bridge's DSU server).

- Connects as a plain BLE central, **without Nintendo's pairing**, after holding SYNC: ≈ 10 s.
- Input arrives on its own characteristic (`8261cba1-…`), same layout as USB report 0x0A minus the ID.
  Rumble goes to `3f8fb670-…` as `00` + the USB report from byte 1.
- **Rate: ≈ 33 reports per second (one every 30 ms)**, the connection interval macOS grants (USB: 4 ms).
- Verified end to end: every button, analog L/R to full, both sticks in all directions, battery level,
  rumble at three strengths, and dropping the link ("turn off").

## 2b. Switch 2 Pro over Bluetooth LE (input ✅, motion ✅, 7.5 ms ✅)

From NS2 Bridge's Bluetooth log (`/usr/bin/log show --predicate 'subsystem == "local.ns2bridge"'`):

- Connects without Nintendo's pairing (Wireless → Connect + SYNC) in ≈ 10 s, like the GameCube. Report 0x09
  arrives at **≈ 34 per second** (macOS's connection interval).
- **The USB "select input report" command (`03 91 01 0A … 05`) has no effect over Bluetooth**; ndeadly lists
  command 0x03 as meant for USB. Over Bluetooth each report has its own characteristic, and the controller
  streams **one input characteristic at a time**: subscribing to 0x05 (`…7fd2`) and unsubscribing from 0x09
  (`7492866c…`) switches the stream (0x05 then arrives at ≈ 33/s).
- **The IMU fields in 0x05 start out zero over Bluetooth** (timestamp `00 00 00 00`) although the feature
  mask with the IMU bit was acknowledged; "get feature info" (`0C 01`) reports the IMU as `05` where
  buttons, sticks and rumble read `07`.
- **Fix:** "configure features" (`0C 06`, IMU flag, ndeadly's example parameters `02 02 01 00 8A 00`) is
  **refused while the IMU is enabled** (reply `0C 02 …` instead of `0C 01 …`). Disable the IMU (`0C 05`,
  flag 0x04), configure, enable it (`0C 04`, flag 0x04): feature info turns `07`, the timestamp runs, and
  accel/gyro read as over USB (at rest (0.00, +1.00, +0.19) g, gyro offset ≈ 0.2 °/s). Now part of the
  connect sequence, verified on several reconnects. The 2 reply bytes vary (`00 E4`, `00 D8`; ndeadly `00 50`);
  maybe the IMU temperature (unconfirmed). Once configured, none of the connect commands, the report-rate
  descriptor or a subscription change resets it (each re-sent one at a time, feature info read after each),
  so the IMU arrives unconfigured over BLE; other hosts that skip `0C 06` may have controllers configured
  earlier over USB or by the console.
- **Commands one at a time:** sent 30 ms apart, some replies never came and one was cut short; waiting for
  each reply (≈ 60 ms each) fixed it.
- **Connection interval:** the controller sends one report per connection event and never asks for faster
  parameters; bluetoothd connects with 10–30 ms and the chip picks 30 ms. bluetoothd's private latency levels
  (`setDesiredConnectionLatency:forPeripheral:`, found by disassembling bluetoothd; no entitlement needed) give:
  −7 → 15 ms, ≈ 68 reports/s; **−12 → 7.5 ms, ≈ 133 reports/s** with gyro on or off, steady and motion correct;
  −25 (7.5 ms with shorter events) → the stream collapses; −22 (5 ms) → accepted but not applied.
  `setHighPriorityStream:duration:` (duration must be an integer NSNumber) and Game Mode don't change the
  interval (bluetoothd's Game Mode logic covers bonded HID devices).
- At 30 ms, report 0x05 carries one IMU sample per report: about 1 in 24 of the IMU's 800 Hz samples
  (per a sniffer-capture analysis of ndeadly's traces); 7.5 ms improves motion as well as input.

## 3. NSO N64 controller: why generic HID input is garbage

*Reproduce:* `python3 scripts/n64_hid_descriptor.py` (descriptor in `data/`).

macOS performs the original-Switch USB handshake by itself, so the N64 controller streams report 0x30
every 15 ms. But its HID report descriptor describes report 0x30 as 16 buttons, four 16-bit axes and a
hat, while the real report is the original-Switch layout (timer, battery, three button bytes, packed sticks).

Consequences, measured with SDL 3.4.14 and the controller untouched:

| SDL driver for the N64 | GUID | Seen as | Input with nobody touching it |
|---|---|---|---|
| SDL's own HIDAPI driver | `030070d67e050000192000001202680c` | 16 buttons, 6 axes, 1 hat, gamepad | none |
| Generic IOKit (HIDAPI off) | `030070d67e0500001920000012020000` | 18 buttons, 4 axes, 1 hat, not a gamepad | **≈ 50 presses/s**: the timer byte ticks through "buttons" 0–7; real buttons land in the "axes" |

No SDL mapping can repair the IOKit view, so NS2 Bridge keeps SDL's own driver on (§4). SDL's own
driver reports "no rumble" for the N64 even though it can rumble it, which is why a small helper forwards
game rumble.

## 4. A game switching SDL's N64 driver off (BattleShip)

The N64 controller was "completely erratic" in BattleShip (an SDL2 game running on sdl2-compat/SDL3).

- **Cause** (found by disassembling a few instructions around the game's `SDL_SetHint` calls): right after
  `Ship::ControlDeck::PreInitRaphnet`, the game calls `SDL_SetHint("SDL_JOYSTICK_THREAD", "1")` and
  `SDL_SetHint("SDL_JOYSTICK_HIDAPI", "0")`, which drops the N64 to the IOKit path of §3.
- **Refined fix (1.0.0 final):** SDL checks each HIDAPI driver's own hint before the master one (SDL2 and 3,
  `SDL_hidapijoystick.c`), so NS2 Bridge sets only `SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC=1` and the helper
  only blocks attempts to switch *that* driver off. A game that turns all HIDAPI drivers off (BattleShip does,
  right after setting up Raphnet adapters) keeps that choice for every other device.
- **First fix and verification** with the game's own SDL (`tools/sdlcheck.c` via `scripts/sdl-check.sh`, simulating
  what a game does; phantom presses counted over 2 s with nobody touching the controller):

  | Game does… | Nothing added | Env `SDL_JOYSTICK_HIDAPI=1` (+ `…_NINTENDO_CLASSIC=1`) | NS2 Bridge helper |
  |---|---|---|---|
  | nothing | ✅ 0 | ✅ 0 | ✅ 0 |
  | `SDL_SetHint(HIDAPI, "0")` (BattleShip) | ❌ ≈ 109, IOKit | ✅ 0 | ✅ 0 |
  | the same at `SDL_HINT_OVERRIDE` priority | ❌ ≈ 106 | ❌ ≈ 106 (override beats env) | ✅ 0 |

  The helper drops hints that would switch those drivers off, and reports each Nintendo controller's
  driver back to NS2 Bridge (checked from the game's own `SDL_PollEvent`/`SDL_PeepEvents` calls), which
  was confirmed to catch the IOKit case.
- A static scan for game code naming `SDL_JOYSTICK_HIDAPI` / `…_NINTENDO_CLASSIC` flags such games.
  Only exact names count: `SDL_JOYSTICK_HIDAPI_PS4_RUMBLE` and similar are common and harmless (two of the
  five games tested use them).

## 5. N64 button numbering: SDL2 vs SDL3 (and sdl2-compat)

From SDL's source (`SDL_hidapi_switch.c`: the N64 is handled as a Pro Controller with button-label
remapping), confirmed against SDL3's built-in mapping read on hardware:

| Input | SDL2 | SDL3 / sdl2-compat |
|---|---|---|
| A, B, C←, C↑, C→ | b0, b1, b2, b3, b4 | same |
| Home, Start, ZR, L, R | b5, b6, b7, b9, b10 | same |
| Z, C↓ | axis 4, axis 5 | same |
| D-pad | b11–b14 | **hat 0** |
| Capture | b15 | **b11** |

A game linked to SDL2 but running sdl2-compat therefore needs the SDL3 layout.

## 6. Stick range as games see it

*Measured* with each game's SDL (`SDLCHECK_AXES=1 scripts/sdl-check.sh`), rolling every stick around its edge:

| Controller (SDL driver) | Full push, as the game sees it |
|---|---|
| NSO N64 (SDL's own driver) | ±100% |
| NSO GameCube (generic IOKit) | **57–62%**, because SDL maps the full 0–4095 range but the sticks travel ≈ 790–3310 |
| Switch 2 Pro (generic IOKit) | ≈ 81% (travel ≈ 384–3584) |

NS2 Bridge's helper rescales `SDL_GameControllerGetAxis` / `SDL_GetGamepadAxis` for Nintendo controllers
on the IOKit path using NS2 Bridge's stick calibration (SDL's IOKit scaling is `raw × 65535 / 4095 − 32768`;
the Y axes are inverted by the mapping). With it, the GameCube reads centered at rest and reaches full tilt;
this was confirmed by feel in BattleShip. All five games tested read sticks by polling those functions.

## 7a. Switch 2 Pro: motion from report 0x05, verified

With motion on, the Pro switches to report 0x05 and NS2 Bridge decodes its IMU fields (SDL's offsets and
scales), measured through the DSU server at 250 samples per second:

- Resting on a desk (on its grips): accel (SDL frame) = (0.00, **+1.00**, +0.19) g; the +0.19 matches the
  ≈ 11° tilt on its grips, and the accel Z seen in the packed 0x09 data (§7).
- Tilting the top edge up: gyro X (pitch) positive and accel Z turning negative, as the SDL frame requires.
- **Scale check:** integrating the gyro alone from rest and predicting where gravity should point, then
  comparing with the accelerometer at every still moment after movement of up to 289 °/s: median error
  0.3°, 90% within 3.8°, worst 5.0° with SDL's 34.8 rad/s range (the IMU clock ran in microseconds);
  SDL's alternative 40 rad/s range fits worse (worst 5.6°). Resting gyro offset ≈ 0.01 °/s.
- **Automatic mode:** with no DSU client the Pro stays on 0x09 (games can read it); a client subscribing
  switches it to 0x05 within a second, and it returns to 0x09 a few seconds after the client stops.

## 7. Switch 2 Pro: the packed motion data inside report 0x09 (partial)

*Reproduce:* `python3 scripts/pro2_packed_motion.py` (guided capture with still/pitch/roll/yaw segments).

Report 0x09 carries 30 bytes of motion (byte 15 = 30), in a format nobody has published. What the
capture shows while the controller lies still:

- **Byte 16** steps by **3** each report → about **3 IMU samples per 4 ms report**.
- Bytes 21–24 and 25–28 behave like two slowly advancing 32-bit quantities (timestamps or integrated values).
- **Bytes 42–43** are an int16 of **4090–4101 ≈ 4096 = 1 g** at a ±8 g range: accelerometer Z.
- The remaining bits are noise-like in their low bits and look compressed or integrated; per-bit flip
  rates are printed by the script as a starting point.

NS2 Bridge therefore reads motion from report **0x05** (SDL's and ndeadly's documented layout; accel
±8 g, gyro ±2000 °/s at 16.4 LSB per °/s), switching the Pro to it only while motion is needed; verified
on hardware in §7a.

## 8. Switch 2 Pro buttons: C vs Capture (resolved)

**Bit 17 = Capture, bit 20 = C.** In `pro2-usb-buttons` the "press CAPTURE" prompt shows bit 20 and
"press C" shows bit 17: the person pressed the two the other way round (the guided recordings also drift
in timing elsewhere, e.g. B's bit under the "A" prompt). Three independent sources agree on the mapping
the app uses:

| Source | Capture | C |
|---|---|---|
| ndeadly, `hid_reports.md` (report 0x09, byte 2) | 0x02 → bit 17 | 0x10 → bit 20 |
| procon2-mac `procon2-mapping.json`, learned by pressing buttons on a real Pro Controller 2 | byte 4 mask 0x02 → bit 17 | byte 4 mask 0x10 → bit 20 |
| NSO GameCube, same family and report structure, verified on our hardware (§1) | bit 17 | bit 20 |

Hardware check (2026-09-29): three deliberate Capture presses on the Pro Controller 2 each set **bit 17**.
`ns2probe buttons` now also asks for confirmation whenever a press disagrees with NS2 Bridge's table, so a
swapped press like the one above can't slip into a capture silently.

## 9. SDL mapping GUIDs

From SDL's source (SDL2 ≥ 2.26 and SDL3, `SDL_PrivateMatchGamepadMappingForGUID`): the CRC field is
stripped before matching, a mapping without one matches any CRC, and a second pass ignores the firmware
version. NS2 Bridge therefore also ships mappings with CRC and version zeroed
(`030000007e0500006920000000000000` Pro, `030000007e0500007320000000000000` GameCube), so they keep
working when firmware updates change `bcdDevice`. Confirmed: the GameCube, with no exact-GUID mapping,
is recognized as a gamepad by both an SDL2 game and an sdl2-compat game.

## 10. DSU (CemuHook) details that matter

- Dolphin reads the D-pad and face buttons from the **analog** bytes of the pad-data message, not just
  the button bitmasks; a server that leaves them at 0 shows no face buttons in Dolphin.
- Button bits (from Dolphin's client and DS4Windows): byte 1 = Share 0x01, L3 0x02, R3 0x04,
  Options 0x08, D-pad up/right/down/left 0x10/0x20/0x40/0x80; byte 2 = L2 0x01, R2 0x02, L1 0x04,
  R1 0x08, Triangle 0x10, Circle 0x20, Cross 0x40, Square 0x80. Sticks: +Y is up.
- Motion axes, derived by composing Dolphin's SDL and DSU input maps: from SDL's sensor frame,
  DSU accel = −SDL accel (in g), pitch = +x, yaw = −y, roll = −z (°/s).
