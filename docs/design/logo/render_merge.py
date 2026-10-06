"""Render the MYO mark with the app's own One Body math.

A Python port of ios/.../Features/Coach/Orb/OneBody.metal: the body is a
signed-distance circle, droplets blend in with a smooth-min (`fuse`), the
colour is mixed by each shape's share of the blend, then the pale centre,
soft edge, halo and film grain are applied over cream paper exactly as the
shader does. Change the scenes at the bottom and rerun.

    python render_merge.py   # writes merge-*.png next to this file
"""
import math
import os

import numpy as np
from PIL import Image

CREAM = np.array([0xFC, 0xF4, 0xE8]) / 255
AMBER = np.array([0xF6, 0xA6, 0x09]) / 255
BLUE = np.array([0x42, 0x85, 0xF4]) / 255


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)


def wobble(x, y, seed):
    """Low-frequency stand-in for the shader's simplex noise."""
    a = np.arctan2(y, x)
    return (0.5 * np.sin(3 * a + seed) + 0.3 * np.sin(5 * a - 1.7 * seed) + 0.2 * np.sin(2 * a + 2.3 * seed))


def render(size, body, drops, drop_color=AMBER, fuse=0.16, soft=0.02, glow=0.14,
           grain=0.045, squash=1.0, seed=1.3, ss=2):
    """body: (cx, cy, r); drops: [(x, y, r)] in the shader's space (short
    side spans -1..1, y up). Rendered at `ss`x and downsampled."""
    n = size * ss
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float64)
    px = (xs + 0.5) / n * 2 - 1
    py = -((ys + 0.5) / n * 2 - 1)

    cx, cy, r = body
    qx, qy = px - cx, (py - cy) / squash
    d = np.hypot(qx, qy) - r * (1 + 0.035 * wobble(qx, qy, seed))

    you = np.zeros_like(d)
    for dx, dy, dr in drops:
        dd = np.hypot(px - dx, py - dy) - dr
        h = np.clip(0.5 + 0.5 * (dd - d) / fuse, 0, 1)
        you = np.maximum(you, 1 - h)
        d = smin(d, dd, fuse)

    c = AMBER[None, None, :] * (1 - you[..., None]) + drop_color[None, None, :] * you[..., None]
    pale = (1 - np.clip((d + r) / r, 0, 1) ** 2 * (3 - 2 * np.clip((d + r) / r, 0, 1))) * 0.38
    c = c * (1 - pale[..., None]) + pale[..., None]

    t = np.clip((d + soft) / (2 * soft), 0, 1)
    fill = 1 - t * t * (3 - 2 * t)
    halo = np.exp(-np.maximum(d, 0) / glow) * 0.3 * (1 - fill)
    alpha = fill * 0.93
    alpha = alpha + (1 - alpha) * halo

    rng = np.random.default_rng(7)
    g = (rng.random((n, n)) - 0.5) * grain
    col = CREAM[None, None, :] * (1 - alpha[..., None]) + np.clip(c + g[..., None], 0, 1) * alpha[..., None]
    img = Image.fromarray((np.clip(col, 0, 1) * 255).astype(np.uint8))
    return img.resize((size, size), Image.LANCZOS)


HERE = os.path.dirname(os.path.abspath(__file__))
SCENES = {
    # A little blob arriving, joined by a liquid bridge.
    "merge-arriving": dict(body=(-0.08, 0.04, 0.50), drops=[(0.50, -0.36, 0.16)], fuse=0.2),
    # Halfway in: the little blob is sinking into the body.
    "merge-sinking": dict(body=(-0.05, 0.03, 0.52), drops=[(0.46, -0.32, 0.18)], fuse=0.22),
    # Your words: a blue drop merging into the amber body.
    "merge-blue": dict(body=(-0.06, 0.03, 0.52), drops=[(0.46, -0.32, 0.18)], fuse=0.22, drop_color=BLUE),
    # Two drops in sequence, one almost absorbed, one arriving.
    "merge-two": dict(body=(-0.06, 0.06, 0.50), drops=[(0.44, -0.30, 0.13), (0.70, -0.62, 0.09)], fuse=0.18),
}

if __name__ == "__main__":
    for name, scene in SCENES.items():
        render(1024, **scene).save(os.path.join(HERE, f"{name}.png"))
        print("wrote", name)
