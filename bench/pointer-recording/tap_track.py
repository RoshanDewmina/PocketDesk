#!/usr/bin/env python3
"""Per-frame comparison of the Mac's real cursor and the phone glyph around a tap.

Both screens carry the same bench page with one bright green button. The phone is hand-held and
moves in the frame, so everything is measured relative to the green button seen on each screen:
  * Mac button: bright green blob inside the MacBook region (fixed camera; x > 1400).
  * Phone button: bright green blob elsewhere in the frame.
The phone glyph (black arrow, white outline) is matched with a masked-NCC template within a window
around the phone's button; the click ripple's ember dot (orange) near the phone's button and the
bench page's red flash on the Mac mark the click on each screen.
Usage: tap_track.py DIR OUT.csv [--tmpl frame,x0,y0,x1,y1] [--strip every N]
Frame period: 1/240 s real (29.97 fps playback of 240 fps capture, 8x slow motion).
"""
import csv, os, sys
import numpy as np
from PIL import Image, ImageDraw

MAC_REGION = (1400, 350, 1920, 900)

def erode(mask, r):
    out = mask.copy(); h, w = mask.shape
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            sh = np.zeros_like(mask)
            ys, ye = max(0, dy), min(h, h + dy); xs, xe = max(0, dx), min(w, w + dx)
            sh[ys:ye, xs:xe] = mask[ys - dy:ye - dy, xs - dx:xe - dx]
            out &= sh
    return out

def blobs(rgb):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    green = (g > 170) & (r < 190) & (b < 190) & (g > r + 60) & (g > b + 60)
    # Solid buttons survive a small erosion; the editor's thin green text does not.
    green = erode(green, 2)
    orange = (r > 190) & (g > 90) & (g < 190) & (b < 90)
    red = (r > 170) & (g < 90) & (b < 90)
    return green, orange, red

def dark_blob(rgb, box, inset=12):
    """Centroid and size of the Mac's real cursor over the green button: the camera renders the
    black arrow as mid grey with little green excess, unlike the button (bright, green-dominant)
    and its white label (bright)."""
    x0, y0, x1, y1 = box
    sub = rgb[y0 + inset:y1 - inset, x0 + inset:x1 - inset]
    if sub.size == 0: return None
    r, g, b = sub[..., 0], sub[..., 1], sub[..., 2]
    m = (g < 150) & (g - r < 50)
    ys, xs = np.nonzero(m)
    if len(xs) < 3: return None
    return (x0 + inset + float(xs.mean()), y0 + inset + float(ys.mean()), int(len(xs)))

def bbox(mask, region=None, exclude=None):
    m = mask.copy()
    if region:
        x0, y0, x1, y1 = region; sub = np.zeros_like(m); sub[y0:y1, x0:x1] = m[y0:y1, x0:x1]; m = sub
    if exclude:
        x0, y0, x1, y1 = exclude; m[y0:y1, x0:x1] = False
    ys, xs = np.nonzero(m)
    if len(xs) < 50: return None
    return (int(np.percentile(xs, 3)), int(np.percentile(ys, 3)), int(np.percentile(xs, 97)), int(np.percentile(ys, 97)), len(xs))

def dilate(mask, r):
    out = mask.copy(); h, w = mask.shape
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy > r * r: continue
            sh = np.zeros_like(mask)
            ys, ye = max(0, dy), min(h, h + dy); xs, xe = max(0, dx), min(w, w + dx)
            sh[ys:ye, xs:xe] = mask[ys - dy:ye - dy, xs - dx:xe - dx]
            out |= sh
    return out

class Matcher:
    def __init__(self, tmpl, mask):
        self.tmpl = tmpl.astype(np.float64); self.mask = mask.astype(np.float64)
        self.n = self.mask.sum(); tm = (self.tmpl * self.mask).sum() / self.n
        self.tz = (self.tmpl - tm) * self.mask; self.tnorm = np.sqrt((self.tz ** 2).sum())
        self.h, self.w = tmpl.shape; self._k = {}
    def kern(self, shape, key, arr):
        c = self._k.get((shape, key))
        if c is None: c = np.conj(np.fft.rfft2(arr, s=shape)); self._k[(shape, key)] = c
        return c
    def best(self, img):
        H, W = img.shape
        if H < self.h or W < self.w: return 0, 0, -1.0
        shape = (H + self.h, W + self.w)
        F = np.fft.rfft2(img, s=shape); F2 = np.fft.rfft2(img * img, s=shape)
        SI = np.fft.irfft2(F * self.kern(shape, 'm', self.mask), s=shape)[:H - self.h + 1, :W - self.w + 1]
        SI2 = np.fft.irfft2(F2 * self.kern(shape, 'm', self.mask), s=shape)[:H - self.h + 1, :W - self.w + 1]
        SIT = np.fft.irfft2(F * self.kern(shape, 't', self.tz), s=shape)[:H - self.h + 1, :W - self.w + 1]
        var = np.maximum(SI2 - SI * SI / self.n, self.n * 16.0)
        ncc = SIT / (np.sqrt(var) * self.tnorm)
        y, x = np.unravel_index(np.argmax(ncc), ncc.shape)
        return int(x), int(y), float(ncc[y, x])

def main(d, out, args):
    names = sorted(f for f in os.listdir(d) if f.endswith('.jpg'))
    tmpl_spec = args[args.index('--tmpl') + 1] if '--tmpl' in args else None
    tmpl_dir = args[args.index('--tmpl-dir') + 1] if '--tmpl-dir' in args else d
    if '--auto-tmpl' in args:
        # Find the glyph's white outline near (but outside) the phone's green button in this frame.
        fi = int(args[args.index('--auto-tmpl') + 1])
        im = Image.open(os.path.join(d, f'f{fi:05d}.jpg')); rgb = np.asarray(im, dtype=np.int16)
        green, orange, _ = blobs(rgb); ph = bbox(green, exclude=MAC_REGION)
        bx0, by0, bx1, by1, _ = ph; bw = bx1 - bx0; bh = by1 - by0
        # The ember contact dot marks the glyph tip at the click; the glyph is the compact white
        # outline right next to it (the button's own label is excluded by masking the button).
        ow = orange.copy(); ow[:, :max(0, bx0 - 2 * bw)] = False; ow[:, bx1 + 2 * bw:] = False
        ow[:max(0, by0 - 2 * bh), :] = False; ow[by1 + 2 * bh:, :] = False
        oys, oxs = np.nonzero(ow)
        cx, cy = (float(oxs.mean()), float(oys.mean())) if len(oxs) else ((bx0 + bx1) / 2, (by0 + by1) / 2)
        white = rgb.min(axis=2) > 165
        win = np.zeros_like(white)
        win[max(0, int(cy - 0.6 * bh)):int(cy + 1.0 * bh), max(0, int(cx - 0.6 * bw)):int(cx + 1.0 * bw)] = True
        win[by0 + 4:by1 - 4, bx0 + 4:bx1 - 4] = False
        white &= win
        ys, xs = np.nonzero(white)
        print('ember dot at', (round(cx), round(cy)), flush=True)
        x0, x1 = int(xs.min()) - 4, int(xs.max()) + 5; y0, y1 = int(ys.min()) - 4, int(ys.max()) + 5
        tmpl_spec = f'{fi},{x0},{y0},{x1},{y1}'
        print('auto template', tmpl_spec, 'button', (bx0, by0, bw, bh), 'white px', len(xs), flush=True)
    every = int(args[args.index('--strip') + 1]) if '--strip' in args else 0
    matcher = tip = None
    if tmpl_spec:
        fi, x0, y0, x1, y1 = [int(v) for v in tmpl_spec.split(',')]
        refim = Image.open(os.path.join(tmpl_dir, f'f{fi:05d}.jpg'))
        ref = np.asarray(refim.convert('L'), dtype=np.float64)
        refrgb = np.asarray(refim, dtype=np.int16)[y0:y1, x0:x1]
        # The glyph's white outline is the only feature the camera separates from the phone's dark
        # screen (body ~55-70 vs screen ~75); mask = outline dilated so it includes the body inside.
        # White means every channel high, which keeps the green button out of the mask.
        t = ref[y0:y1, x0:x1]; bright = refrgb.min(axis=2) > 165; m = dilate(bright, 3)
        ys, xs = np.nonzero(bright); tip = (int(xs[ys == ys.min()].min()), int(ys.min()))
        matcher = Matcher(t, m); print('template', t.shape, 'mask', int(m.sum()), 'tip', tip, flush=True)
    strip = []
    with open(out, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['frame', 'mac_bx', 'mac_by', 'mac_bw', 'mac_bh', 'red_px', 'cur_px', 'cur_rel_x', 'cur_rel_y',
                    'ph_bx', 'ph_by', 'ph_bw', 'ph_bh',
                    'orange_px', 'glyph_x', 'glyph_y', 'glyph_s', 'glyph_rel_x', 'glyph_rel_y'])
        for i, name in enumerate(names):
            im = Image.open(os.path.join(d, name)); rgb = np.asarray(im, dtype=np.int16)
            green, orange, red = blobs(rgb)
            mac = bbox(green, region=MAC_REGION)
            ph = bbox(green, exclude=MAC_REGION)
            redpx = int(red[MAC_REGION[1]:MAC_REGION[3], MAC_REGION[0]:MAC_REGION[2]].sum())
            row = [int(name[1:6])]
            row += [mac[0], mac[1], mac[2] - mac[0], mac[3] - mac[1]] if mac else [-1, -1, -1, -1]
            row += [redpx]
            cur = dark_blob(rgb, mac[:4]) if mac else None
            if cur and mac:
                mw = max(1, mac[2] - mac[0]); mh = max(1, mac[3] - mac[1])
                row += [cur[2], round((cur[0] - (mac[0] + mw / 2)) / mw, 3), round((cur[1] - (mac[1] + mh / 2)) / mh, 3)]
            else:
                row += [0, 0.0, 0.0]
            gx = gy = gs = -1; relx = rely = 0.0; opx = 0
            if ph:
                bx0, by0, bx1, by1, _ = ph
                bw = max(1, bx1 - bx0); bh = max(1, by1 - by0)
                row += [bx0, by0, bw, bh]
                wx0, wy0 = max(0, bx0 - 3 * bw), max(0, by0 - 3 * bh)
                wx1, wy1 = min(rgb.shape[1], bx1 + 3 * bw), min(rgb.shape[0], by1 + 3 * bh)
                opx = int(orange[wy0:wy1, wx0:wx1].sum())
                if matcher:
                    g = np.asarray(im.convert('L'), dtype=np.float64)[wy0:wy1, wx0:wx1]
                    x, y, s = matcher.best(g)
                    gx, gy, gs = wx0 + x + tip[0], wy0 + y + tip[1], s
                    relx = (gx - (bx0 + bw / 2)) / bw; rely = (gy - (by0 + bh / 2)) / bh
            else:
                row += [-1, -1, -1, -1]
            row += [opx, gx, gy, round(gs, 3), round(relx, 3), round(rely, 3)]
            w.writerow(row)
            if every and i % every == 0 and ph:
                bx0, by0, bx1, by1, _ = ph
                cx, cy = (bx0 + bx1) // 2, (by0 + by1) // 2
                tile = im.crop((cx - 150, cy - 110, cx + 150, cy + 110)).resize((300, 220))
                dd = ImageDraw.Draw(tile); dd.text((4, 4), f'{name[1:6]} r{redpx} o{opx} s{gs:.2f}', fill=(255, 80, 80))
                if mac:
                    mx0, my0, mx1, my1, _ = mac
                    mtile = im.crop((mx0 - 40, my0 - 40, mx1 + 40, my1 + 40)).resize((300, 220))
                    both = Image.new('RGB', (300, 440)); both.paste(tile, (0, 0)); both.paste(mtile, (0, 220))
                    strip.append(both)
            if i % 100 == 0: print(name, 'mac', mac and mac[:4], 'phone', ph and ph[:4], 'glyph', (gx, gy, round(gs, 2)), flush=True)
    if strip:
        cols = 12; rows = (len(strip) + cols - 1) // cols
        sheet = Image.new('RGB', (cols * 300, rows * 440))
        for k, t in enumerate(strip): sheet.paste(t, ((k % cols) * 300, (k // cols) * 440))
        sheet.save(out.replace('.csv', '-strip.jpg'), quality=85); print('strip', sheet.size)
    print('wrote', out)

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
