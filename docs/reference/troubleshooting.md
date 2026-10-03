---
title: Troubleshooting
parent: Reference
nav_order: 2
---

# Troubleshooting

Still stuck? Ask in [Discussions](https://github.com/info-moed/NS2Bridge/discussions) or open a
[bug report](https://github.com/info-moed/NS2Bridge/issues/new/choose) with a diagnostics report attached
(Diagnostics tab → **Export Diagnostics Report…**).

## Installing and launching

| Symptom | Cause | Fix |
|---|---|---|
| "NS2 Bridge could not be verified" | It's not signed with a paid Apple Developer ID. | System Settings → Privacy & Security → **Open Anyway**. Once per version. |
| macOS asks for permissions again after an update | Expected with ad-hoc signing: each version is a new identity to macOS. | Approve again. |
| The welcome tour appears again | Every new installation shows it. | Close it, or use it to check your settings. |

## Connecting

| Symptom | Cause | Fix |
|---|---|---|
| The controller charges but never connects | A charge-only USB-C cable. | Use a **data** cable; try another port. |
| "…exclusive access" when connecting | Another app holds the controller, often a browser tab using WebUSB. | Close it, then click **Reconnect** (Diagnostics). |
| Switch 2 controller won't connect over Bluetooth | Not in sync mode, or another device grabbed it. | Unplug the cable, click **Wireless → Connect wirelessly**, then hold the small SYNC button until the lights sweep. |
| It disconnected after sleeping | NS2 Bridge doesn't do Nintendo's pairing. | Connect again with **Connect** and SYNC. |
| Bluetooth feels slow | Speed set to Standard, or this Mac's chip refused 7.5 ms. | Wireless → Speed → **Fastest**; check the [Latency Test](../guide/latency.md). An orange note says if it fell back to Fast. |

## Games

| Symptom | Cause | Fix |
|---|---|---|
| No input in a game | SDL doesn't know the controller yet. | Turn on **Setup → Let SDL games and emulators use this controller**, then quit and reopen the game. |
| No controller in a game over Bluetooth | Games only see Bluetooth controllers through the helper. | Launch the game from the **Games** tab, or install the helper into it. Needs SDL 2.24 or later. |
| N64 input goes haywire in a game | The game switched SDL's N64 driver off. | Launch it from **Games** (or install the helper). The Games row warns when this happens. |
| Sticks don't reach the edge | The game reads the controller through SDL's generic driver. | Launch from **Games** or update the helper; [calibrate the sticks](../guide/calibration.md); check the game's own sensitivity and deadzone. |
| No rumble | The game runs without the helper, or its rumble is off. | Start it with **Games → Play with rumble**; check the game's own rumble setting. |
| "Update helper in game" | NS2 Bridge has a newer helper than the copy installed in the game. | Click it (the game must be closed). |
| No gyro in a game over Bluetooth | The game uses SDL2, which has no virtual motion sensors. | Use USB with an emulator over DSU, or a game built on SDL3. |

## Emulators

| Symptom | Cause | Fix |
|---|---|---|
| Emulator sees no DSU controller | DSU server off, wrong address, or wrong slot. | Motion tab: server on, `127.0.0.1:26760`; Player 1 = slot 1 (index 0). |
| No gyro | Motion is Off, or the controller isn't a Switch 2 Pro. | Motion tab → **Automatic** or **Always on**. |
| Aim drifts slowly | Gyro offset. | Motion tab → **Calibrate gyro** with the controller still on a table. |
| Games reading the Pro over USB stop responding while an emulator uses gyro | Motion reports aren't described to macOS. | Expected in **Always on**; use **Automatic**. |

## Starting over

**Setup → Reset NS2 Bridge…** removes everything NS2 Bridge set up and relaunches fresh.
See [Settings and files](settings-and-files.md) for exactly what it removes.
