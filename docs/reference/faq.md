---
title: FAQ
parent: Reference
nav_order: 3
---

# FAQ

**Is NS2 Bridge official?**
No. It's an independent open-source project, not affiliated with or endorsed by Nintendo, Microsoft or Apple.

**Is it free? Is it safe?**
Free and MIT-licensed. It has no accounts or telemetry, its only internet access is an optional update check ([Privacy](privacy.md)), it contains only
original code, and never writes to a controller's firmware or memory. The source is on
[GitHub](https://github.com/info-moed/NS2Bridge); security reports go to [SECURITY.md](https://github.com/info-moed/NS2Bridge/blob/main/SECURITY.md).

**Why does macOS warn me the first time?**
NS2 Bridge isn't signed with a paid Apple Developer ID, so macOS can't verify the developer. Allow it once in
System Settings → Privacy & Security.

**Which controllers work?**
The Switch 2 Pro Controller, the Nintendo Switch Online GameCube controller and the NSO N64 controller.
Joy-Con 2 isn't supported yet. See [Compatibility](compatibility.md).

**Does it work with Steam?**
Games launched by Steam don't get NS2 Bridge's helper unless you install the helper into the game (Games tab), which
then works however the game is started. Steam Input itself doesn't know these controllers on macOS.

**How is the Bluetooth support "like Steam Input"?**
Steam Input reads controllers itself and gives games it launches a virtual controller. NS2 Bridge does the same for
games launched with its helper, through SDL. A system-wide virtual controller would need a permission Apple only
grants to approved developers.

**Why is Bluetooth slower than USB?**
The controller sends one report per Bluetooth connection event. NS2 Bridge gets that down to 7.5 ms (133 per
second); USB is 4 ms. See [Bluetooth](../guide/bluetooth.md#speed).

**Do I need NS2 Bridge running to play?**
Yes, for anything beyond basic input: rumble, Bluetooth, DSU and calibration all go through it. **Open NS2 Bridge at
login** keeps it ready in the menu bar.

**Does it change my games?**
Only if you click **Install rumble into game**, which adds the helper next to the game's SDL library and keeps a
backup; **Remove helper from game** restores the originals exactly. Don't redistribute a modified game.

**Can I use it with online or anti-cheat games?**
Don't use the helper with them. Some games' terms forbid third-party tools.

**Does it work on Intel Macs?**
It's a universal app, but it hasn't been tested on an Intel Mac yet.

**How do I uninstall it completely?**
Setup → **Reset NS2 Bridge…**, quit, then delete the app. Details in [Install](../INSTALL.md#uninstalling).
