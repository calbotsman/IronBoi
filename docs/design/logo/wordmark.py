"""MYO wordmark with the mark's gesture: a small ink drop being absorbed
into the O, joined by the same soft liquid bridge (blur-threshold metaball,
applied only around the drop so the letters stay crisp)."""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'wordmark-letters.svg')
INK = np.array([26, 20, 16]); CREAM = np.array([252, 244, 232])

def letters_mask(h=360):
    os.system(f'rsvg-convert -h 1400 "{SRC}" -o /private/tmp/claude-501/wm-raw.png')
    g = Image.open('/private/tmp/claude-501/wm-raw.png').convert('L')
    m = g.point(lambda v: 255 if v < 110 else (0 if v > 170 else int((170 - v) / 60 * 255)))
    m = m.crop(m.getbbox())
    return m.resize((int(m.width * h / m.height), h), Image.LANCZOS)

def build(name, drop_r, gap, angle_deg, bridge=True):
    L = letters_mask()
    pad = 120
    W, H = L.width + pad * 2 + 140, L.height + pad * 2
    base = Image.new('L', (W, H), 0); base.paste(L, (pad, pad))
    a = np.array(base, dtype=np.float64) / 255
    # O: rightmost letter, assume circular — centre/radius from the mask's right third
    cols = np.where(a.max(axis=0) > 0.5)[0]; rows = np.where(a.max(axis=1) > 0.5)[0]
    right = cols.max(); top, bot = rows.min(), rows.max()
    r_o = (bot - top) / 2; cx, cy = right - r_o, (top + bot) / 2
    t = np.radians(angle_deg)
    dist = r_o + gap + drop_r
    dx, dy = cx + dist * np.cos(t), cy + dist * np.sin(t)
    drop = Image.new('L', (W, H), 0)
    ImageDraw.Draw(drop).ellipse((dx - drop_r, dy - drop_r, dx + drop_r, dy + drop_r), fill=255)
    d = np.array(drop, dtype=np.float64) / 255
    out = np.maximum(a, d)
    if bridge:
        blob = Image.fromarray((np.clip(a + d, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(drop_r * 0.9))
        b = np.array(blob, dtype=np.float64) / 255
        meta = np.clip((b - 0.40) / 0.02, 0, 1)
        yy, xx = np.mgrid[0:H, 0:W]
        near = (np.hypot(xx - dx, yy - dy) < drop_r + gap + drop_r * 0.8).astype(np.float64)
        out = np.maximum(out, meta * near)
    img = CREAM[None, None, :] * (1 - out[..., None]) + INK[None, None, :] * out[..., None]
    Image.fromarray(img.astype(np.uint8)).save(os.path.join(HERE, f'{name}.png'))

build('word-drop-away', drop_r=22, gap=40, angle_deg=35, bridge=False)
build('word-drop-near', drop_r=24, gap=16, angle_deg=-40)
build('word-drop-merging', drop_r=26, gap=6, angle_deg=-45)
print('ok')
