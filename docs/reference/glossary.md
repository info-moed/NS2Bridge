---
title: Glossary
parent: Reference
nav_order: 5
---

# Glossary

**Accelerometer.** Measures acceleration, including gravity, so it knows which way is down. Switch 2 Pro only.

**BLE (Bluetooth Low Energy).** The Bluetooth flavor the Switch 2 controllers use. NS2 Bridge connects to them
directly. The NSO N64 controller uses *classic* Bluetooth, paired by macOS.

**Connection interval.** How often a Bluetooth link exchanges data. The controller sends one report per interval, so
it sets the latency: 7.5 ms at NS2 Bridge's Fastest speed, 30 ms at macOS's default.

**Deadzone.** The small area around a stick's center that's treated as "not moved", to hide drift.

**DSU (CemuHook) protocol.** A local network protocol emulators use to receive controllers, including motion.
NS2 Bridge runs a DSU server on `127.0.0.1:26760`.

**Force-feedback plug-in.** A macOS mechanism that lets games ask a controller to vibrate. NS2 Bridge registers its
own plug-in so SDL games see rumble without the helper.

**Gyroscope (gyro).** Measures rotation speed. Used for motion aiming. Switch 2 Pro only.

**Helper.** NS2 Bridge's small library (`ns2rumble.dylib`) that runs inside a game, either attached at launch from the
Games tab or installed into the game. It adds rumble, full stick range, the N64 driver guard and virtual gamepads for
Bluetooth controllers.

**HD Rumble 2.** The Switch 2 Pro's vibration: two linear motors, each playing a low and a high band.

**HIDAPI.** SDL's own drivers for specific controllers (as opposed to its generic driver through macOS's IOKit).
The N64 controller only reads correctly with SDL's HIDAPI driver.

**IMU.** Inertial measurement unit: the gyro plus accelerometer.

**Player lights.** The LEDs showing a controller's player number.

**Profile.** A named set of stick calibration, deadzones and vibration settings for one type of controller.

**Report.** One packet of input from a controller (buttons, sticks, battery, motion). USB: 250 a second.

**SDL.** The open-source library most Mac game ports and emulators use for controllers. SDL2, SDL3 and sdl2-compat
(the SDL2 interface running on SDL3) are all supported.

**Virtual gamepad.** A controller that exists only in software. The helper creates one inside a game for each
Bluetooth controller, the way Steam Input does.
