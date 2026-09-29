#!/usr/bin/env python3
"""Measure content-motion cadence in phone recordings without claiming physical latency.

Usage: analyze.py LABEL=recording.mp4 [...] [--start=2] [--dur=25]

The source-frame columns describe the recording's own timestamp cadence. The motion columns are
frames retained by ffmpeg ``mpdecimate`` and therefore describe distinct screen content only in a
known moving-stimulus window. They are not decoded/presented app FPS and cannot exceed the
recording cadence. Camera calibration and physical glass-to-glass latency are outside this tool.
"""
from __future__ import annotations

import json
import math
import pathlib
import re
import statistics
import subprocess
import sys


def run(command):
    return subprocess.run(command, capture_output=True, text=True, check=False)


def source_times(path, start, duration):
    interval = f"{start}%+{duration}"
    command = ["ffprobe", "-v", "error", "-select_streams", "v:0",
               "-read_intervals", interval,
               "-show_entries", "frame=best_effort_timestamp_time",
               "-of", "json", path]
    result = run(command)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "ffprobe failed")
    payload = json.loads(result.stdout)
    values = []
    for frame in payload.get("frames", []):
        try:
            value = float(frame["best_effort_timestamp_time"])
        except (KeyError, TypeError, ValueError):
            continue
        # ffprobe seeks to an earlier keyframe for read_intervals. Trim to the requested window
        # explicitly so source cadence and the ffmpeg mpdecimate window cover the same seconds.
        if math.isfinite(value) and start <= value < start + duration:
            values.append(value)
    return values


def distinct_times(path, start, duration):
    command = ["ffmpeg", "-hide_banner", "-ss", str(start), "-t", str(duration), "-i", path,
               "-vf", "scale=654:-1,mpdecimate=hi=64*12:lo=64*5:frac=0.33,showinfo",
               "-f", "null", "-"]
    result = run(command)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "ffmpeg failed")
    return [float(value) for value in re.findall(r"pts_time:([-+]?[0-9]*\.?[0-9]+)", result.stderr)]


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))]


def cadence_stats(timestamps):
    """Summarize media PTS, rejecting duplicate or reversed timestamps."""
    candidates = [value for value in timestamps
                  if isinstance(value, (int, float)) and math.isfinite(value)]
    if any(right <= left for left, right in zip(candidates, candidates[1:])):
        raise ValueError("media PTS are not strictly increasing")
    valid = candidates
    gaps = [(right - left) * 1000 for left, right in zip(valid, valid[1:])]
    if len(gaps) < 5:
        return None
    span = valid[-1] - valid[0]
    if span <= 0:
        return None
    return {
        "fps": (len(valid) - 1) / span,
        "median": statistics.median(gaps),
        "p90": percentile(gaps, 0.90),
        "p99": percentile(gaps, 0.99),
        "stalls": sum(gap > 100 for gap in gaps),
        "n": len(gaps),
    }


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    start = next((float(arg.split("=", 1)[1]) for arg in argv if arg.startswith("--start=")), 2)
    duration = next((float(arg.split("=", 1)[1]) for arg in argv if arg.startswith("--dur=")), 25)
    if not math.isfinite(start) or start < 0 or not math.isfinite(duration) or duration <= 0:
        print("error: --start must be finite and nonnegative; --dur must be finite and positive", file=sys.stderr)
        return 2
    specs = [arg for arg in argv if not arg.startswith("--")]
    if not specs:
        print(__doc__)
        return 2
    real_paths = {}
    for spec in specs:
        label, separator, candidate = spec.partition("=")
        path = candidate if separator else label
        try:
            identity = str(pathlib.Path(path).expanduser().resolve())
        except OSError:
            identity = path
        if identity in real_paths:
            print(f"error: labels {real_paths[identity]!r} and {label!r} refer to the same recording; "
                  "refusing an accidental A/B or camera pairing", file=sys.stderr)
            return 2
        real_paths[identity] = label
    rows = []
    for spec in specs:
        label, separator, candidate = spec.partition("=")
        path = candidate if separator else label
        try:
            source = cadence_stats(source_times(path, start, duration))
            motion = cadence_stats(distinct_times(path, start, duration))
            error = None
        except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
            source = motion = None
            error = str(exc)
        rows.append((label, source, motion, error))

    print(f"{'recording':24} {'rec fps':>7} {'rec p90':>8} {'motion/s':>9} "
          f"{'motion p90':>11} {'p99':>7} {'stalls>100':>11}")
    for label, source, motion, error in rows:
        if error:
            print(f"{label:24} error: {error}")
        elif source is None:
            print(f"{label:24} not enough source frames")
        elif motion is None:
            print(f"{label:24} {source['fps']:7.1f} {source['p90']:7.1f}ms  not enough motion")
        else:
            print(f"{label:24} {source['fps']:7.1f} {source['p90']:7.1f}ms "
                  f"{motion['fps']:9.1f} {motion['p90']:10.1f}ms "
                  f"{motion['p99']:6.1f}ms {motion['stalls']:11d}")
            if motion["fps"] > source["fps"] * 1.02:
                print(f"  warning: motion cadence exceeds recording cadence; inspect PTS/window pairing")
    print("motion cadence is recording-limited content evidence; physical latency needs camera calibration")
    return 2 if any(error or source is None for _, source, _, error in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main())
