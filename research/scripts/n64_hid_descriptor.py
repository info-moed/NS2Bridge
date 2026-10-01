#!/usr/bin/env python3
"""Why the NSO N64 controller reads as garbage through macOS's generic HID path (IOKit).

Parses ../data/n64-usb-hid-report-descriptor.txt and prints how it describes input report 0x30, next to
what report 0x30 really contains (the original-Switch full report). A generic HID reader such as SDL's
IOKit backend follows the descriptor, so the report's timer byte becomes buttons 1-8 (phantom presses
~66 times a second) and the real buttons and stick land in the "axes". SDL's own HIDAPI driver reads the
real layout, which is why NS2 Bridge keeps that driver on.
"""
from pathlib import Path

hexdata = [l for l in (Path(__file__).parent.parent / "data" / "n64-usb-hid-report-descriptor.txt").read_text().splitlines()
           if l and not l.startswith("#")][0]
d = bytes.fromhex(hexdata)

i, report_id, bit, fields = 0, None, 0, []
size = count = 0
usage_page = 0
usages = []
while i < len(d):
    prefix = d[i]
    n = {0: 0, 1: 1, 2: 2, 3: 4}[prefix & 3]
    tag, typ = prefix >> 4, prefix >> 2 & 3
    val = int.from_bytes(d[i + 1:i + 1 + n], "little")
    i += 1 + n
    if typ == 1 and tag == 0x0: usage_page = val
    elif typ == 1 and tag == 0x7: size = val
    elif typ == 1 and tag == 0x9: count = val
    elif typ == 1 and tag == 0x8: report_id, bit = val, 0
    elif typ == 2 and tag == 0x0:                       # Usage; a 4-byte one carries its own page
        usages.append((val >> 16, val & 0xFFFF) if n == 4 else (usage_page, val))
    elif typ == 2 and tag == 0x1: usages = [(usage_page, f"{val}..")]
    elif typ == 0 and tag == 0x8:                       # Input item
        if report_id == 0x30:
            const = val & 1
            names = {0x30: "X", 0x31: "Y", 0x32: "Z", 0x35: "Rz", 0x39: "hat"}
            generic = [names.get(u, hex(u)) for pg, u in usages if pg == 1]
            what = ("padding" if const else "axes " + "/".join(generic) if generic and "hat" not in generic
                    else "hat switch" if generic else "buttons" if usage_page == 9 else f"page 0x{usage_page:02X}")
            fields.append((bit, size * count, size, count, what))
        bit += size * count
        usages = []
    elif typ == 0 and tag in (0xA, 0xC):
        usages = []

real = {1: "timer", 2: "battery / connection", 3: "buttons (right)", 4: "buttons (shared)", 5: "buttons (left)",
        6: "left stick", 7: "left stick", 8: "left stick", 9: "right stick (unused)", 10: "right stick (unused)",
        11: "right stick (unused)", 12: "vibration status"}
print("Report 0x30 as the descriptor describes it     | what those bytes really are")
for start, bits, size, count, what in fields:
    b0, b1 = 1 + start // 8, 1 + (start + bits - 1) // 8
    print(f"  bytes {b0:2d}-{b1:2d}: {count:2d} × {size:2d}-bit {what:<24.24s} | {', '.join(sorted({real.get(b, 'zero') for b in range(b0, b1 + 1)}))}")
