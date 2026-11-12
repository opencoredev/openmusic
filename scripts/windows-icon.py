#!/usr/bin/env python3
"""Draws the Windows app icon (windows/src/OpenMusic.App/Assets/OpenMusic.ico and OpenMusic.png) with no image libraries:
a rounded square with a warm-to-violet gradient and a white pair of beamed notes. Rerun after changing the design."""
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "windows", "src", "OpenMusic.App", "Assets")


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


def rounded_rect_sd(x, y, cx, cy, hw, hh, r):
    qx = abs(x - cx) - hw + r
    qy = abs(y - cy) - hh + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def ellipse_sd(x, y, cx, cy, rx, ry, angle):
    c, s = math.cos(angle), math.sin(angle)
    dx, dy = x - cx, y - cy
    u = (dx * c + dy * s) / rx
    v = (-dx * s + dy * c) / ry
    return (math.hypot(u, v) - 1) * min(rx, ry)


def box_sd(x, y, x0, y0, x1, y1):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    return rounded_rect_sd(x, y, cx, cy, (x1 - x0) / 2, (y1 - y0) / 2, 0)


def beam_sd(x, y, x0, y0, x1, y1, thick):
    # A slanted parallelogram from (x0, y0) to (x1, y1), `thick` tall.
    t = clamp((x - x0) / (x1 - x0))
    top = y0 + (y1 - y0) * t
    vertical = max(top - y, y - (top + thick))
    horizontal = max(x0 - x, x - x1)
    return max(vertical, horizontal)


def render(size):
    px = bytearray()
    s = float(size)
    for j in range(size):
        px.append(0)  # PNG filter: none
        for i in range(size):
            x, y = (i + 0.5) / s, (j + 0.5) / s
            d = rounded_rect_sd(x, y, 0.5, 0.5, 0.46, 0.46, 0.2) * s
            a = clamp(0.5 - d)
            # Gradient: coral top-left to violet bottom-right.
            t = clamp((x + y) / 2)
            r = (1.00 * (1 - t) + 0.48 * t)
            g = (0.37 * (1 - t) + 0.30 * t)
            b = (0.43 * (1 - t) + 1.00 * t)
            # Soft highlight at the top.
            hl = clamp(1 - math.hypot(x - 0.3, y - 0.15) / 0.6) * 0.18
            r, g, b = clamp(r + hl), clamp(g + hl), clamp(b + hl)
            # Notes: two heads, two stems, one beam.
            sd = min(
                ellipse_sd(x, y, 0.36, 0.70, 0.095, 0.075, -0.45),
                ellipse_sd(x, y, 0.64, 0.64, 0.095, 0.075, -0.45),
                box_sd(x, y, 0.405, 0.30, 0.445, 0.70),
                box_sd(x, y, 0.685, 0.24, 0.725, 0.64),
            ) * s
            bd = beam_sd(x, y, 0.405, 0.27, 0.725, 0.21, 0.09) * s
            sd = min(sd, bd)
            w = clamp(0.5 - sd)
            r, g, b = r * (1 - w) + w, g * (1 - w) + w, b * (1 - w) + w
            px += bytes([int(r * 255 + 0.5), int(g * 255 + 0.5), int(b * 255 + 0.5), int(a * 255 + 0.5)])
    return bytes(px)


def png(size):
    raw = render(size)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main():
    os.makedirs(ASSETS, exist_ok=True)
    sizes = [16, 20, 24, 32, 40, 48, 64, 256]
    images = [png(n) for n in sizes]
    header = struct.pack("<HHH", 0, 1, len(sizes))
    offset = 6 + 16 * len(sizes)
    entries = b""
    for n, data in zip(sizes, images):
        entries += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    with open(os.path.join(ASSETS, "OpenMusic.ico"), "wb") as f:
        f.write(header + entries + b"".join(images))
    with open(os.path.join(ASSETS, "OpenMusic.png"), "wb") as f:
        f.write(images[-1])
    print("wrote", ASSETS)


if __name__ == "__main__":
    main()
