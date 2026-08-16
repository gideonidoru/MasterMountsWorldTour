#!/usr/bin/env python3
"""Generate Media/expand.tga -- the compact window's enlarge control.

A double-headed diagonal arrow (SW <-> NE): the universal expand/resize glyph.
Deliberately thin-shaft-plus-head rather than the solid triangular pointer used
by Media/arrow.tga, so it never reads as navigation.

White RGB with the shape carried entirely in alpha, so the addon can vertex-tint
it grey at rest / gold on hover without touching the art.

Matches arrow.tga's container: 256x256, uncompressed 32-bit BGRA, bottom-left
origin (TGA descriptor 0x08). Power-of-two dimensions are required by WoW.
"""
import struct

N, SS = 64, 8          # output size, supersampling factor
R = N * SS

def clamp(v, lo, hi): return lo if v < lo else hi if v > hi else v

def seg_dist(px, py, ax, ay, bx, by):
    """Distance from point to line segment ab."""
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    L2 = vx * vx + vy * vy
    t = clamp((wx * vx + wy * vy) / L2, 0.0, 1.0) if L2 else 0.0
    dx, dy = wx - t * vx, wy - t * vy
    return (dx * dx + dy * dy) ** 0.5

# Geometry in 0..1 space, y measured DOWN from the top of the image.
# NE = (high x, low y); SW = (low x, high y).
TIP_NE, TIP_SW = (0.88, 0.12), (0.12, 0.88)
SHAFT_HALF = 0.038          # half-thickness of the shaft
# Barbs must sit at a wide enough angle that open space stays visible inside the
# V. Too narrow and the two barbs plus the shaft merge into a solid wedge, which
# is what makes an arrow read as a filled navigation pointer instead of a line.
HEAD_LEN, HEAD_HALF = 0.21, 0.125   # arrowhead barb length / half-spread

def heads(tip, dx, dy):
    """The two barbs of an arrowhead at `tip` pointing along unit (dx,dy)."""
    bx, by = tip[0] - dx * HEAD_LEN, tip[1] - dy * HEAD_LEN   # base centre
    px, py = -dy, dx                                          # perpendicular
    return [(tip, (bx + px * HEAD_HALF, by + py * HEAD_HALF)),
            (tip, (bx - px * HEAD_HALF, by - py * HEAD_HALF))]

D = 0.7071067811865476   # unit diagonal component
STROKES = [(TIP_SW, TIP_NE)]                      # the shaft
STROKES += heads(TIP_NE, D, -D)                   # barbs pointing NE
STROKES += heads(TIP_SW, -D, D)                   # barbs pointing SW

# Render supersampled coverage: a pixel is inside if it lies within
# SHAFT_HALF of any stroke. Rounded ends come free from segment distance.
cov = bytearray(N * N)
acc = [0] * (N * N)
for sy in range(R):
    py = (sy + 0.5) / R
    for sx in range(R):
        px = (sx + 0.5) / R
        for a, b in STROKES:
            if seg_dist(px, py, a[0], a[1], b[0], b[1]) <= SHAFT_HALF:
                acc[(sy // SS) * N + (sx // SS)] += 1
                break
for i, v in enumerate(acc):
    cov[i] = min(255, round(v * 255 / (SS * SS)))

# TGA: bottom-left origin, so emit rows bottom-up.
hdr = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, N, N, 32, 0x08)
px = bytearray()
for y in range(N - 1, -1, -1):
    for x in range(N):
        a = cov[y * N + x]
        px += bytes((255, 255, 255, a))      # BGRA, white with alpha shape
open("Media/expand.tga", "wb").write(hdr + bytes(px))
print("wrote Media/expand.tga", 18 + N * N * 4, "bytes")
