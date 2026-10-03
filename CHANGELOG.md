# Changelog

All notable changes to NS2 Bridge. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [semantic versioning](https://semver.org).

## [1.0.0] - 2026-10-03

First release.

### Controllers
- **Switch 2 Pro Controller**, **NSO GameCube controller** and **NSO N64 controller** over USB and Bluetooth:
  plug-and-play input, player numbers and lights, battery, turn off wirelessly.
- **HD Rumble 2** on the Pro (test effects, two-band manual control, strength), rumble for the GameCube and N64.
- **Gyro and accelerometer** on the Pro over USB and Bluetooth, with a live 3D view and gyro calibration.
- **GameCube analog triggers**, with a trigger test and calibration.
- **Stick calibration** and deadzones; **each controller remembers its own profile**.
- **Fast Bluetooth**: a 7.5 ms connection interval (133 reports a second, about 4× macOS's default) with the
  **Speed** setting (Fastest, Fast, Standard).

### Games and emulators
- **SDL games**: rumble, full stick range and the N64 driver guard through NS2 Bridge's helper, launched from the
  **Games** tab or installed into the game (originals backed up, one-click restore).
- **Bluetooth controllers in games**, like Steam Input: the helper presents them as normal gamepads, with rumble and,
  in SDL3 games, gyro.
- **DSU (CemuHook) server** for emulators: buttons, sticks, analog triggers and gyro.
- Rumble through macOS force feedback, Xbox mode, button layout options.

### App
- Menu bar pills per controller; Basic and Advanced modes; welcome tour on every new installation.
- **Startup animation** (pixel art, skippable; off with Reduce Motion or in Setup) and **Demo mode**.
- **Latency Test** for USB and Bluetooth, **Battery** history and alerts, **Diagnostics** with a privacy-scrubbed
  report for bug reports.
- Opt-in **update check**, **What's New** after updates, Help in the menu bar, VoiceOver labels.
- **Reset NS2 Bridge** removes everything it set up.

### Project
- Documentation website with a user guide for every tab, compatibility list, troubleshooting, FAQ and reference.
- Homebrew cask (`brew install --cask info-moed/tap/ns2bridge`), CI, automated releases with a privacy scan.

[1.0.0]: https://github.com/info-moed/NS2Bridge/releases/tag/v1.0.0
