#!/usr/bin/env python3
"""Per-frame pointer tip and picture-origin tracker for a phone screen recording.

Written for ~/Downloads/"ScreenRecording_09-29-2026 07-40-54_1.MP4" (iPhone 17, 1206x2622,
464 variable-rate frames). Needs only ffmpeg/ffprobe on PATH and numpy + Pillow. Prepare the
inputs next to this script, then run it and analyze.py:

  ffmpeg -i "$REC" -fps_mode passthrough -q:v 2 frames/f%04d.jpg
  ffprobe -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 "$REC" \
      | tr -d , > pts.txt
  python3 -c "import numpy as np; np.save('pts.npy', np.loadtxt('pts.txt'))"
  nice -n 10 python3 track.py && python3 analyze.py

Uses masked normalized cross-correlation (numpy FFT, float64 with a variance floor so flat
regions cannot produce false matches) for two templates:
  * the phone-drawn arrow glyph (tip position per frame; score < 0.8 means not on screen)
  * the Finder toolbar view-button cluster (a static Mac feature = picture position per frame)
The template crops (frame 161) and the picture band (y 700-1830) are specific to that
recording; adjust the constants below for another one. Writes track.csv, one row per frame.
"""
import csv, sys, os
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
FRAMES = os.path.join(ROOT, 'frames')
Y0, Y1 = 700, 1830          # Mac picture band in the recording (original px)
N = 464

pts = np.load(os.path.join(ROOT, 'pts.npy'))

def load(i):
    im = Image.open(os.path.join(FRAMES, f'f{i:04d}.jpg')).convert('L')
    return np.asarray(im, dtype=np.float64)

def dilate(mask, r):
    out = mask.copy()
    h, w = mask.shape
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy > r * r: continue
            sh = np.zeros_like(mask)
            ys, ye = max(0, dy), min(h, h + dy)
            xs, xe = max(0, dx), min(w, w + dx)
            sh[ys:ye, xs:xe] = mask[ys - dy:ye - dy, xs - dx:xe - dx]
            out |= sh
    return out

class Matcher:
    def __init__(self, tmpl, mask):
        self.tmpl = tmpl.astype(np.float64); self.mask = mask.astype(np.float64)
        self.n = self.mask.sum()
        tm = (self.tmpl * self.mask).sum() / self.n
        self.tz = (self.tmpl - tm) * self.mask
        self.tnorm = np.sqrt((self.tz ** 2).sum())
        self.h, self.w = tmpl.shape
        self._cache = {}

    def _k(self, shape, key, arr):
        c = self._cache.get((shape, key))
        if c is None:
            c = np.conj(np.fft.rfft2(arr, s=shape))
            self._cache[(shape, key)] = c
        return c

    def score(self, img):
        H, W = img.shape
        shape = (H + self.h, W + self.w)
        F = np.fft.rfft2(img, s=shape)
        F2 = np.fft.rfft2(img * img, s=shape)
        SI = np.fft.irfft2(F * self._k(shape, 'mask', self.mask), s=shape)[:H - self.h + 1, :W - self.w + 1]
        SI2 = np.fft.irfft2(F2 * self._k(shape, 'mask', self.mask), s=shape)[:H - self.h + 1, :W - self.w + 1]
        SIT = np.fft.irfft2(F * self._k(shape, 'tz', self.tz), s=shape)[:H - self.h + 1, :W - self.w + 1]
        var = np.maximum(SI2 - SI * SI / self.n, self.n * 16.0)  # std floor of 4 grey levels defeats FFT round-off in flat regions
        ncc = SIT / (np.sqrt(var) * self.tnorm)
        return ncc

    def best(self, img):
        ncc = self.score(img)
        idx = np.argmax(ncc)
        y, x = np.unravel_index(idx, ncc.shape)
        return int(x), int(y), float(ncc[y, x])

# --- templates from frame 161 ---------------------------------------------------------
ref = load(161)
# Arrow: crop around the pointer; mask = dark body dilated to include the white outline.
ax0, ay0, ax1, ay1 = 905, 1085, 1005, 1210
arrow = ref[ay0:ay1, ax0:ax1]
dark = arrow < 70
mask = dilate(dark, 6)
ys, xs = np.nonzero(dark)
tip_dy, tip_dx = int(ys.min()), int(xs[ys == ys.min()].min())
print(f'arrow template {arrow.shape}, mask px {int(mask.sum())}, tip offset ({tip_dx},{tip_dy})')
arrow_m = Matcher(arrow, mask)

# Toolbar view buttons cluster (static Mac feature). Full-mask NCC.
tx0, ty0, tx1, ty1 = 290, 915, 480, 950
toolbar = ref[ty0:ty1, tx0:tx1]
toolbar_m = Matcher(toolbar, np.ones_like(toolbar, dtype=bool))
print(f'toolbar template {toolbar.shape}; in frame 161 at ({tx0},{ty0})')

rows = []
for i in range(1, N + 1):
    img = load(i)
    band = img[Y0:Y1]
    px, py, ps = arrow_m.best(band)
    tipx, tipy = px + tip_dx, py + tip_dy + Y0
    # toolbar can be anywhere in the picture band; search full width, y band around picture
    tx, ty, ts = toolbar_m.best(band)
    ty += Y0
    rows.append((i, pts[i - 1], tipx, tipy, ps, tx, ty, ts))
    if i % 50 == 0:
        print(f'frame {i}: tip ({tipx},{tipy}) s={ps:.2f}  toolbar ({tx},{ty}) s={ts:.2f}', flush=True)

with open(os.path.join(ROOT, 'track.csv'), 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['frame', 't', 'tip_x', 'tip_y', 'tip_score', 'tb_x', 'tb_y', 'tb_score'])
    w.writerows(rows)
print('wrote track.csv')
