# Legal notice

**This is not legal advice.** This document explains how NS2 Bridge is built and what it
does and doesn't contain, so you can judge any risk yourself. If you need certainty for your
situation, talk to a lawyer where you live.

## 1. No affiliation, trademarks

NS2 Bridge is an independent, unofficial, open-source project. It is **not affiliated with,
authorized, sponsored, or endorsed by Nintendo Co., Ltd., Microsoft Corporation, or Apple Inc.**

- *Nintendo*, *Nintendo Switch*, *Nintendo Switch 2*, *Joy-Con*, *Pro Controller*, *Nintendo GameCube*,
  *Nintendo 64* / *N64* and *Nintendo Switch Online* are trademarks of Nintendo.
- *Xbox* and *XInput* are trademarks of Microsoft.
- *macOS* and *Mac* are trademarks of Apple.

These names appear only to describe which hardware and software NS2 Bridge works with
(nominative use). The project does not use any Nintendo, Microsoft or Apple logo. The app icon is
original artwork, a generic gamepad drawn in code (`scripts/make-icon.swift`), and the controller
pictures inside the app are simple original diagrams drawn in code (rounded shapes and labeled
buttons), not reproductions of any company's artwork or product photos. The startup animation, the
website's animated image and the social-preview image are original pixel art generated in code
(`Sources/NS2BridgeApp/IntroAnimation.swift`): a generic blocky controller built from cubes, with the
project's own name in a pixel font. The documentation's screenshots show only NS2 Bridge's own interface.
The short menu bar labels (GC, N64, PC2) are plain abbreviations.

If you fork or publish this project, keep it that way:
- Don't add company logos or product photos.
- Don't put "Nintendo" in the project or app name.
- Keep the "not affiliated" statement.

## 2. What the software contains, and what it doesn't

NS2 Bridge contains **only original code** (MIT-licensed, see `LICENSE`). It does **not** contain,
download, or distribute:

- Nintendo firmware, system software, encryption keys, pairing keys, or any Nintendo code;
- games, ROMs, BIOS files, or copyrighted game assets, or any part of a game's code;
- code copied from other projects (see `THIRD_PARTY_NOTICES.md` for the references consulted).

The `research/` folder contains recordings of **controller input reports** (button, stick, trigger and
motion values) from the project's own controllers, a HID descriptor as macOS reports it, measurement
logs, and analysis scripts written for this project. It contains no firmware, no code from any device
or game, and no personal data.

## 3. How the protocol knowledge was obtained (interoperability)

The controller protocol was learned by:
1. observing the input and output of **lawfully owned** controllers (Switch 2 Pro, NSO GameCube, NSO N64)
   connected to a Mac, using the Mac's standard USB, HID and Bluetooth interfaces;
2. reading **publicly available** community documentation and open-source drivers (listed in
   `THIRD_PARTY_NOTICES.md` and `docs/PROTOCOL.md`); and
3. for games that misbehaved with a controller, inspecting **how that game calls SDL** (its import table,
   and in one case the few instructions around an `SDL_SetHint` call) in a lawfully obtained copy, to make
   the controller work with it. No game code is reproduced.
4. to make the Bluetooth link faster, reading macOS's own Bluetooth log and inspecting the macOS Bluetooth
   system service (`bluetoothd`) and framework (CoreBluetooth) on the maintainer's Mac: their exported
   names, strings and a few functions, to find which connection-speed settings macOS accepts from an app.
   Only facts are used (method names, numeric levels, the intervals they produce, as also printed in the
   system log). No Apple code is reproduced or distributed.

The sole purpose is **interoperability**: letting a controller the user owns work with a
computer the user owns. Laws in many places specifically permit this, for example:
- **United States:** 17 U.S.C. § 1201(f), the reverse-engineering exemption for interoperability.
- **European Union:** Article 6 of Directive 2009/24/EC (decompilation for interoperability).

NS2 Bridge **does not circumvent any access control or copy protection**:
- It talks to the controller the same way the controller's own USB and Bluetooth interfaces
  invite any host to.
- It does not implement Nintendo's Bluetooth pairing/key exchange, and it contains no keys.
- It never writes to the controller's firmware or flash memory. The commands it sends set up input
  reporting and the motion sensors, the player lights and vibration, and read the battery state and the
  serial number (see §6). The optional research channel for developers (off by default) is limited to the
  same kinds of commands; it refuses memory writes, firmware updates and pairing.

Facts about how a device communicates (byte offsets, bit meanings, command numbers) are
functional information. The project's documentation describes them **in its own words**.

### Undocumented macOS interface (Bluetooth speed)

macOS keeps these controllers at a 30 ms Bluetooth interval unless asked otherwise, and Apple offers no
public way for an app to ask. The **Fastest** and **Fast** speeds (Wireless tab) therefore call an
undocumented CoreBluetooth method (`setDesiredConnectionLatency:forPeripheral:` on the central), which
macOS accepts from any app without special permission. Using an undocumented interface isn't unlawful,
but Apple doesn't support it: it may stop working in a future macOS (NS2 Bridge then simply runs at
30 ms), and apps that use such interfaces can't be distributed through the Mac App Store, which NS2 Bridge
isn't. **Standard** uses only documented interfaces. No macOS component is modified, patched or bypassed.

## 4. Games: how NS2 Bridge adds rumble

NS2 Bridge never ships or downloads games. You need your own legally obtained copies. It offers
three ways to make the controllers work fully in SDL games (rumble, full stick range, the N64's correct
driver), in order of preference:

1. **Force-feedback plug-in (no changes to games).**
   - NS2 Bridge registers a small plug-in (`NS2FF.plugin`) on the connected controller, using the
     standard macOS ForceFeedback mechanism.
   - When a game's SDL asks macOS whether the controller can vibrate, macOS loads that plug-in into
     the game, which forwards the vibration to NS2 Bridge.
   - Game files are not touched. The registration is removed when NS2 Bridge quits, and it disappears
     when the controller is unplugged.
2. **Helper at launch.** When you choose "Play with rumble", NS2 Bridge starts that game with a small
   helper library (`ns2rumble.dylib`) using a standard macOS loader feature (`DYLD_INSERT_LIBRARIES`).
   This only applies to games you launch from NS2 Bridge, and doesn't change the game's files.
   Inside the game, the helper only touches SDL's controller functions: it forwards rumble for Nintendo
   controllers, keeps SDL's N64 driver switched on, scales Nintendo controllers' stick values to their
   calibrated range, optionally presents them as Xbox controllers, and tells NS2 Bridge (on this Mac) which
   SDL driver each Nintendo controller got, and presents Switch 2 controllers connected to NS2 Bridge over
   Bluetooth as virtual SDL gamepads (games can't see them otherwise; this is how Steam Input works on a Mac
   too). It doesn't read or change anything else.
3. **Helper installed into the game** (only if you click "Install rumble into game"). This is for games
   whose signing blocks the other two methods.
   - What it does: NS2 Bridge places the helper next to the game's own SDL library, adds one load
     entry for it to that library, and re-signs only what macOS requires, for your Mac only.
   - Backups: the original files are first saved to
     `~/Library/Application Support/NS2Bridge/Backups/<game id>/`, and "Remove helper from game"
     restores them exactly.
   - macOS may ask you to allow NS2 Bridge under **Privacy & Security → App Management**.
   - The game's own program code is not changed.
   - **Do not redistribute a modified game.** Keep it for personal use on your own machine.
     Check the game's license if you're unsure; open-source recompilation projects typically permit
     personal modification.

Some games' terms of service forbid third-party tools. Online and anti-cheat-protected games are out
of scope; don't use the helper or plug-in with them.

## 5. Safety

- Switch 2 Pro vibration strength is capped at 450 of the 1023 possible levels. Open-source drivers
  note that the top of the range may damage the vibration motors. The GameCube controller's motor is only
  switched on and off, as the console does.
- The app never writes to controller flash or firmware.
- The software is provided **"as is", without warranty** (see `LICENSE`). Use at your own risk.

## 6. Privacy

- NS2 Bridge has **no telemetry, analytics or accounts**, and sends **nothing about you or your controllers**
  anywhere. Its only internet access is the **update check**: one request to GitHub's public Releases API asking
  for the latest version, only when you click *Check for Updates* or after you turn on *Check for updates
  automatically* (once a day; off by default). Links in the app (help, issues) open in your browser.
- The **diagnostics report** (Diagnostics tab) is created on your Mac, shown to you, and only saved or copied when you
  choose; it removes your home folder path, serial numbers, full Bluetooth addresses and email addresses.
- The only network sockets are local (loopback only): `127.0.0.1:26761` carries rumble requests and
  controller-driver reports from games to the app, and Bluetooth controllers' input from the app back to the
  helper in each game (on a loopback port the helper picks); `127.0.0.1:26760` is the DSU server that
  emulators on the same Mac can read controllers from. None of them is reachable from other computers.
- **Reset NS2 Bridge** (Setup) deletes everything NS2 Bridge stored or set up on the Mac.
- The **website** (info-moed.github.io/NS2Bridge) is hosted by GitHub Pages, under
  [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
  It has no analytics or cookies of its own; the page with diagrams loads the Mermaid library from the jsDelivr
  CDN.
- Battery history is kept locally in `~/Library/Application Support/NS2Bridge/battery.json`, identified
  by controller type and, for the N64, its Bluetooth address. It never leaves your Mac.
- Diagnostic recordings (`.ns2cap`) are saved only where you choose (the Desktop by default). They
  can contain your controller's serial number, so review them before sharing.
- Bluetooth diagnostics go to the macOS system log on your Mac only (subsystem `local.ns2bridge`); replies
  that carry the serial number aren't logged.
- The developer research channel (off unless enabled with `defaults write`, see `docs/DEVELOPMENT.md`)
  accepts commands from other programs on the same Mac and user account while it is on. Leave it off unless
  you are doing protocol research.
- macOS will ask for **Bluetooth** permission (for wireless controllers), and may ask for
  **Notifications** (battery alert) and **App Management** (only when installing the helper into a game).
  All are handled by macOS and can be revoked in System Settings.
- To remember each controller's settings, NS2 Bridge reads the controller's serial number (read-only, from
  the controller's own memory) and stores only a one-way fingerprint of it, on your Mac.
- With **Let SDL games and emulators use this controller** on, a small login item
  (`~/Library/LaunchAgents/local.ns2bridge.sdl-env.plist`) re-applies those game settings when you log in.
  Turning the switch off removes it.
- The published source, release and research data contain no personal information about the people who
  made them.

## 6a. AI-assisted development

NS2 Bridge was developed with AI assistance (Anthropic's Claude, via Claude Code), under the direction of
the maintainer, who tested it on real hardware and decided what shipped. The same rules apply as for any
code here: it is original to this project, and the sources consulted are credited in
`THIRD_PARTY_NOTICES.md`. The evidence behind the protocol notes is published in `research/` so it can be
checked independently.

## 7. Reporting a problem

If you are a rights holder and believe something in this repository infringes your rights,
please open an issue. It will be reviewed and, if appropriate, removed promptly.
