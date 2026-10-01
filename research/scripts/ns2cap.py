#!/usr/bin/env python3
"""Reader for NS2 Bridge .ns2cap captures, plus a summary when run directly.

Format: the 4 bytes "NS2C", then records of  u32 LE milliseconds since the recording started,
u16 LE length, and that many bytes of one raw input report (byte 0 = report ID).
A .labels file next to a capture is tab-separated: milliseconds <TAB> what the person was asked to do.

    python3 ns2cap.py ../captures/gamecube-usb-buttons.ns2cap
"""
import struct
import sys
from pathlib import Path


def read(path):
    """[(ms, bytes)] for every report in a capture."""
    d = Path(path).read_bytes()
    if d[:4] != b"NS2C":
        raise ValueError(f"{path}: not an .ns2cap file")
    out, i = [], 4
    while i + 6 <= len(d):
        ms, n = struct.unpack_from("<IH", d, i)
        i += 6
        out.append((ms, d[i:i + n]))
        i += n
    return out


def labels(path):
    """[(ms, text)] from the .labels file next to a capture (empty if there is none)."""
    p = Path(path).with_suffix(".labels")
    if not p.exists():
        return []
    rows = []
    for line in p.read_text().splitlines():
        if "\t" in line:
            ms, text = line.split("\t", 1)
            rows.append((int(ms), text))
    return rows


def stick(r, o):
    """Two 12-bit values packed into 3 bytes (Switch 1 and Switch 2 families)."""
    return r[o] | (r[o + 1] & 0x0F) << 8, r[o + 1] >> 4 | r[o + 2] << 4


if __name__ == "__main__":
    for path in sys.argv[1:] or sorted(Path(__file__).parent.parent.joinpath("captures").glob("*.ns2cap")):
        reports = read(path)
        ids = {}
        for _, r in reports:
            ids[r[0]] = ids.get(r[0], 0) + 1
        secs = (reports[-1][0] - reports[0][0]) / 1000
        print(f"{Path(path).name}: {len(reports)} reports over {secs:.0f} s "
              f"(≈{len(reports) / secs:.0f}/s), report IDs {', '.join(f'0x{k:02X}×{v}' for k, v in ids.items())}, "
              f"{len(labels(path))} labels")
