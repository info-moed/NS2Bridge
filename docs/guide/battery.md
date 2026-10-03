---
title: Battery
parent: User guide
nav_order: 9
---

# Battery

Live battery data for the selected controller, read every 10 seconds, with history kept per physical controller.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/tab-battery-dark.png">
  <img src="../images/tab-battery-light.png" alt="The Battery tab">
</picture>

- **Level and status:** percentage, charging or on battery, and the charge or discharge rate once it has about
  5 minutes of steady data.
- **Voltage history:** 1 hour, 6 hours, 24 hours or 7 days (one point per minute while NS2 Bridge runs).
- **Nerd stats:** cell voltage, highest and lowest seen, estimated charge cycles, last full charge, time charging and
  on battery, the voltage-to-percent curve in use.
- **Charge limit alert:** when a charging controller reaches the level you choose, NS2 Bridge shows a notification,
  plays a chime and buzzes the controller so you can unplug it. Keeping lithium batteries between about 20% and
  80% slows their wear. (It's an alert, not an automatic stop: the controllers don't let a computer switch their
  charging off, and Macs can't cut power to a USB-C port.) macOS asks for notification permission the first time.
- **Battery calibration:** builds a voltage-to-percent curve for this specific controller, so the percentage stays
  accurate as the battery ages. Step 1: charge it until full (NS2 Bridge notices when charging stops). Step 2: unplug
  and play wirelessly until it's low. NS2 Bridge must stay open while it times the discharge.
- **Battery life test:** play wirelessly for at least 5 minutes and NS2 Bridge projects how long a full charge lasts.
  *Start with rumble load* adds a steady gentle vibration to measure the worst case.

Cycles and times only count what NS2 Bridge has seen while running; the controllers don't store a cycle count.
History stays on your Mac (`~/Library/Application Support/NS2Bridge/battery.json`).
