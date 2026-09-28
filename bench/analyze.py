#!/usr/bin/env python3
"""Usage: analyze.py LABEL=recording.mp4 [LABEL=recording.mp4 ...]
Measures distinct on-screen updates in phone screen recordings (60 fps) using ffmpeg mpdecimate."""
import subprocess, sys, re, statistics

def distinct_times(path, start, dur):
    cmd = ["ffmpeg", "-hide_banner", "-ss", str(start), "-t", str(dur), "-i", path,
           "-vf", "scale=654:-1,mpdecimate=hi=64*12:lo=64*5:frac=0.33,showinfo", "-f", "null", "-"]
    out = subprocess.run(cmd, capture_output=True, text=True).stderr
    return [float(x) for x in re.findall(r"pts_time:([0-9.]+)", out)]

def stats(ts):
    gaps = [(b - a) * 1000 for a, b in zip(ts, ts[1:])]
    gaps = [g for g in gaps if g < 1000]
    if len(gaps) < 5:
        return None
    gaps.sort()
    span = ts[-1] - ts[0]
    return dict(fps=len(ts) / span if span else 0, median=statistics.median(gaps),
                p90=gaps[int(len(gaps) * .9)], p99=gaps[min(len(gaps) - 1, int(len(gaps) * .99))],
                stalls=sum(g > 100 for g in gaps), n=len(gaps))

args = sys.argv[1:]
start, dur = 2, 25
rows = []
for a in args:
    if a.startswith("--start="): start = float(a.split("=")[1]); continue
    if a.startswith("--dur="): dur = float(a.split("=")[1]); continue
    label, _, path = a.partition("=")
    s = stats(distinct_times(path or label, start, dur))
    rows.append((label, s))
print(f"{'app':24} {'upd/s':>6} {'median':>7} {'p90':>6} {'p99':>6} {'stalls>100ms':>13}")
for label, s in rows:
    if s is None: print(f"{label:24} not enough motion"); continue
    print(f"{label:24} {s['fps']:6.1f} {s['median']:6.0f}ms {s['p90']:5.0f}ms {s['p99']:5.0f}ms {s['stalls']:13d}")
