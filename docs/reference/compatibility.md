---
title: Compatibility
parent: Reference
nav_order: 1
---

# Compatibility

✅ verified on real hardware · 🧪 built and unit-tested, not yet tried on real hardware · — not applicable

Tried something not listed? A [compatibility report](https://github.com/info-moed/NS2Bridge/issues/new/choose)
(working or not) adds it here.

## Controllers and features

| | Switch 2 Pro (`057E:2069`) | NSO GameCube (`057E:2073`) | NSO N64 (`057E:2019`) |
|---|---|---|---|
| USB input | ✅ 250 Hz | ✅ 250 Hz | ✅ 66 Hz (its own rate) |
| Bluetooth input | ✅ 133 Hz at 7.5 ms | ✅ 33 Hz at macOS's 30 ms; 7.5 ms 🧪 | 🧪 classic Bluetooth |
| Rumble (app) | ✅ HD Rumble 2, two motors | ✅ on/off motor, 3 strengths | ✅ |
| Rumble in games (helper) | ✅ | ✅ | ✅ |
| Gyro / accelerometer | ✅ USB and Bluetooth | — | — |
| Analog triggers | — | ✅ (DSU, live view, calibration) | — |
| Battery level | ✅ | ✅ | ✅ |
| Player lights | 🧪 | 🧪 | 🧪 |
| Turn off wirelessly | ✅ | ✅ | 🧪 |
| In games over Bluetooth (virtual gamepad) | ✅ | 🧪 | — (macOS shows it to games itself) |

## Games

| Game | SDL | Tested | Notes |
|---|---|---|---|
| BattleShip | sdl2-compat (SDL3) | ✅ Pro (USB, Bluetooth with gyro), GameCube, N64 | Turns SDL's HIDAPI drivers off; the helper keeps the N64 driver on. 20% stick deadzone of its own. |
| Wave Race 64 Recompiled | SDL2 | ✅ Pro (USB, Bluetooth), N64 | No gyro over Bluetooth (SDL2 has no virtual sensors). |

Most SDL games should behave like these. Games with SDL compiled in (not a separate library) can't use the helper.

## Emulators (DSU)

| Emulator | Tested |
|---|---|
| Scripted DSU client (`research/scripts/dsu_motion_monitor.py`) | ✅ buttons, sticks, GameCube triggers, Pro gyro over USB and Bluetooth |
| Dolphin, Cemu, Lime3DS, Ryujinx forks | 🧪 not yet confirmed: reports welcome |

## Macs and macOS

| | Status |
|---|---|
| macOS 15 (Sequoia) and later | Required |
| Apple silicon | ✅ |
| Intel | 🧪 universal build, untested |
| Bluetooth 7.5 ms interval | ✅ on the maintainer's Apple silicon Mac; other Bluetooth chips may differ (Fastest falls back to 15 ms by itself) |
