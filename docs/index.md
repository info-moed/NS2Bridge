---
title: Home
nav_order: 1
description: Switch 2 Pro, NSO GameCube and NSO N64 controllers on macOS.
permalink: /
---

# NS2 Bridge

**Nintendo's newest controllers on your Mac: the Switch 2 Pro Controller, the NSO GameCube controller and the
NSO N64 controller, over USB or Bluetooth, with rumble, gyro and analog triggers, in games and emulators.**

![NS2 Bridge's startup animation: a pixel-art controller assembling from 3D voxels](images/intro.gif)

[Download for macOS](https://github.com/info-moed/NS2Bridge/releases/latest){: .btn .btn-primary .mr-2 }
[Getting started](guide/getting-started.md){: .btn .mr-2 }
[View on GitHub](https://github.com/info-moed/NS2Bridge){: .btn }

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/tab-controller-dark.png">
  <img src="images/tab-controller-light.png" alt="NS2 Bridge showing a Switch 2 Pro Controller's live input">
</picture>

Free and open source (MIT) · macOS 15 or later · Apple silicon and Intel · No account, no telemetry

## What it does

| | |
|---|---|
| **Plug in and play** | A Switch 2 Pro, NSO GameCube or NSO N64 controller works the moment it's connected: a colored pill in the menu bar shows its player number and battery. |
| **Games** | Rumble, full stick range and correct buttons in SDL games (most Mac ports and recompiled games). Over Bluetooth, games see the controller through NS2 Bridge's helper, much like Steam Input. |
| **Emulators** | A built-in DSU (CemuHook) server gives Dolphin, Cemu, Lime3DS and others buttons, sticks, analog triggers and the Pro's gyro. |
| **Fast Bluetooth** | 133 reports a second (one every 7.5 ms), about 4× macOS's default, with gyro included. |
| **HD Rumble 2** | Test effects, a manual two-band player, and game rumble on both motors. |
| **Tools** | Stick calibration and deadzones, per-controller profiles, button test, latency test, battery history, live 3D motion view, raw report viewer. |

## Try it without a controller

Turn on **Setup → Demo mode** and NS2 Bridge plays back two recorded controllers, so every tab shows live data.

## Learn more

- [Getting started](guide/getting-started.md): install, first launch, the welcome tour.
- [User guide](guide/index.md): every tab explained.
- [Games](guide/games.md) · [Emulators](guide/emulators.md) · [Bluetooth](guide/bluetooth.md)
- [Compatibility](reference/compatibility.md) · [FAQ](reference/faq.md) · [Troubleshooting](reference/troubleshooting.md)
- [For developers](DEVELOPMENT.md): building, testing, the protocol notes and research evidence.
