#!/usr/bin/env python3
"""Analyse track.csv: pointer visibility runs, per-frame motion, pinning at the follow inset."""
import csv, os, sys
import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
rows = list(csv.DictReader(open(os.path.join(ROOT, 'track.csv'))))
f = np.array([int(r['frame']) for r in rows])
t = np.array([float(r['t']) for r in rows])
tx = np.array([float(r['tip_x']) for r in rows]); ty = np.array([float(r['tip_y']) for r in rows])
ts = np.array([float(r['tip_score']) for r in rows])
bx = np.array([float(r['tb_x']) for r in rows]); by = np.array([float(r['tb_y']) for r in rows])
bs = np.array([float(r['tb_score']) for r in rows])
VIS = 0.80
vis = ts >= VIS
dt = np.diff(t) * 1000

print(f'frames {len(f)}; pointer visible in {vis.sum()} ({100*vis.mean():.0f}%); toolbar score min {bs.min():.2f} median {np.median(bs):.2f}')
print('\n== Pointer-missing runs (score < %.2f) ==' % VIS)
runs = []
i = 0
while i < len(f):
    if not vis[i]:
        j = i
        while j + 1 < len(f) and not vis[j + 1]: j += 1
        dur = (t[min(j + 1, len(t) - 1)] - t[i]) * 1000
        runs.append((f[i], f[j], j - i + 1, dur))
        i = j + 1
    else:
        i += 1
for a, b, n, dur in runs:
    print(f'  frames {a}-{b}: {n} frames, {dur:.0f} ms  (t={t[a-1]:.2f}s)  last tip before: ({tx[a-2]:.0f},{ty[a-2]:.0f}) score {ts[a-2]:.2f}; first after: ({tx[b]:.0f},{ty[b]:.0f}) score {ts[b]:.2f}' if a > 1 and b < len(f) else f'  frames {a}-{b}: {n} frames, {dur:.0f} ms')

# per-frame motion
dtx = np.diff(tx); dty = np.diff(ty); dbx = np.diff(bx); dby = np.diff(by)
both = vis[1:] & vis[:-1]
step = np.hypot(dtx, dty)
print('\n== On-screen pointer step per frame (px, only where visible both frames) ==')
s = step[both]
print(f'  n={len(s)} median {np.median(s):.1f} p90 {np.percentile(s,90):.1f} max {s.max():.1f}')
print(f'  frames with step > 40 px: {int((s>40).sum())}; step > 80 px: {int((s>80).sum())}')
print('\n== Picture (toolbar) motion per frame ==')
pm = np.hypot(dbx, dby)
print(f'  frames with picture moving >1 px: {int((pm>1).sum())} of {len(pm)}; median when moving {np.median(pm[pm>1]):.1f} px; max {pm.max():.1f} px')

# inset lines (recording px): 32 pt margin * 3 px/pt from each side of the usable rect; assume zero horizontal safe insets
LEFT, RIGHT = 96, 1206 - 96
print('\n== Frames where the picture moves: is the pointer pinned near an inset line? ==')
near = ((np.abs(tx - LEFT) < 30) | (np.abs(tx - RIGHT) < 30))
moving = np.concatenate([[False], pm > 1])
print(f'  picture moving frames: {int(moving.sum())}; of those, pointer within 30 px of an inset line: {int((moving & near & vis).sum())}')

print('\n== Per-frame table (frame, t, dt ms, tip x/y, step, score, picture dx, pointer-in-picture dx) ==')
rel = tx - bx
for k in range(len(f)):
    d = dt[k-1] if k > 0 else 0
    st = step[k-1] if k > 0 else 0
    pdx = dbx[k-1] if k > 0 else 0
    rdx = rel[k] - rel[k-1] if k > 0 else 0
    flag = ''
    if not vis[k]: flag += ' MISSING'
    if k > 0 and vis[k] and vis[k-1] and st > 40: flag += ' JUMP'
    if abs(pdx) > 1: flag += ' PAN'
    if d > 25: flag += f' REC-GAP({d:.0f})'
    if vis[k] and near[k]: flag += ' @INSET'
    print(f'{f[k]:4d} {t[k]:6.3f} {d:5.1f}  tip ({tx[k]:5.0f},{ty[k]:5.0f}) step {st:5.1f} s={ts[k]:.2f}  pic dx {pdx:6.1f}  rel dx {rdx:6.1f}{flag}')
