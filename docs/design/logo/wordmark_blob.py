"""MYO wordmark: lowercase "myo" drawn as one metaball field, the same idea as
the One Body blob. Strokes are skeleton lines; each adds a Gaussian falloff and
the word is wherever the summed field passes 0.5, so strokes swell where they
meet. The o is a soft amber blob sitting on the baseline.

Units: x-height 100, baseline at y=100. Needs numpy + pillow.
python wordmark_blob.py  ->  myo-wordmark.png
"""
import os
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
INK = np.array([26, 20, 16]); AMBER = np.array([246, 166, 9])
S = 8  # samples per unit
xs = np.arange(-30, 380, 1 / S); ys = np.arange(-30, 185, 1 / S)
X, Y = np.meshgrid(xs, ys)


def seg(ax, ay, bx, by):
    px, py, dx, dy = X - ax, Y - ay, bx - ax, by - ay
    t = np.clip((px * dx + py * dy) / (dx * dx + dy * dy), 0, 1)
    return np.hypot(px - dx * t, py - dy * t)


def arch(cx, cy, r):  # upper half of a ring
    ring = np.abs(np.hypot(X - cx, Y - cy) - r)
    ends = np.minimum(np.hypot(X - cx + r, Y - cy), np.hypot(X - cx - r, Y - cy))
    return np.where(Y <= cy, ring, ends)


def blob(cx, cy, r):
    th = np.arctan2(Y - cy, X - cx)
    rr = r * (1 + 0.035 * np.sin(2 * th - 0.6) + 0.025 * np.sin(3 * th + 1.2))
    return np.maximum(np.hypot(X - cx, Y - cy) - rr, 0)


def field(ds, s=13.2):
    return sum(np.exp(-(d / s) ** 2) for d in ds)


h, r = 11, 27            # stroke half-width, m arch radius
cy, base = h + r, 100 - h
m = [seg(h, cy, h, base)]
for c in (h + r, h + 3 * r):
    m += [arch(c, cy, r), seg(c + r, cy, c + r, base)]
lx = h + 4 * r + h + 16 + h
y = [seg(lx, h, lx + 28.9, 100), seg(lx + 62, h, lx + 14, 140)]
R = 46
o = blob(lx + 62 + h + 3 + R, 100 - R, R - h)

letters = field(m + y)
ball = field([o])
alpha = (letters + ball) > 0.5
rgb = np.where((ball > letters)[..., None], AMBER, INK)

rows, cols = np.where(alpha)
sl = (slice(rows.min() - 4, rows.max() + 5), slice(cols.min() - 4, cols.max() + 5))
img = np.dstack([rgb[sl], alpha[sl] * 255]).astype(np.uint8)
im = Image.fromarray(img, 'RGBA')
H = 270  # final height in px; downsampling from the hi-res field gives the antialiasing
im = im.resize((round(im.width * H / im.height), H), Image.LANCZOS)
im.save(os.path.join(HERE, 'myo-wordmark.png'))
print(im.size)
