# Controller protocol notes

Switch 2 Pro Controller (§1–8), NSO GameCube (§7b) and NSO N64 (§7c). The raw evidence and the scripts
that reproduce it are in [../research/](../research/).

Everything NS2 Bridge relies on, written in this project's own words. Every item is marked:

- **✅ Verified:** measured on real hardware by this project (Pro Controller 2, `bcdDevice 0x0201`, macOS 27).
- **📚 Documented:** from public sources (linked), used but not yet independently verified here.
- **❓ Unknown:** nobody has published it yet, as far as we know.

---

## 1. USB identity and interfaces

| | Value | |
|---|---|---|
| Vendor / product | `057E` / `2069` (Joy-Con 2 R `2066`, L `2067`, NSO GameCube `2073`) | ✅ (2069) |
| Speed | Full speed (12 Mb/s), 500 mA | ✅ |

| Interface | Class | Endpoints | Bound on macOS to | |
|---|---|---|---|---|
| 0 | HID (0x03) | interrupt IN `0x81`, OUT `0x01`, 64 B, 4 ms | Apple `AppleUserHIDDevice` (game pad, usage 1/5) | ✅ |
| 1 | Vendor (0xFF) | bulk OUT `0x02`, IN `0x82`, 64 B | **nothing**: any app can claim it | ✅ |
| 2 | Audio control | — | `AppleUSBAudio` | ✅ |
| 3 | Audio streaming, out (192 B iso) | `0x03` | `usbaudiod` (headset jack) | ✅ |
| 4 | Audio streaming, in (192 B iso) | `0x83` | `usbaudiod` (microphone) | ✅ |

The HID report descriptor on interface 0 is valid on macOS 27. It describes input report `0x09`
with four 12-bit axes and 21 buttons, and macOS tags the device as game-controller capable. ✅

## 2. Waking the controller up

Out of the box the controller **sends no input at all** until a host configures it. ✅

Commands go to interface 1's bulk OUT endpoint, and each one is answered on bulk IN. ✅

**Command header** (8 bytes, then payload):
```
[0] command   [1] 0x91 (request)   [2] transport: 00 = USB, 01 = Bluetooth
[3] subcommand   [4] 00   [5] payload length   [6..7] 00 00
```
**Reply:** `[0]` command, `[1] 0x01`, `[2] 00`, `[3]` subcommand, `[4] 00`, `[5] 0xF8`, … ✅
(0xF8 appeared on every reply we saw; it looks like "OK".)

**Sequence NS2 Bridge sends** (every command acknowledged on hardware ✅):

| Bytes | Meaning |
|---|---|
| `03 91 00 0D 00 08 00 00 01 00 FF FF FF FF FF FF` | Start HID output; last 6 bytes = host address (FF = generic) 📚 |
| `07 91 00 01 00 00 00 00` | Unknown; used by console and SDL 📚 |
| `16 91 00 01 00 00 00 00` | Unknown; used by the console 📚 |
| `09 91 00 07 00 08 00 00 <LED mask> 00…` | Player LEDs (bit 0 = LED 1) ✅ |
| `0C 91 00 02 00 04 00 00 27 00 00 00` | Feature mask. Bits: 0 buttons, 1 sticks, 2 motion, 4 mouse, 5 rumble, 7 magnetometer 📚 |
| `0C 91 00 04 00 04 00 00 27 00 00 00` | Enable those features 📚 |
| `03 91 00 0A 00 04 00 00 09 00 00 00` | Select input report format: `09` (or `05`) ✅ |

After this the controller streams report `0x09` at **~252 Hz**, and it keeps streaming after the
host releases interface 1. ✅ If the stream ever stops (sleep, host reset), send the sequence again.

## 3. Input report 0x09 (64 bytes)

| Byte | Content | |
|---|---|---|
| 0 | Report ID `0x09` | ✅ |
| 1 | 8-bit counter, +1 per report | ✅ |
| 2 | Power: bit 0 external power, bit 1 charging, bits 2–5 battery level 0–9 | ✅ (0x23 = USB, charging, 8/9) |
| 3–5 | Buttons, 24-bit little-endian (table below) | ✅ |
| 6–8 | Left stick, two 12-bit values: `x = b6 \| (b7 & 0x0F) << 8`, `y = b7 >> 4 \| b8 << 4` | ✅ |
| 9–11 | Right stick, same packing | ✅ |
| 12 | Status flags (0x38 with our feature mask) | 📚 |
| 13 | NFC state | 📚 |
| 14 | Headset state | 📚 |
| 15 | Motion data length (30 observed) | ✅ |
| 16–45 | Motion data, **packed format**: byte 16 counts +3 per report (3 IMU samples), bytes 42–43 = accel Z (int16, 4096 = 1 g); the rest undecoded ([research §7](../research/FINDINGS.md)) | ❓ partly |
| 46–63 | Zero | ✅ |

**Sticks:** up and right read higher. Measured travel is about 384–3584 with center ≈ 2000–2200,
so treating 0–4095 as full range under-reads a full tilt by about 25%. ✅

### Buttons (bytes 3–5, verified one at a time on hardware ✅)

| Bit | Button | Bit | Button | Bit | Button |
|---|---|---|---|---|---|
| 0 | B | 8 | D-pad down | 16 | Home |
| 1 | A | 9 | D-pad right | 17 | Capture |
| 2 | Y | 10 | D-pad left | 18 | GR (back right) |
| 3 | X | 11 | D-pad up | 19 | GL (back left) |
| 4 | R | 12 | L | 20 | C |
| 5 | ZR | 13 | ZL | | |
| 6 | + | 14 | − | | |
| 7 | Right stick click | 15 | Left stick click | | |

ZL and ZR are digital on this controller.

## 4. Input report 0x05 (alternative format) 📚

Selected with report format `05`. It's the layout SDL uses, and it's the only one with **documented motion data**:

| Byte (USB, incl. ID) | Content |
|---|---|
| 1–4 | 32-bit counter |
| 5–8 | Buttons (a *different* bit order from 0x09) |
| 11–16 | Sticks (12-bit packed) |
| 26–31 | Magnetometer, 3 × int16 (feature bit 7) |
| 43–46 | Motion timestamp (µs) |
| 47–48 | Temperature, int16 |
| 49–54 | Accelerometer X/Y/Z, int16, ±8 g → **4096 LSB/g** |
| 55–60 | Gyroscope X/Y/Z, int16, ±2000 °/s → **16.4 LSB/(°/s)** |
| 61–62 | Analog L/R triggers (GameCube controller only) |

Sources: ndeadly `hid_reports.md`, SDL `SDL_hidapi_switch2.c`. *Not yet verified by this project.*
NS2 Bridge switches the Pro to this format while **Motion** is on and decodes it as above (`MotionDecoder`),
with SDL's choice of gyro range by IMU clock rate. The input part of 0x05 (buttons, sticks, voltage) is
parsed too, so the controller keeps working in the app. Implemented and unit-tested; not yet run on hardware.

## 5. Rumble: output report 0x02 (HD Rumble 2)

Sent as a HID **output** report on interface 0 (`IOHIDDeviceSetReport`). Verified on hardware: both
motors, both bands, at a 4 ms cadence. ✅

```
[0]      0x02 (report ID)
[1]      0x50 | sequence (low nibble, +1 per frame, wraps at 16)
[2..6]   left motor payload (5 bytes)
[7..16]  zero
[17]     0x50 | sequence (same value)
[18..22] right motor payload (5 bytes)
[23..63] zero
```

**Payload:** four 10-bit fields packed least-significant-bit first into 40 bits:
`high-band frequency | high-band amplitude | low-band frequency | low-band amplitude`.

- Each motor plays a low band and a high band at the same time. ✅ (they feel clearly different)
- **Amplitude is capped at 450 of 1023** by SDL and Linux. Their notes say higher levels may damage
  the controller. NS2 Bridge enforces the cap. 📚
- Default frequency codes: low `0x112`, high `0x187`. **How codes map to hertz is not published** ❓
- Worked example, both bands at the cap: `87 09 27 91 70`. Silent frame: `87 01 20 11 00`. ✅ (unit-tested)

Command `0A 91 00 02 … <id>` plays built-in vibration samples (ids 0–7). 📚

## 6. Bluetooth LE (✅ with the NSO GameCube; Pro Controller not yet verified)

- The controller advertises manufacturer data with company ID `0x0553`, then VID and PID. Hold the
  **sync** button to make it connectable.
- **No standard pairing.** If a host starts BLE SMP pairing, the controller drops the link. The
  console uses a proprietary key exchange, which NS2 Bridge does not implement. Input works without it.
- Service `ab7de9be-89fe-49ad-828f-118f09df7fd0`:
  - input 0x09 on characteristic `7492866c-…`
  - input 0x05 (common report, with motion) on `ab7de9be-…-7fd2`; **one input characteristic streams at a
    time, chosen by subscription** (the USB "select input report" command does nothing over BLE) ✅
  - commands on `649d4ac9-…` (acks on `c765a961-…`). Send them one at a time, each after its reply: sent
    30 ms apart, replies go missing ✅
  - rumble on `cc483f51-…` (41 bytes: `00` + 16-byte left block + 16-byte right block)
- Commands are the same as over USB, with transport byte `[2] = 01`.
- **Motion over BLE** ✅: after the feature mask/enable (`0C 02`/`0C 04`, mask 0x2F), report 0x05 streams
  with its IMU fields all zero and "get feature info" (`0C 01`) shows the IMU as `05`. The IMU must be
  configured, which it refuses while enabled (reply byte 1 = `02`). Working sequence:
  `0C 91 01 05 00 04 00 00 04 00 00 00` (disable IMU) → `0C 91 01 06 00 0A 00 00 04 00 00 00 02 02 01 00 8A 00`
  ("configure features", ndeadly's example parameters; reply `02 00 00 00` + 2 varying bytes) →
  `0C 91 01 04 00 04 00 00 04 00 00 00` (enable IMU). Feature info then shows `07 07 07 00 00 07 00 00` and
  0x05 carries motion at the same scale as USB. None of the init commands (nor the report-rate descriptor or a
  subscription change) clears the configured state once set (tested one by one), so the IMU arrives
  unconfigured over BLE. Other hosts report motion without `0C 06`; their controllers may still have been
  configured by an earlier USB or console session.
- **Latency** ✅: one report per connection event. The controller never requests a connection interval, so
  macOS keeps its default: it asks for 10–30 ms and the chip picks **30 ms** (≈ 34 reports/s). The Switch 2
  console sets 5 ms. A macOS central app *can* ask for a shorter one with the private
  `-[CBCentralManager setDesiredConnectionLatency:(long long) forPeripheral:]` (no entitlement needed);
  bluetoothd accepts levels −25…2 besides the public 0/1/2. Measured with the Pro (report 0x05 and 0x09 alike):

  | Level | bluetoothd name | Interval | Result |
  |---|---|---|---|
  | 0 | low (macOS default) | 10–30 ms → 30 | ≈ 34 reports/s |
  | −7 | very-low | 15 ms | ≈ 68/s, steady |
  | **−12** | **midi v2** | **7.5 ms** (event length 3) | **≈ 133/s, steady, motion correct** (NS2 Bridge: Fastest) |
  | −25 | super-low | 7.5 ms (event length 2) | stream collapses to a few reports/s |
  | −22 | LEHID-5ms | — | accepted, never applied on this Mac's chip |

  The request lasts for the connection; NS2 Bridge sends it at every connect.

## 7. Flash memory (read-only use) 📚

| Address | Content |
|---|---|
| `0x13000` | Serial / factory info |
| `0x13040` | Gyro bias (floats) |
| `0x13080`, `0x130C0` | Left / right stick factory calibration |
| `0x13100` | Accelerometer bias (floats) |
| `0x1FC040`, `0x1FC060` | User stick calibration |

NS2 Bridge doesn't read or write flash yet. Stick calibration is done in the app.

## 7b. NSO GameCube Controller (057E:2073, bcdDevice 0x0101) ✅

Same interfaces and 0x91 wake-up as the Pro Controller 2; select report format `0A`. Streams input report
`0x0A` at ≈ 252 Hz. The HID descriptor describes 0x0A like 0x09 (21 buttons + four 12-bit axes), so SDL's
generic backend reads it with a mapping.

| Byte | Content |
|---|---|
| 1 | counter · 2 power (as 0x09) |
| 3–5 | buttons: bit 0 B, 1 A, 2 Y, 3 X, **4 R click, 5 Z**, 6 Start, 8 ↓, 9 →, 10 ←, 11 ↑, **12 L click, 13 ZL**, 16 Home, 17 Capture, 20 C |
| 6–11 | control stick, C-stick (12-bit packed); ±≈1200 from center, near-round gate (diagonal radius ≈ 1.04× cardinal) |
| 13, 14 | analog L, R: rest ≈ 33, full ≈ 220; the click bits set at ≈ 216 |
| 15–45 | motion length (30) + packed motion, as 0x09 |

ndeadly's table swaps Z ↔ R click and ZL ↔ L click; verified one button at a time (`research/captures/gamecube-usb-buttons.ns2cap`).
Rumble: output report `0x03` = `[03, 0x50|seq, motor]`, motor 1 on / 0 off / 2 brake; strength by duty cycle
(sent every 4 ms). Full, half and 20 % felt distinct on hardware.

**Bluetooth LE** ✅: same service as the Pro; input 0x0A on characteristic `8261cba1-9435-420c-84d6-f0c75a2c8e4d`,
rumble 0x03 on `3f8fb670-ab25-45bf-b540-38c72834d064` (`00` + the USB report from byte 1). No pairing needed;
≈ 33 reports/s at macOS's default interval (the 7.5 ms setting is untested with the GameCube 🧪).

## 7c. NSO N64 Controller (057E:2019) ✅

- Speaks the original Switch protocol. macOS performs the USB handshake itself, so it streams full report
  `0x30` every **15 ms** (the controller's own rate).
- Buttons in bytes 3–5 use the Pro Controller (Switch 1) positions: A, B, C-buttons on Y/X/ZR/−, Z on ZL,
  ZR on the left-stick click, Start on +, plus L, R, Home, Capture, D-pad; stick in bytes 6–8.
- Rumble: Switch 1 output report `0x10` (`00 C9 40 72` = full); subcommands via report `0x01`
  (0x02 device info incl. firmware and address, 0x30 player lights, 0x48 vibration, 0x50 battery voltage
  × 2.5 mV, 0x06 00 disconnect over Bluetooth).
- **Its HID report descriptor doesn't match report 0x30**, so generic HID readers (SDL's IOKit backend) see
  the timer byte as buttons and the buttons as axes. Only SDL's own HIDAPI driver reads it correctly
  ([research §3–5](../research/FINDINGS.md)).

## 8. Corrections to widely shared early notes

| Early claim | What's actually true |
|---|---|
| Gyro at byte 47 of report 0x05 | Byte 47 is **temperature**; gyro is 55–60 📚 |
| Gyro 133.3 LSB/(°/s) | **16.4** LSB/(°/s) at ±2000 °/s 📚 |
| Accel 16384 LSB/g | **4096** LSB/g at ±8 g 📚 |
| HID descriptor is "garbage" | Valid on macOS 27 (report 0x09 described) ✅ |
| Vendor interface is #2 | It's **#1** ✅ |
| `03 91 … 0A … 09` = "enable haptics" | It **selects the input report format** ✅ |
| NSO GameCube 0x0A: bit 4 Z, bit 5 R, bit 12 ZL, bit 13 L | **Bit 4 = R click, 5 = Z, 12 = L click, 13 = ZL** ✅ |

## Sources

- ndeadly, [switch2_controller_research](https://github.com/ndeadly/switch2_controller_research): `hid_reports.md`, `commands.md`, `bluetooth_interface.md`, `memory_layout.md`
- libsdl-org, [SDL_hidapi_switch2.c](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch2.c)
- Linux `hid-nintendo` Switch 2 patch series, linux-input mailing list, 2026
- [caqlayan/procon2-mac](https://github.com/caqlayan/procon2-mac), [darthcloud/BlueRetro](https://github.com/darthcloud/BlueRetro)
