#!/usr/bin/env python3
"""Usage: ab_summary.py LABEL=phone-export.jsonl [LABEL=... ] [--last=SECONDS] [--min-fps=30]
One row per phone statistics export (Controls → Picture → Export statistics log), for A/B runs:
the active tuning, the Mac's encoder trace (from the embedded host summary), delivered and
presented cadence, the per-second arrival-gap signature, the bench marker's glass-to-glass and
the latest legibility score. Windows with decoded fps below --min-fps (connect, idle) are skipped
for the cadence and gap columns."""
import json, os, statistics, sys


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


def summarize(label, rows, min_fps):
    hosts = [r.get("host") or {} for r in rows]
    active = [r for r in rows if num(r.get("decodedFPS")) and r["decodedFPS"] >= min_fps]
    tunings = sorted({r.get("tuning") for r in rows if r.get("tuning")})
    gap_windows = [r for r in active if num(r.get("renderGapMaxMs"))]
    gap_share = (sum(1 for r in gap_windows if r["renderGapMaxMs"] >= 80) / len(gap_windows)) if gap_windows else None
    legibility = next((r["legibility"] for r in reversed(rows) if isinstance(r.get("legibility"), dict)), None)
    return {
        "run": label,
        "samples": len(rows),
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
        "decoded p50": med([r.get("decodedFPS") for r in active]),
        "shown p50": med([r.get("presentedFPS") for r in active]),
        "superseded/s": med([r.get("supersededFrames") for r in active]),
        "gap max p50": med([r.get("renderGapMaxMs") for r in active]),
        "gap≥80ms %": None if gap_share is None else 100 * gap_share,
        "rtt p50/p90": f"{fmt(med([r.get('rttMs') for r in rows]))}/{fmt(pct([r.get('rttMs') for r in rows], 0.9))}",
        "glass p50/p95": f"{fmt(med([r.get('glassP50Ms') for r in active]))}/{fmt(pct([r.get('glassP95Ms') for r in active], 0.5))}",
        "±clock": med([r.get("clockUncertaintyMs") for r in rows]),
        "distinct/s": med([r.get("markerDistinctFPS") for r in active]),
        "shownΔ p50/p90": f"{fmt(med([r.get('presentedIntervalP50Ms') for r in active]))}/{fmt(med([r.get('presentedIntervalP90Ms') for r in active]))}",
        "120Hz %": (100 * med([r.get("presentedAt120Share") for r in active])) if med([r.get("presentedAt120Share") for r in active]) is not None else None,
        "click→photon p50": med([r.get("inputToPhotonP50Ms") for r in rows]),
        "CER 11pt/13pt": f"{fmt(legibility['cer'].get('11pt'))}/{fmt(legibility['cer'].get('13pt'))} ({legibility.get('surface')} +{legibility.get('ageMs', 0) / 1000:.1f}s)" if legibility else "–",
    }


def main():
    args = sys.argv[1:]
    last = next((float(a.split("=")[1]) for a in args if a.startswith("--last=")), None)
    min_fps = next((float(a.split("=")[1]) for a in args if a.startswith("--min-fps=")), 30)
    runs = []
    for arg in args:
        if arg.startswith("--"):
            continue
        label, _, path = arg.partition("=")
        rows = load(path or label)
        if last:
            rows = rows[-int(last):]
        if rows:
            runs.append(summarize(label, rows, min_fps))
    if not runs:
        print(__doc__)
        return
    keys = list(runs[0].keys())
    width = max(len(k) for k in keys)
    print(f"{'':{width}}  " + "  ".join(f"{r['run']:>18}" for r in runs))
    for key in keys[1:]:
        print(f"{key:{width}}  " + "  ".join(f"{fmt(r[key]):>18}" for r in runs))


if __name__ == "__main__":
    main()
