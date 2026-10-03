---
title: Latency Test
parent: User guide
nav_order: 11
---

# Latency Test (Advanced)

A 10-second measurement of how fast the selected controller's reports arrive, compared with what the link should
deliver, for USB and Bluetooth.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/tab-latency-test-dark.png">
  <img src="../images/tab-latency-test-light.png" alt="The Latency Test tab">
</picture>

| Row | Meaning |
|---|---|
| Report rate, average interval | How often a report arrives. USB: every 4 ms (250 Hz). Bluetooth: depends on the [Speed](bluetooth.md#speed) setting. |
| 99% of reports within, jitter | How steady the stream is. |
| Dropped reports | Gaps in the controller's report counter. |
| Added input latency | What the link adds on top of the game: on average half an interval (you wait for the next report), at worst a full one. |

The histogram shows the spread of intervals (green = expected). **Copy results** puts a text summary on the
clipboard, handy for bug reports. It measures the link, not your display or the game's frame time.

Reference values: USB 4 ms · NS2 Bridge over Bluetooth 7.5 ms (Fastest) · macOS's Bluetooth default 30 ms ·
Switch 2 console over Bluetooth 5 ms. The NSO N64 controller reports every 15 ms on both USB and Bluetooth (its own
rate).
