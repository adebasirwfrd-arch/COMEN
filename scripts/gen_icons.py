#!/usr/bin/env python3
"""Render ikon PWA COMEN (perisai + centang di atas gradien navy→biru) tanpa dependensi eksternal."""
import math
import os
import struct
import zlib

NAVY = (10, 31, 68)
BLUE = (11, 95, 255)
CYAN = (0, 184, 217)
WHITE = (255, 255, 255)


def png(path, w, h, px):
    raw = b''.join(b'\x00' + bytes(px[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(data)


def inside_rounded(x, y, r):
    cx, cy = min(max(x, r), 1 - r), min(max(y, r), 1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def shield(x, y):
    """Perisai dalam koordinat normal [0,1]."""
    if y < 0.2 or y > 0.84:
        return False
    half = 0.27 if y < 0.52 else 0.27 * math.cos((y - 0.52) / 0.32 * math.pi / 2) ** 0.8
    top_dip = 0.03 * (1 - ((x - 0.5) / 0.27) ** 2) if abs(x - 0.5) <= 0.27 else 0
    return abs(x - 0.5) <= half and y >= 0.2 + top_dip * 0.0 + (0.03 - top_dip)


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def check(x, y):
    return min(seg_dist(x, y, 0.38, 0.52, 0.47, 0.62), seg_dist(x, y, 0.47, 0.62, 0.64, 0.42)) <= 0.04


def render(size, maskable=False, ss=3):
    px = bytearray(size * size * 4)
    scale = 0.8 if maskable else 1.0
    for j in range(size):
        for i in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sj in range(ss):
                for si in range(ss):
                    x = (i + (si + 0.5) / ss) / size
                    y = (j + (sj + 0.5) / ss) / size
                    if not maskable and not inside_rounded(x, y, 0.22):
                        continue
                    t = (x + y) / 2
                    col = [NAVY[k] + (BLUE[k] - NAVY[k]) * t for k in range(3)]
                    gx = math.hypot(x - 0.8, y - 0.15)
                    glow = max(0, 0.35 - gx) * 1.4
                    col = [col[k] + (CYAN[k] - col[k]) * glow for k in range(3)]
                    sx, sy = 0.5 + (x - 0.5) / scale, 0.5 + (y - 0.5) / scale
                    if shield(sx, sy):
                        col = list(BLUE) if check(sx, sy) else list(WHITE)
                    for k in range(3):
                        acc[k] += col[k]
                    acc[3] += 255
            n = ss * ss
            o = (j * size + i) * 4
            a = acc[3] / n
            if a > 0:
                px[o:o + 4] = bytes([int(acc[0] / (acc[3] / 255)), int(acc[1] / (acc[3] / 255)), int(acc[2] / (acc[3] / 255)), int(a)])
    return px


if __name__ == '__main__':
    out = os.path.join(os.path.dirname(__file__), '..', 'web', 'icons')
    os.makedirs(out, exist_ok=True)
    for name, size, mask in [('favicon.png', 64, False), ('Icon-192.png', 192, False), ('Icon-512.png', 512, False),
                             ('Icon-maskable-192.png', 192, True), ('Icon-maskable-512.png', 512, True)]:
        png(os.path.join(out, name), size, size, render(size, mask, ss=2 if size >= 512 else 3))
        print('✓', name)
