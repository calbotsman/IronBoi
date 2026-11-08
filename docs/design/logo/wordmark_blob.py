"""MYO wordmark: lowercase "myo" drawn as one metaball field and shaded with the
One Body orb's own look (pale centre, soft edge, amber halo, film grain, as in
render_merge.py / OneBody.metal).

Strokes are skeleton lines; each adds a Gaussian falloff and the word is
wherever the summed field passes 0.5, so strokes swell where they meet. The o
is a soft blob sitting on the baseline. Output is transparent, glow included.

Units: x-height 100, baseline at y=100. Needs numpy, scipy, pillow.
python wordmark_blob.py  ->  myo-wordmark.png
"""
import os
import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt as edt

HERE = os.path.dirname(os.path.abspath(__file__))
AMBER = np.array([0xF6, 0xA6, 0x09]) / 255
S = 8  # samples per unit
PAD = 40  # room for the halo
xs = np.arange(-PAD, 340 + PAD, 1 / S); ys = np.arange(-PAD, 151 + PAD, 1 / S)
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


h, r, R = 11, 27, 46     # stroke half-width, m arch radius, o radius
cy, base = h + r, 100 - h
m = [seg(h, cy, h, base)]
for c in (h + r, h + 3 * r):
    m += [arch(c, cy, r), seg(c + r, cy, c + r, base)]
lx = h + 4 * r + h + 16 + h
y = [seg(lx, h, lx + 28.9, 100), seg(lx + 62, h, lx + 14, 140)]
o = blob(lx + 62 + h + 3 + R, 100 - R, R - h)

L = field(m, 11.8) + field(y)   # the m a little tighter so its top doesn't swell
B = field([o])
inside = (L + B) > 0.5
d = (edt(~inside) - edt(inside)) / S          # signed distance, <0 inside
share = B / (B + L + 1e-12)                   # 1 in the o, 0 in the letters

# orb shading (render_merge.py, scaled to these units)
depth = R * share + h * (1 - share)
u = np.clip((d + depth) / depth, 0, 1)
pale = (1 - u * u * (3 - 2 * u)) * (0.38 * share + 0.22 * (1 - share))
c = AMBER * (1 - pale[..., None]) + pale[..., None]
c = np.clip(c + (np.random.default_rng(7).random(d.shape) - 0.5)[..., None] * 0.045, 0, 1)
soft, glow = 1.8, 13
t = np.clip((d + soft) / (2 * soft), 0, 1)
fill = (1 - t * t * (3 - 2 * t)) * 0.93
halo = np.exp(-np.maximum(d, 0) / glow) * 0.3 * (1 - fill)

# same result as the shader over cream, but kept transparent
alpha = 1 - (1 - fill) * (1 - halo)
premul = c * (fill * (1 - halo))[..., None] + AMBER * halo[..., None]
rgb = premul / np.maximum(alpha, 1e-6)[..., None]

rows, cols = np.where(alpha > 0.01)
sl = (slice(rows.min(), rows.max() + 1), slice(cols.min(), cols.max() + 1))
img = np.dstack([rgb[sl], alpha[sl]])
im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), 'RGBA')
H = 300  # final height in px; downsampling from the hi-res field gives the antialiasing
letters_h = (inside[sl].any(axis=1)).sum() / im.height
im = im.resize((round(im.width * H / im.height), H), Image.LANCZOS)
im.save(os.path.join(HERE, 'myo-wordmark.png'))
print(im.size, 'letters fill %.2f of the height' % letters_h)
