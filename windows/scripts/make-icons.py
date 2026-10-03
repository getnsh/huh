#!/usr/bin/env python3
"""Draws the huh? mark into the icon files Windows wants.

The same five capsules as the Mac icon, at the same weights, with the accent on
the centre bar. Written by hand rather than pulled from a library so the shape
lives in a diff, which is how the Mac does it too.

An .ico may hold PNG payloads directly, so one encoder covers both formats.
"""
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "app" / "src-tauri" / "icons"
ICONS.mkdir(parents=True, exist_ok=True)

WEIGHTS = [0.34, 0.66, 1.0, 0.66, 0.34]
ACCENT = (158, 123, 255, 255)   # #9E7BFF
PLAIN = (236, 236, 236, 255)    # #ECECEC
TOP = (33, 33, 36, 255)
BOTTOM = (10, 10, 10, 255)


def draw(size: int) -> bytes:
    inset = size * 0.085
    left, top = inset, inset
    side = size - inset * 2
    radius = side * 0.225
    pixels = [[(0, 0, 0, 0)] * size for _ in range(size)]

    def inside_rounded(x, y):
        if not (left <= x <= left + side and top <= y <= top + side):
            return False
        cx = min(max(x, left + radius), left + side - radius)
        cy = min(max(y, top + radius), top + side - radius)
        return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2 + 0.001

    for y in range(size):
        for x in range(size):
            if not inside_rounded(x + 0.5, y + 0.5):
                continue
            t = (y - top) / side
            pixels[y][x] = tuple(
                round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(4)
            )

    bar_width = side * 0.072
    gap = side * 0.062
    total = bar_width * 5 + gap * 4
    max_height = side * 0.52
    x0 = left + side / 2 - total / 2

    for index, weight in enumerate(WEIGHTS):
        height = max(bar_width, max_height * weight)
        bx = x0 + index * (bar_width + gap)
        by = top + side / 2 - height / 2
        colour = ACCENT if index == 2 else PLAIN
        r = bar_width / 2
        for y in range(int(by), int(by + height) + 1):
            for x in range(int(bx), int(bx + bar_width) + 1):
                if not (0 <= x < size and 0 <= y < size):
                    continue
                px, py = x + 0.5, y + 0.5
                if not (bx <= px <= bx + bar_width and by <= py <= by + height):
                    continue
                cy = min(max(py, by + r), by + height - r)
                if (px - (bx + r)) ** 2 + (py - cy) ** 2 <= r ** 2 + 0.001 or (
                    by + r <= py <= by + height - r
                ):
                    pixels[y][x] = colour

    raw = b"".join(
        b"\x00" + b"".join(struct.pack("4B", *pixel) for pixel in row) for row in pixels
    )

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


written = {}
for size in (32, 128, 256):
    data = draw(size)
    written[size] = data
    (ICONS / f"{size}x{size}.png").write_bytes(data)
(ICONS / "128x128@2x.png").write_bytes(written[256])
(ICONS / "icon.png").write_bytes(written[256])

# An ICO directory of PNG payloads.
entries, payloads, offset = [], [], 6 + 16 * 3
for size in (32, 128, 256):
    data = written[size]
    entries.append(
        struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
    )
    payloads.append(data)
    offset += len(data)
(ICONS / "icon.ico").write_bytes(
    struct.pack("<HHH", 0, 1, 3) + b"".join(entries) + b"".join(payloads)
)
print("wrote", ", ".join(sorted(p.name for p in ICONS.iterdir())))
