#!/usr/bin/env python3
"""Reproduces the NSO GameCube (USB, report 0x0A) findings from ../captures/gamecube-usb-buttons.ns2cap.

The person pressed, in order, about a second each: A, B, X, Y, Z, ZL, L (slowly to the click), R (same),
Start, Home, Capture, C, D-pad up/down/left/right, then rolled both sticks around their edges.

Shows: which bit each press set (and so the Z/R-click and ZL/L-click swap vs. ndeadly's table),
the analog trigger value when the click bit sets, rest/peak trigger values, stick travel and gate shape.
"""
import math
from pathlib import Path
from ns2cap import read, stick

CAP = Path(__file__).parent.parent / "captures" / "gamecube-usb-buttons.ns2cap"
PRESSED_IN_ORDER = ["A", "B", "X", "Y", "Z", "ZL", "L (click)", "R (click)", "Start", "Home", "Capture", "C",
                    "D-pad up", "D-pad down", "D-pad left", "D-pad right"]

reports = [(ms, r) for ms, r in read(CAP) if r[0] == 0x0A]
buttons = lambda r: r[3] | r[4] << 8 | r[5] << 16

print("1. Bits in order of first press (bytes 3-5, little-endian):")
seen, prev = [], 0
for ms, r in reports:
    b = buttons(r)
    for bit in range(24):
        if b >> bit & 1 and not prev >> bit & 1 and bit not in seen:
            seen.append(bit)
    prev = b
for name, bit in zip(PRESSED_IN_ORDER, seen):
    print(f"   {name:12s} → bit {bit:2d}  (byte {3 + bit // 8}, mask 0x{1 << bit % 8:02X})")

print("\n2. Which bits are the full-press clicks? Analog value while each bit is held:")
for bit in (4, 5, 12, 13):
    held = [(r[13], r[14]) for _, r in reports if buttons(r) >> bit & 1]
    print(f"   bit {bit:2d}: analog L {min(h[0] for h in held)}..{max(h[0] for h in held)}, "
          f"R {min(h[1] for h in held)}..{max(h[1] for h in held)}")
print("   → bit 4 = R click and bit 12 = L click (only at full travel); bits 5 / 13 = Z / ZL.")

print("\n3. Analog triggers (bytes 13, 14):")
for name, idx, bit in (("L", 13, 12), ("R", 14, 4)):
    vals = [r[idx] for _, r in reports]
    click = next(r[idx] for _, r in reports if buttons(r) >> bit & 1)
    print(f"   {name}: rest ≈ {sorted(vals)[len(vals) // 2]}, peak {max(vals)}, click fires at {click}")

print("\n4. Sticks (bytes 6-8 main, 9-11 C-stick): travel and gate shape")
for name, o in (("main", 6), ("C", 9)):
    cx, cy = stick(reports[0][1], o)
    sectors = {}
    for _, r in reports:
        x, y = stick(r, o)
        dx, dy = x - cx, y - cy
        rad = math.hypot(dx, dy)
        if rad > 300:
            s = int(((math.degrees(math.atan2(dy, dx)) + 360 + 11.25) % 360) // 22.5)
            sectors[s] = max(sectors.get(s, 0), rad)
    card = sum(sectors.get(k, 0) for k in (0, 4, 8, 12)) / 4
    diag = sum(sectors.get(k, 0) for k in (2, 6, 10, 14)) / 4
    xs = [stick(r, o)[0] for _, r in reports]
    print(f"   {name}: center {cx},{cy}; x {min(xs)}..{max(xs)}; reach ≈ {card:.0f} straight, {diag:.0f} diagonal "
          f"(diag/straight {diag / card:.2f}: a near-round octagon)")
    print(f"      read linearly over 0-4095 (what SDL's IOKit backend does) a full push is ≈ {card / 2047.5 * 100:.0f}%")
