---
title: Command line
parent: Reference
nav_order: 7
---

# Command line

For developers and the curious. Paths are relative to the repository.

## App flags

| Command | What |
|---|---|
| `"NS2 Bridge.app/Contents/MacOS/NS2Bridge" --render-drawings <folder>` | Saves the controller drawings, the 3D motion view and the welcome pages as PNGs (light and dark), then quits. |
| `"NS2 Bridge.app/Contents/MacOS/NS2Bridge" --render-intro <folder>` | Renders the startup animation as an animated GIF (`intro.gif`) plus a PNG every 10 frames, then quits. |
| `"NS2 Bridge.app/Contents/MacOS/NS2Bridge" --render-social <file.png>` | The finished intro frame at 1280 × 640, GitHub's social-preview size. |
| `open -n "NS2 Bridge.app" --args --screenshot-tour <folder>` | Opens the app in Demo mode with a clean state, saves every tab in light and dark as `tab-<name>-<light/dark>.png`, then quits. Use `open` (launching the binary directly from a terminal makes macOS stop it at the Bluetooth permission check). These are the images in the documentation. |

## Scripts

| Command | What |
|---|---|
| `swift test` | Unit tests (no controller needed). |
| `./scripts/build-app.sh` | Builds `build/NS2 Bridge.app` (universal, ad-hoc signed) with the helper and force-feedback plug-in. |
| `./scripts/package.sh` | Clean build, tests, and `dist/NS2Bridge-<version>-macOS.zip` + `.sha256`. |
| `./scripts/sdl-check.sh <Game.app> [seconds]` | Runs a game's own SDL like a worst-case game; reports each Nintendo controller's SDL driver and phantom input. |
| `./scripts/vpad-check.sh <Game.app> [seconds]` | With a Switch 2 controller on Bluetooth: shows the virtual gamepad the game's SDL sees, with values and (SDL3) motion. |

## Tools

| Command | What |
|---|---|
| `swift run ns2probe info` · `init` · `stream [--out file.ns2cap]` · `gc` · `rumble [preset]` | Low-level USB probe for a Switch 2 controller: descriptor dump, wake-up sequence, report stream (optionally recorded), what Apple's GameController framework sees, rumble presets. Quit NS2 Bridge first (it holds the controller). |
| `python3 research/scripts/dsu_motion_monitor.py [seconds]` | A DSU client that summarizes each controller every 2 s: transport, packets per second, motion. |
| `python3 research/scripts/*.py` | Reproduce the findings in `research/FINDINGS.md` from the recorded captures. |
