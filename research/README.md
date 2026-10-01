# Research data and methods

Everything NS2 Bridge's protocol notes are built on, published so anyone can check it, reuse it, or
take it further: raw captures from real controllers, the scripts that turn them into findings, and
measurements that aren't available anywhere else.

- **[FINDINGS.md](FINDINGS.md)**: every finding, with the numbers, how it was measured, and how to reproduce it.
- **[../docs/PROTOCOL.md](../docs/PROTOCOL.md)**: the resulting protocol reference, each fact marked
  verified / documented elsewhere / unknown.

## How the data was collected

**Hardware.** One of each, lawfully owned, connected to a Mac (Apple Silicon, macOS 27):

| Controller | USB ID | Firmware (`bcdDevice`) |
|---|---|---|
| Switch 2 Pro Controller | 057E:2069 | 0x0201 |
| Switch 2 NSO GameCube Controller | 057E:2073 | 0x0101 |
| Switch Online N64 Controller | 057E:2019 | 0x0212 |

**Only standard, documented host interfaces were used**: macOS IOKit HID (`IOHIDManager`, reading
input reports exactly as any app can), IOUSBHost on the controllers' unclaimed vendor interface
(the start-up commands), and CoreBluetooth. Nothing was opened up, flashed, or modified on any
controller; no firmware was read or written.

**Methods.**

1. **Guided captures.** `ns2probe` (in `Sources/ns2probe/`) records every input report to an
   `.ns2cap` file while prompting the person to press one button or make one movement at a time; the
   prompts and their timestamps go to a `.labels` file. Decoding is then a matter of correlating bits
   and bytes with the labeled segments ([scripts/](scripts/)).
2. **Byte statistics.** For each byte offset: min, max, and how often it changes. Counters, noise,
   sticks and constants each have a recognizable signature (e.g. counters flip bit 0 most often and
   each higher bit about half as often).
3. **Live checks.** Rumble strengths and turn-off were confirmed by a person holding the controller.
   Bluetooth input was checked end to end through NS2 Bridge's DSU server with a small DSU client
   ([scripts/dsu_monitor.py](scripts/dsu_monitor.py)); its log is in [data/](data/).
4. **Games' own SDL.** `tools/sdlcheck.c` (driven by `scripts/sdl-check.sh`) links against a game's
   bundled SDL the way the game does, optionally behaves like a hostile game, and reports which SDL
   driver each controller gets, phantom input while untouched, and the stick range the game sees.
5. **Static inspection of games** for interoperability: which SDL functions a game imports (`nm`) and,
   in one case, a disassembly (`otool -tV`) of the few instructions around an `SDL_SetHint` call, to
   find out why a controller misbehaved in that game. No game code is included here.
6. **Public sources** (SDL, ndeadly's research, dekuNukem's notes, Dolphin, libultraship; see
   [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)) were read to cross-check. Where our
   measurements disagreed with them, FINDINGS.md says so.

## What's here

| Path | What |
|---|---|
| `captures/pro2-usb-buttons.ns2cap` (+ `.labels`) | Switch 2 Pro, USB, report 0x09: every button pressed once (guided), then pitch/roll/yaw. 173 s, 43 327 reports. The person's timing drifts in places, and the C and Capture prompts were answered with each other's button (see FINDINGS.md §8). |
| `captures/pro2-usb-guided-motion.ns2cap` (+ `.labels`) | Switch 2 Pro, USB, report 0x09: still flat, pitch, roll, yaw (each separated by still), stick circles, buttons held one by one. 110 s. |
| `captures/gamecube-usb-buttons.ns2cap` | NSO GameCube, USB, report 0x0A: A, B, X, Y, Z, ZL, L and R slowly to the click, Start, Home, Capture, C, D-pad, then both sticks rolled. 150 s, 37 551 reports. Also used by the unit tests. |
| `data/n64-usb-hid-report-descriptor.txt` | The N64 controller's USB HID report descriptor as macOS lists it. |
| `data/gamecube-bluetooth-dsu-monitor.log` | GameCube over Bluetooth LE, seen through NS2 Bridge's DSU server: connect, every input, turn-off. |
| `scripts/ns2cap.py` | Reader for `.ns2cap` / `.labels` files; run it for a summary of every capture. |
| `scripts/gamecube_usb.py` | Reproduces the GameCube findings (bit map incl. the Z/ZL corrections, triggers, stick travel and gate). |
| `scripts/pro2_packed_motion.py` | The partial decode of the motion data packed inside report 0x09. |
| `scripts/n64_hid_descriptor.py` | Shows why a generic HID reader misreads the N64 controller. |
| `scripts/dsu_monitor.py` | Minimal DSU client used for the Bluetooth checks. |
| `scripts/dsu_motion_monitor.py` | DSU client summarizing transport, rate and motion (accel/gyro) per controller, used for the motion checks over USB and Bluetooth. |

Run any script with Python 3 from `research/scripts/`, no packages needed:

```bash
cd research/scripts && python3 ns2cap.py && python3 gamecube_usb.py
```

### `.ns2cap` format

The 4 bytes `NS2C`, then one record per input report: `u32` little-endian milliseconds since the
recording started, `u16` little-endian length, then the report bytes (byte 0 is the report ID).
`.labels` files are `milliseconds<TAB>prompt` lines.

### Privacy of the data

The captures contain **input reports only** (report IDs 0x09 and 0x0A; checked by `ns2cap.py`):
buttons, sticks, triggers, motion, battery level and counters. Controllers only reveal serial numbers
and Bluetooth addresses through separate commands, which were not recorded. Timestamps are relative to
the start of each recording. Nothing identifies the person or the computer.

## How this project was made: AI-assisted

NS2 Bridge, including this research, was developed **with AI assistance**: Anthropic's Claude (through
Claude Code) wrote most of the code, analysis scripts and documentation, proposed the experiments, and
worked through the captures, public sources and disassembly, under the direction of the maintainer, who
ran every hardware test with real controllers, judged the results, and decided what shipped. Commits made
with the AI are marked `Co-Authored-By: Claude`.

That's why this folder exists: AI-assisted reverse engineering is only as trustworthy as its evidence,
so the evidence is here. Every claim in FINDINGS.md points to data you can rerun. If something doesn't
reproduce on your controller, please open an issue with your capture.
