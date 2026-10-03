---
title: Helper protocol
parent: Reference
nav_order: 8
---

# Helper protocol

How NS2 Bridge and its game helper (`Hooks/ns2rumble.c`) talk: UDP on the loopback interface, little-endian.
NS2 Bridge listens on `127.0.0.1:26761`. Each helper binds its own loopback port and sends from it, and NS2 Bridge
answers to that port.

## Helper → NS2 Bridge

| Packet | Layout | When |
|---|---|---|
| Hello | `"NS2H"` · u32 pid · u8 SDL major | Once, when SDL is present |
| Keep-alive | `"NS2K"` · u32 pid | Every second: "this game wants Bluetooth controllers" |
| Rumble | `"NS2R"` · u16 low · u16 high · u32 ms · u16 product · u64 device · u8 rank | On every rumble call for a Nintendo controller |
| Driver report | `"NS2B"` · u32 pid · u16 product · u8 driver · u8 SDL major | When a Nintendo controller is opened, and on change |

- **ms** = 0: until the next request (SDL stops it).
- **device**: the IORegistry ID from SDL's device path (`DevSrvsID:<id>`), `UINT64_MAX` for a virtual gamepad
  (the Bluetooth controller), else 0.
- **rank**: position among the game's controllers of this kind, in connection order (`0xFF` = unknown). Together these
  let NS2 Bridge route rumble to the exact controller.
- **driver**: SDL GUID byte 14: `'h'` HIDAPI, `'v'` virtual, 0 generic (IOKit).

## NS2 Bridge → helper

**Bluetooth controllers** (`"NS2V"`), sent to every helper that kept alive in the last 3 seconds, at the controller's
report rate:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `"NS2V"` |
| 4 | 1 | version (1) |
| 5 | 1 | count (≤ 8) |
| 6 + 52 n | 52 | one gamepad per entry (below) |

| Offset in entry | Size | Field |
|---|---|---|
| 0 | 1 | slot (player number) |
| 1 | 1 | flags: bit 0 = motion valid |
| 2 | 2 | product ID |
| 4 | 4 | buttons: bit n = SDL gamepad button n (south, east, west, north, back, guide, start, left stick, right stick, left shoulder, right shoulder, d-pad up, down, left, right, misc1) |
| 8 | 12 | 6 × i16 SDL axes: left x, left y, right x, right y, left trigger, right trigger (y down positive; triggers −32768 at rest) |
| 20 | 12 | 3 × f32 accelerometer, m/s², SDL frame |
| 32 | 12 | 3 × f32 gyro, rad/s, SDL frame |
| 44 | 8 | u64 sensor time, µs |

The helper attaches an SDL virtual gamepad per slot from the game's own event calls and detaches it when a slot gets
no update for a second. Built by `VirtualGamepad.packet` (`Sources/NS2Kit/VirtualGamepad.swift`); the layout is
pinned by a unit test.

## Per-game settings

`~/Library/Application Support/NS2Bridge/games/<bundle id>.env`: `KEY=VALUE` lines (values may contain `\n`) that the
helper applies to its environment at start-up, for example SDL hints, mappings, `NS2_XBOX_MODE` and
`NS2_STICKCAL_<pid>` (stick calibration in SDL units).
