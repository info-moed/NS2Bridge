---
title: Emulators
parent: User guide
nav_order: 6
---

# Emulators (DSU / CemuHook)

NS2 Bridge runs a **DSU server** (also called CemuHook UDP) on `127.0.0.1:26760`. Emulators that support it get
every connected controller: buttons, sticks, the GameCube's **analog triggers**, and the Switch 2 Pro's **gyro and
accelerometer**. Player 1 is DSU slot 1 (index 0), Player 2 slot 2, and so on. The server only accepts connections
from this Mac.

The server is on by default (**Motion** tab). Many emulators also read the controllers directly through SDL; DSU is
what carries motion and analog triggers.

## Setting up an emulator

The menu names below come from each emulator's own documentation and may differ between versions. NS2 Bridge's DSU
server has been verified with a scripted DSU client; tell us how your emulator does with a
[compatibility report](https://github.com/info-moed/NS2Bridge/issues/new/choose).

| Emulator | Where | What to enter |
|---|---|---|
| **Dolphin** (GameCube, Wii) | Controllers → *Alternate Input Sources* → **DSU Client** | Enable, add server `127.0.0.1`, port `26760`. Then pick the `DSUClient/0/…` device in the controller's configuration. |
| **Cemu** (Wii U) | Input settings | API **DSUController**, server `127.0.0.1:26760`. |
| **Lime3DS / Citra forks** (3DS) | Settings → Controls → *Motion / Touch* | Motion provider **CemuHook UDP**, `127.0.0.1`, port `26760`. |
| **Ryujinx forks** (Switch) | Input → Motion | **CemuHook compatible motion**, `127.0.0.1`, port `26760`, slot 0 for Player 1. |

## Gyro

Gyro comes from the Switch 2 Pro Controller (the GameCube and N64 controllers have no motion sensors). The **Motion**
tab's mode decides when it flows; see [Motion](motion.md):

- **Automatic** (default): on while an emulator listens for the Pro over DSU, off a few seconds after it stops.
- **Always on** / **Off**.

For steady aiming, run **Calibrate gyro** once (Motion tab: controller still on a table, 3 seconds).

## Checking that it works

The Motion tab shows how many emulators are listening ("1 emulator listening"). Developers can watch exactly what a client receives with
`python3 research/scripts/dsu_motion_monitor.py` (packets per second, accelerometer and gyro).
