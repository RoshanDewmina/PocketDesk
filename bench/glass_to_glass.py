#!/usr/bin/env python3
"""Glass-to-glass latency from one high-speed camera clip that films the Mac and the phone together.

Usage:
  glass_to_glass.py CLIP --mac X,Y,W,H --phone X,Y,W,H [--start=S] [--dur=S] [--window-ms=400]
                    [--touch-times=touches.csv] [--json=out.json] [--csv=transitions.csv]
  glass_to_glass.py CLIP --snapshot=frame.png [--start=S]

Regions are the flash band on each screen, as fractions of the frame (all four values <= 1) or as
pixels. The Test Pad bench's auto-flash toggles the band black/white every 400-700 ms; each Mac
transition is paired with the next phone transition of the same direction inside the window.

Reports per-transition delays (ms) with p50/p95/p99/max. Frame times come from the file's own
timestamps, so a 240 fps clip resolves about +/-2.1 ms before sub-frame interpolation. With
--touch-times (one time in seconds of the clip per line, the frame where the finger lands, marked by
hand), it also reports touch -> Mac photon and touch -> phone photon for the next transitions.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
import re
import statistics
import subprocess
import sys

HYSTERESIS = 0.25


def run(command):
    return subprocess.run(command, capture_output=True, text=True, check=False)


def probe_size(path):
    result = run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                  "-show_entries", "stream=width,height", "-of", "json", str(path)])
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "ffprobe failed")
    stream = json.loads(result.stdout)["streams"][0]
    return int(stream["width"]), int(stream["height"])


def parse_region(text, width, height):
    values = [float(part) for part in text.split(",")]
    if len(values) != 4:
        raise ValueError(f"region needs X,Y,W,H: {text}")
    if all(0 <= value <= 1 for value in values):
        values = [values[0] * width, values[1] * height, values[2] * width, values[3] * height]
    x, y, w, h = (int(round(value)) for value in values)
    w, h = max(2, w), max(2, h)
    if x < 0 or y < 0 or x + w > width or y + h > height:
        raise ValueError(f"region {text} is outside the {width}x{height} frame")
    return x, y, w, h


METADATA_TIME = re.compile(r"pts_time:([0-9.eE+-]+)")
METADATA_LUMA = re.compile(r"lavfi\.signalstats\.YAVG=([0-9.eE+-]+)")


def parse_metadata(text):
    samples, time = [], None
    for line in text.splitlines():
        match = METADATA_TIME.search(line)
        if match:
            time = float(match.group(1))
            continue
        match = METADATA_LUMA.search(line)
        if match and time is not None:
            samples.append((time, float(match.group(1))))
            time = None
    return samples


def region_luma(path, region, start=None, duration=None):
    x, y, w, h = region
    command = ["ffmpeg", "-v", "error", "-nostdin"]
    if start is not None:
        command += ["-ss", str(start)]
    command += ["-i", str(path)]
    if duration is not None:
        command += ["-t", str(duration)]
    command += ["-vf", f"crop={w}:{h}:{x}:{y},signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-",
                "-an", "-f", "null", "-"]
    result = run(command)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "ffmpeg failed")
    return parse_metadata(result.stdout)


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def transitions(samples):
    """Crossings of the midpoint between the region's dark and bright levels, with hysteresis.

    Returns (time_s, rising) per transition, the time interpolated linearly between the two frames
    that straddle the midpoint.
    """
    if len(samples) < 3:
        return []
    levels = [luma for _, luma in samples]
    dark, bright = percentile(levels, 0.05), percentile(levels, 0.95)
    if bright - dark < 8:
        return []
    middle = (dark + bright) / 2
    band = (bright - dark) * HYSTERESIS
    high, low = middle + band, middle - band
    state = None
    found = []
    last_below = last_above = None
    for index, (time, luma) in enumerate(samples):
        if state is None:
            if luma >= high:
                state = True
            elif luma <= low:
                state = False
        elif not state and luma >= high:
            found.append((crossing(samples, index, middle), True))
            state = True
        elif state and luma <= low:
            found.append((crossing(samples, index, middle), False))
            state = False
    return found


def crossing(samples, index, middle):
    for back in range(index, 0, -1):
        (t0, l0), (t1, l1) = samples[back - 1], samples[back]
        if (l0 - middle) * (l1 - middle) <= 0 and l0 != l1:
            return t0 + (t1 - t0) * (middle - l0) / (l1 - l0)
    return samples[index][0]


def pair(mac, phone, window_s):
    """Each Mac transition with the first later phone transition of the same direction, before the
    next Mac transition and inside the window. Unpaired Mac transitions are counted, not guessed."""
    pairs, missing, cursor = [], 0, 0
    for position, (time, rising) in enumerate(mac):
        limit = time + window_s
        if position + 1 < len(mac):
            limit = min(limit, mac[position + 1][0])
        while cursor < len(phone) and phone[cursor][0] < time:
            cursor += 1
        match = None
        for index in range(cursor, len(phone)):
            candidate_time, candidate_rising = phone[index]
            if candidate_time > limit:
                break
            if candidate_rising == rising:
                match = index
                break
        if match is None:
            missing += 1
            continue
        pairs.append((time, phone[match][0], (phone[match][0] - time) * 1000))
        cursor = match + 1
    return pairs, missing


def summarize(values):
    if not values:
        return {"n": 0}
    return {"n": len(values), "min": min(values), "p50": percentile(values, 0.5),
            "p95": percentile(values, 0.95), "p99": percentile(values, 0.99), "max": max(values),
            "mean": statistics.fmean(values)}


def frame_interval_ms(samples):
    gaps = [(b[0] - a[0]) * 1000 for a, b in zip(samples, samples[1:]) if b[0] > a[0]]
    return statistics.median(gaps) if gaps else None


def touch_latencies(touches, mac, phone):
    rows = []
    for touch in touches:
        next_mac = next((time for time, _ in mac if time >= touch), None)
        next_phone = next((time for time, _ in phone if time >= touch), None)
        rows.append({"touch": touch,
                     "toMacMs": None if next_mac is None else (next_mac - touch) * 1000,
                     "toPhoneMs": None if next_phone is None else (next_phone - touch) * 1000})
    return rows


def read_touches(path):
    values = []
    for line in pathlib.Path(path).read_text().splitlines():
        field = line.split(",")[0].strip()
        if field and not field.startswith("#"):
            try:
                values.append(float(field))
            except ValueError:
                continue
    return values


def analyze(mac_samples, phone_samples, window_ms=400, touches=()):
    mac, phone = transitions(mac_samples), transitions(phone_samples)
    pairs, missing = pair(mac, phone, window_ms / 1000)
    delays = [delay for _, _, delay in pairs]
    interval = frame_interval_ms(mac_samples)
    result = {"frameIntervalMs": interval, "quantisationMs": None if interval is None else interval / 2,
              "macTransitions": len(mac), "phoneTransitions": len(phone), "unpaired": missing,
              "glassToGlassMs": summarize(delays),
              "pairs": [{"mac": a, "phone": b, "delayMs": d} for a, b, d in pairs]}
    if touches:
        rows = touch_latencies(touches, mac, phone)
        result["touch"] = rows
        result["touchToMacMs"] = summarize([r["toMacMs"] for r in rows if r["toMacMs"] is not None])
        result["touchToPhoneMs"] = summarize([r["toPhoneMs"] for r in rows if r["toPhoneMs"] is not None])
    return result


def describe(name, stats):
    if not stats.get("n"):
        return f"{name}: no samples"
    return (f"{name}: n {stats['n']} · p50 {stats['p50']:.1f} · p95 {stats['p95']:.1f} · "
            f"p99 {stats['p99']:.1f} · max {stats['max']:.1f} ms")


def snapshot(path, output, start):
    command = ["ffmpeg", "-v", "error", "-nostdin", "-y", "-ss", str(start or 0), "-i", str(path),
               "-frames:v", "1", str(output)]
    result = run(command)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "ffmpeg failed")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("clip")
    parser.add_argument("--mac")
    parser.add_argument("--phone")
    parser.add_argument("--start", type=float)
    parser.add_argument("--dur", type=float)
    parser.add_argument("--window-ms", type=float, default=400)
    parser.add_argument("--touch-times")
    parser.add_argument("--json")
    parser.add_argument("--csv")
    parser.add_argument("--snapshot")
    args = parser.parse_args(argv)

    if args.snapshot:
        snapshot(args.clip, args.snapshot, args.start)
        width, height = probe_size(args.clip)
        print(f"wrote {args.snapshot} ({width}x{height}); pick the two flash bands as X,Y,W,H")
        return 0
    if not args.mac or not args.phone:
        parser.error("--mac and --phone are required (use --snapshot to find them)")

    width, height = probe_size(args.clip)
    mac_region = parse_region(args.mac, width, height)
    phone_region = parse_region(args.phone, width, height)
    mac_samples = region_luma(args.clip, mac_region, args.start, args.dur)
    phone_samples = region_luma(args.clip, phone_region, args.start, args.dur)
    touches = read_touches(args.touch_times) if args.touch_times else ()
    result = analyze(mac_samples, phone_samples, args.window_ms, touches)

    interval = result["frameIntervalMs"]
    print(f"frames {len(mac_samples)} · interval {interval:.2f} ms (±{interval / 2:.1f} ms before interpolation)"
          if interval else "frames: none")
    if interval and interval > 5:
        print("warning: the clip is slower than 200 fps; export the original slow-motion file")
    print(f"transitions: mac {result['macTransitions']} · phone {result['phoneTransitions']} · "
          f"unpaired {result['unpaired']}")
    print(describe("glass-to-glass", result["glassToGlassMs"]))
    if touches:
        print(describe("touch -> Mac photon", result["touchToMacMs"]))
        print(describe("touch -> phone photon", result["touchToPhoneMs"]))
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(result, indent=2))
    if args.csv:
        with open(args.csv, "w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(["mac_s", "phone_s", "delay_ms"])
            for row in result["pairs"]:
                writer.writerow([f"{row['mac']:.5f}", f"{row['phone']:.5f}", f"{row['delayMs']:.2f}"])
    return 0 if result["glassToGlassMs"].get("n") else 1


if __name__ == "__main__":
    sys.exit(main())
