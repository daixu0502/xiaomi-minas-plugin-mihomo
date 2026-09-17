#!/usr/bin/env python3
"""Generate the local Mihomo plugin icon using only the Python standard library."""

import binascii
import math
import struct
import sys
import zlib


SIZE = 300
LOGICAL_SIZE = 256
SCALE = 2


def rounded_rect_contains(x, y, left, top, right, bottom, radius):
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2


def line_distance(px, py, ax, ay, bx, by):
    dx = bx - ax
    dy = by - ay
    length_sq = dx * dx + dy * dy
    if length_sq == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length_sq))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def high_res_pixel(x, y):
    unit_x = x / SCALE * LOGICAL_SIZE / SIZE
    unit_y = y / SCALE * LOGICAL_SIZE / SIZE
    if not rounded_rect_contains(unit_x, unit_y, 0, 0, 256, 256, 48):
        return (0, 0, 0, 0)

    mix = max(0.0, min(1.0, (unit_x + unit_y) / 512))
    start = (39, 200, 184)
    end = (8, 113, 105)
    color = tuple(round(start[i] * (1 - mix) + end[i] * mix) for i in range(3))

    strokes = (
        (72, 78, 72, 180, 15),
        (72, 78, 128, 151, 15),
        (128, 151, 184, 78, 15),
        (184, 78, 184, 180, 15),
    )
    if any(line_distance(unit_x, unit_y, *stroke[:4]) <= stroke[4] for stroke in strokes):
        return (255, 255, 255, 255)
    if math.hypot(unit_x - 198, unit_y - 190) <= 11:
        return (185, 255, 247, 255)
    return (*color, 255)


def render():
    high_size = SIZE * SCALE
    high = [[high_res_pixel(x + 0.5, y + 0.5) for x in range(high_size)] for y in range(high_size)]
    rows = []
    area = SCALE * SCALE
    for y in range(SIZE):
        row = bytearray([0])
        for x in range(SIZE):
            samples = [high[y * SCALE + sy][x * SCALE + sx] for sy in range(SCALE) for sx in range(SCALE)]
            for channel in range(4):
                row.append(sum(pixel[channel] for pixel in samples) // area)
        rows.append(bytes(row))
    return b"".join(rows)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: make_icon.py OUTPUT")
    raw = render()
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(sys.argv[1], "wb") as output:
        output.write(png)


if __name__ == "__main__":
    main()
