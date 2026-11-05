"""Greyscale check: luma mean, contrast (std dev) and grain density for
calm vs pumped screenshots, on background-only regions (no orb, no UI)."""
import sys
from PIL import Image, ImageFilter, ImageStat, ImageChops

def stats(path, out):
    im = Image.open(path).convert("RGB")
    g = im.convert("L")  # ITU-R 601 luma
    g.save(out)
    w, h = g.size
    # Background-only patches: left/right margins beside the orb, and the
    # band just above the controls.
    boxes = [(int(w*0.03), int(h*0.18), int(w*0.18), int(h*0.62)),
             (int(w*0.82), int(h*0.18), int(w*0.97), int(h*0.62))]
    full = ImageStat.Stat(g)
    res = {"mean_all": full.mean[0], "std_all": full.stddev[0]}
    means, stds, dens = [], [], []
    for b in boxes:
        c = g.crop(b)
        s = ImageStat.Stat(c)
        means.append(s.mean[0]); stds.append(s.stddev[0])
        blur = c.filter(ImageFilter.MedianFilter(5))
        diff = ImageChops.difference(c, blur)
        hist = diff.histogram()
        n = sum(hist)
        dens.append(sum(hist[6:]) / n)  # pixels ≥6/255 off their neighbourhood
    res["margin_mean"] = sum(means)/len(means)
    res["margin_grain_density"] = sum(dens)/len(dens)
    # Edge-to-centre luminance spread: centre column above the orb vs corners.
    top_c = ImageStat.Stat(g.crop((int(w*0.4), int(h*0.13), int(w*0.6), int(h*0.17)))).mean[0]
    corner = ImageStat.Stat(g.crop((0, int(h*0.88), int(w*0.12), int(h*0.98)))).mean[0]
    res["centre_minus_corner"] = top_c - corner
    return res

for path in sys.argv[1:]:
    r = stats(path, path.replace(".png", "-grey.png"))
    print(path.split("/")[-1], {k: round(v, 3) for k, v in r.items()})
