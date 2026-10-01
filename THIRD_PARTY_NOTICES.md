# Third-party notices and references

NS2 Bridge contains **no third-party source code**. It links only Apple system frameworks
(IOKit, IOUSBHost, CoreBluetooth, GameController, ServiceManagement, SwiftUI, AppKit). The Bluetooth
speed setting calls one undocumented CoreBluetooth method (see `LEGAL.md`, "Undocumented macOS interface").

The projects below were **consulted as references** for how the controller behaves. Where a
project's code informed an implementation, that's noted, and the implementation in this repository
was written independently. Facts about the protocol are described in this project's own words.

| Project | License | How it was used |
|---|---|---|
| [SDL](https://github.com/libsdl-org/SDL): `src/joystick/hidapi/SDL_hidapi_switch2.c` | zlib | Reference for the Switch 2 init sequence, the flash calibration addresses, the HD Rumble 2 bit packing (`EncodeHDRumble`), the report 0x05 IMU offsets and scales, and the GameCube button and rumble handling. NS2 Bridge's `HDRumble2Encoder`, `MotionDecoder` and `GameCubeRumble` are independent Swift implementations. The zlib license permits this use; credit is given here. |
| SDL: `SDL_hidapi_switch.c`, `SDL_gamepad.c` / `SDL_gamecontroller.c`, the IOKit joystick backend | zlib | Reference for how SDL numbers the N64 controller's buttons (SDL2 vs SDL3), how it matches mapping GUIDs (CRC and version fallbacks), and how it scales IOKit axes. Facts only. `tools/sdlcheck.c` and `tools/vpadcheck.c` declare a handful of SDL function prototypes to call a game's own SDL, and the helper declares the layout of SDL's `SDL_VirtualJoystickDesc` (SDL2 and SDL3 public headers) to attach virtual gamepads; these are interface declarations, not SDL code. |
| Linux `hid-nintendo` Switch 2 patch series (Vicki Pfau, 2026, linux-input mailing list) | GPL-2.0 | Consulted for protocol facts only (rumble field layout, amplitude cap of 450, 4 ms cadence). **No code was copied.** |
| [ndeadly/switch2_controller_research](https://github.com/ndeadly/switch2_controller_research) | none stated | Factual reference for report layouts, commands, the memory map and the Bluetooth interface, including the example "configure features" command bytes NS2 Bridge sends to enable motion over Bluetooth (a short functional command, not prose). Its published Bluetooth captures were analyzed for IMU timing facts. **No text, tables or files are reproduced.** Facts are restated in `docs/PROTOCOL.md` with links back. |
| [dekuNukem/Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering) | none stated | Background on original-Switch controllers (12-bit stick packing). Reference only. |
| [caqlayan/procon2-mac](https://github.com/caqlayan/procon2-mac) | MIT | Confirmed that a CoreBluetooth central can connect without Nintendo pairing. Reference only; no code used. |
| [darthcloud/BlueRetro](https://github.com/darthcloud/BlueRetro) | Apache-2.0 | Background on Switch 2 Bluetooth bring-up and connection intervals. Reference only. |
| HandHeldLegend *procon2tool* | not available | Its published rumble frame layout (report 0x02, counter byte, dual 5-byte payloads) was widely cited in the community. The four "canned" vibration byte patterns in `Rumble.swift` come from that tool via the author's earlier prototype; they are short data values, not code. |
| [360Controller/360Controller](https://github.com/360Controller/360Controller) | GPL-2.0 (see repo) | Reference only: its Feedback360 plug-in confirmed the ForceFeedback plug-in type ID (`F4545CE5-BF5B-11D6-A4BB-0003933E3E3E`), a fixed interface identifier. `NS2FF.plugin` is written independently; **no code was copied**. |
| [esp-cpp/espp](https://github.com/esp-cpp/espp), pull request #765 (Switch 2 Pro Controller emulator) | see repo | Facts about the Bluetooth connection: one report per connection event, the console's 15 ms → 5 ms connection update. Reference only; no code used. |
| [martin-bts/hid-switch2-dkms](https://github.com/martin-bts/hid-switch2-dkms) (Linux driver and BlueZ plugin) | see repo | Facts: a Linux host requests a 7.5 ms interval for these controllers; notes on IMU timing. Reference only; no code used. |
| [TommyWabg/Switch2Connect](https://github.com/TommyWabg/Switch2Connect), [joypad-ai/joypad-os](https://github.com/joypad-ai/joypad-os) | see repos | Report rates other hosts and adapters achieve, and which init commands they send. Reference only; no code used. |
| [v1993/cemuhook-protocol](https://v1993.github.io/cemuhook-protocol/) | — | Protocol description for the DSU (CemuHook) server in `DSUServer.swift`. |
| [Dolphin](https://github.com/dolphin-emu/dolphin): `DualShockUDPProto.h`, `DualShockUDPClient.cpp`, `SDL` input backend | GPL-2.0-or-later | Consulted for the DSU message layout, which bytes a client actually reads (the analog button bytes), and the axis conventions of its DSU and SDL inputs, from which the SDL → DSU motion conversion was derived. **No code was copied**; `DSUServer.swift` is written independently. |
| DS4Windows (`UdpServer.cs`, via Dolphin's notes) | — | The DSU button bit order, as documented by Dolphin. Reference only. |
| [Kenix3/libultraship](https://github.com/Kenix3/libultraship): `ControllerStick.cpp`, `SDLAxisDirectionToAxisDirectionMapping.cpp` | MIT | Read to understand how games built on it combine several controllers and scale stick values (research §6). Reference only; nothing is used in NS2 Bridge. |

## SDL zlib license (reproduced for credit)

```
Simple DirectMedia Layer
Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

Games tested with NS2 Bridge (Wave Race 64 Recompiled, BattleShip, and three other SDL ports of N64
games) are separate projects under their own licenses. None of their code or assets is
included here; only how they call SDL was examined, for interoperability.
