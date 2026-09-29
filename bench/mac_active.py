"""Usage: mac_active.py mac-log.jsonl LABEL=START-END [LABEL=START-END ...] [--min-fps=30]
Per Mac-log line range (1-based, inclusive), medians/p90 over the active seconds (encodedFPS >= min) of the
capture, encoder and link fields, for the session notebook."""
import json, statistics, sys


def pct(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, max(0, int(round(fraction * len(ordered) + 0.5)) - 1))]


def fmt(value):
    return "–" if value is None else f"{value:.1f}"


lines = open(sys.argv[1]).read().splitlines()
min_fps = next((float(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--min-fps=")), 30)
fields = ["captureFPS", "captureIdleFPS", "sourceFPS", "captureLatencyP90Ms", "captureGapP90Ms", "captureGapMaxMs",
          "encodedFPS", "encodeLatencyMs", "encodeLatencyP90Ms", "encodeInFlightMax", "rateUpdates",
          "droppedBeforeEncode", "pushSkipped", "sentKbps", "targetKbps", "pacerDelayMs", "rttMs"]
for spec in sys.argv[2:]:
    if spec.startswith("--"):
        continue
    label, _, span = spec.partition("=")
    start, _, end = span.partition("-")
    rows = []
    for line in lines[int(start) - 1:int(end)]:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    active = [r for r in rows if isinstance(r.get("encodedFPS"), (int, float)) and r["encodedFPS"] >= min_fps]
    print(f"=== {label} lines {start}-{end}: {len(rows)} samples, {len(active)} active (encoded >= {min_fps:g})")
    for field in fields:
        values = [r[field] for r in active if isinstance(r.get(field), (int, float))]
        if values:
            print(f"  {field:22} p50 {fmt(statistics.median(values)):>7}  p90 {fmt(pct(values, 0.9)):>7}  n={len(values)}")
