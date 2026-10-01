#!/usr/bin/env python3
"""The Switch 2 Pro's packed motion data in report 0x09 (bytes 16-45): what could be decoded.

Uses ../captures/pro2-usb-guided-motion.ns2cap, recorded with guided segments (see its .labels):
still (flat on a desk), pitch, still, roll, still, yaw, still, then stick circles and buttons.

Prints per-bit flip rates while still (noise sits in low bits, counters show a halving pattern, constant
fields never flip), the sample counter (+3 per report = 3 IMU samples per 4 ms report), and the int16 at
bytes 42-43 that reads ≈ 4096 (1 g) while the controller lies flat. Everything else looked compressed or
integrated and is left undecoded; NS2 Bridge reads motion from report 0x05 instead.
"""
from pathlib import Path
from ns2cap import read

CAP = Path(__file__).parent.parent / "captures" / "pro2-usb-guided-motion.ns2cap"
reports = [(ms, r) for ms, r in read(CAP) if r[0] == 0x09]
still = [r[16:46] for ms, r in reports if 1500 < ms < 4800]

print(f"Motion length byte (15): {sorted({r[15] for _, r in reports})}")
print("Flip rate per bit while still, % of consecutive reports (motion byte n = report byte 16+n):")
flips = [0] * 240
for a, b in zip(still, still[1:]):
    x = int.from_bytes(a, "little") ^ int.from_bytes(b, "little")
    for i in range(240):
        flips[i] += x >> i & 1
for byte in range(30):
    print(f"  m{byte:2d} (byte {16 + byte:2d}): " + " ".join(f"{100 * flips[byte * 8 + k] // (len(still) - 1):3d}" for k in range(8)))

steps = [(b[0] - a[0]) & 0xFF for a, b in zip(still, still[1:])]
print(f"\nm0 (byte 16) steps between reports: most common {max(set(steps), key=steps.count)} → 3 samples per report")
z = [int.from_bytes(m[26:28], "little", signed=True) for m in still]
print(f"int16 at m26-27 (bytes 42-43) while flat: {min(z)}..{max(z)} ≈ 4096 = 1 g at ±8 g range → accel Z")
