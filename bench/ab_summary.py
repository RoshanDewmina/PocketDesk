#!/usr/bin/env python3
"""Usage: ab_summary.py LABEL=phone-export.jsonl [LABEL=... ] [--last=SECONDS] [--rows=START:END]
                     [--from=ISO8601] [--to=ISO8601] [--min-fps=30]
                     [--motion=DISTINCT_FPS] [--all]
One row per phone statistics export (Controls → Picture → Export statistics log), for A/B runs:
the active tuning, the Mac's encoder trace (from the embedded host summary), delivered and
presented cadence, the per-second arrival-gap signature, the bench marker's uncalibrated latency and
the latest legibility score. Windows with decoded fps below --min-fps (connect, idle) are skipped
for the cadence and gap columns. ``--from``/``--to`` use a sample's ISO-8601 or numeric ``at``
timestamp; legacy logs need ``--rows`` (zero-based, END exclusive). Marker latency uses only
motion windows (marker distinct fps ≥ --motion, default 20), with a valid clock uncertainty. An
idle picture re-pushes the last marker, so its marker age is never reported as latency. ``--all``
widens cadence windows only. Camera calibration is a separate physical evidence gate."""
import json, math, os, statistics, sys

from align_exports import parse_time, row_time


def load(path):
    rows = []
    with open(os.path.expanduser(path)) as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("{"):
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return [r for r in rows if r.get("role") == "phone"]


def num(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def pct(values, fraction):
    ordered = sorted(v for v in values if num(v))
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, max(0, int(round(fraction * len(ordered) + 0.5)) - 1))]


def med(values):
    ordered = [v for v in values if num(v)]
    return statistics.median(ordered) if ordered else None


def fmt(value, digits=1):
    return "–" if value is None else (f"{value:.{digits}f}" if isinstance(value, float) else str(value))


def time_option(args, name):
    prefix = f"--{name}="
    raw = next((arg.split("=", 1)[1] for arg in args if arg.startswith(prefix)), None)
    if raw is None:
        return None
    parsed = parse_time(raw)
    if parsed is None:
        raise ValueError(f"invalid --{name} timestamp: {raw!r}")
    return parsed


def select_time(rows, start=None, end=None):
    if start is None and end is None:
        return rows
    selected = []
    for row in rows:
        value = row_time(row)
        if value is None:
            continue
        if start is not None and value < start:
            continue
        if end is not None and value >= end:
            continue
        selected.append(row)
    return selected


def select_last(rows, seconds):
    times = [row_time(row) for row in rows]
    present = [value for value in times if value is not None]
    if present:
        return [row for row, value in zip(rows, times)
                if value is not None and value >= max(present) - seconds]
    # Legacy logs were sampled once per second, so retain the historical approximation.
    return rows[-int(seconds):]


def summarize(label, rows, min_fps, motion_fps, all_active=False):
    hosts = [r.get("host") or {} for r in rows]
    cadence = [r for r in rows if num(r.get("decodedFPS")) and r["decodedFPS"] >= min_fps]
    marker_min = max(0.000001, motion_fps)
    marker_motion = [r for r in cadence
                     if num(r.get("markerDistinctFPS")) and r["markerDistinctFPS"] >= marker_min]
    clocked_motion = [r for r in marker_motion
                      if num(r.get("clockUncertaintyMs"))
                      and math.isfinite(r["clockUncertaintyMs"])
                      and r["clockUncertaintyMs"] >= 0]
    cadence_report = cadence if all_active else marker_motion
    tunings = sorted({r.get("tuning") for r in rows if r.get("tuning")})
    gap_windows = [r for r in cadence_report if num(r.get("renderGapMaxMs"))]
    gap_share = (sum(1 for r in gap_windows if r["renderGapMaxMs"] >= 80) / len(gap_windows)) if gap_windows else None
    legibility = next((r["legibility"] for r in reversed(rows) if isinstance(r.get("legibility"), dict)), None)
    return {
        "run": label,
        "samples": len(rows),
        "cadence s": len(cadence_report),
        "marker motion s": len(marker_motion),
        "clocked marker s": len(clocked_motion),
        "sample time": ("present" if any(row_time(r) is not None for r in rows) else "missing"),
        "tuning": "; ".join(tunings) or "?",
        "route": next((r.get("routeDetail") or r.get("route") for r in reversed(rows) if r.get("route")), "?"),
        "size": next((f"{r.get('receivedWidth')}x{r.get('receivedHeight')}" for r in reversed(rows) if r.get("receivedWidth")), "?"),
        "enc fps p50": med([h.get("encodedFPS") for h in hosts]),
        "encodeMs p50": med([h.get("encodeMs") for h in hosts]),
        "VT lat p50/p90": f"{fmt(med([h.get('encodeLatencyMs') for h in hosts]))}/{fmt(pct([h.get('encodeLatencyP90Ms') for h in hosts], 0.5))}",
        "in-flight max": max([h.get("encodeInFlightMax") for h in hosts if num(h.get("encodeInFlightMax"))] or [None]),
        "rate upd/s p50": med([h.get("rateUpdates") for h in hosts]),
        "key KB max": (max([h.get("keyFrameBytesMax") for h in hosts if num(h.get("keyFrameBytesMax"))] or [0]) // 1024) or None,
        "limit cpu %": (100 * sum(1 for h in hosts if h.get("qualityLimitation") == "cpu") / len(hosts)) if hosts else None,
        "decoded p50": med([r.get("decodedFPS") for r in cadence_report]),
        "shown p50": med([r.get("presentedFPS") for r in cadence_report]),
        "superseded/s": med([r.get("supersededFrames") for r in cadence_report]),
        "gap max p50": med([r.get("renderGapMaxMs") for r in cadence_report]),
        "gap≥80ms %": None if gap_share is None else 100 * gap_share,
        "rtt p50/p90": f"{fmt(med([r.get('rttMs') for r in rows]))}/{fmt(pct([r.get('rttMs') for r in rows], 0.9))}",
        "marker p50/p95 uncal": f"{fmt(med([r.get('glassP50Ms') for r in clocked_motion]))}/{fmt(pct([r.get('glassP95Ms') for r in clocked_motion], 0.5))}",
        "±clock": med([r.get("clockUncertaintyMs") for r in clocked_motion]),
        "distinct/s": med([r.get("markerDistinctFPS") for r in marker_motion]),
        "shownΔ p50/p90": f"{fmt(med([r.get('presentedIntervalP50Ms') for r in cadence_report]))}/{fmt(med([r.get('presentedIntervalP90Ms') for r in cadence_report]))}",
        "120Hz %": (100 * med([r.get("presentedAt120Share") for r in cadence_report])) if med([r.get("presentedAt120Share") for r in cadence_report]) is not None else None,
        "physical latency": "needs camera calibration",
        "click→photon p50": med([r.get("inputToPhotonP50Ms") for r in rows]),
        "CER 11pt/13pt": f"{fmt(legibility['cer'].get('11pt'))}/{fmt(legibility['cer'].get('13pt'))} ({legibility.get('surface')} +{legibility.get('ageMs', 0) / 1000:.1f}s)" if legibility else "–",
    }


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    last = next((float(a.split("=")[1]) for a in args if a.startswith("--last=")), None)
    min_fps = next((float(a.split("=")[1]) for a in args if a.startswith("--min-fps=")), 30)
    motion_fps = next((float(a.split("=")[1]) for a in args if a.startswith("--motion=")), 20)
    all_active = "--all" in args
    try:
        time_start = time_option(args, "from")
        time_end = time_option(args, "to")
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if time_start is not None and time_end is not None and time_start >= time_end:
        print("error: --from must be earlier than --to", file=sys.stderr)
        return 2
    window = next((a.split("=")[1] for a in args if a.startswith("--rows=")), None)
    runs = []
    for arg in args:
        if arg.startswith("--"):
            continue
        label, _, path = arg.partition("=")
        rows = load(path or label)
        rows = select_time(rows, time_start, time_end)
        if window:
            row_start, _, row_end = window.partition(":")
            rows = rows[int(row_start or 0):int(row_end) if row_end else None]
        if last:
            rows = select_last(rows, last)
        if rows:
            runs.append(summarize(label, rows, min_fps, motion_fps, all_active))
    if not runs:
        print(__doc__)
        return 2
    keys = list(runs[0].keys())
    width = max(len(k) for k in keys)
    print(f"{'':{width}}  " + "  ".join(f"{r['run']:>18}" for r in runs))
    for key in keys[1:]:
        print(f"{key:{width}}  " + "  ".join(f"{fmt(r[key]):>18}" for r in runs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
