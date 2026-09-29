#!/usr/bin/env python3
"""Usage: stats_summary.py PocketDeskStreamStats.jsonl [--last=SECONDS]
Summarizes the per-second stream statistics that PocketDesk writes when "Stream statistics" is on
(phone: exported log; Mac: ~/Library/Caches/PocketDeskStreamStats.jsonl). Prints p50/p90 per stage."""
import json, statistics, sys

FIELDS = {
    "host": ["captureFPS", "captureLatencyMs", "captureLatencyP90Ms", "captureGapP90Ms", "captureGapMaxMs", "pushSkipped",
             "droppedBeforeEncode", "encodedFPS", "encodeMs", "encodeLatencyMs", "encodeLatencyP90Ms", "encodeLatencyMaxMs",
             "encodeInFlightMax", "encodeBytesP50", "keyFrameBytesMax", "rateUpdates", "encoderSessionAgeS",
             "pacerDelayMs", "sentFPS", "sentKbps", "targetKbps", "maxKbps", "availableOutgoingKbps", "keyFrames", "rttMs"],
    "phone": ["receivedFPS", "decodedFPS", "presentedFPS", "supersededFrames", "assemblyMs", "jitterBufferMs",
              "decodeMs", "presentLatencyMs", "presentLatencyP90Ms", "renderGapP90Ms", "renderGapMaxMs", "presentGapP90Ms",
              "markerFrames", "markerDistinctFPS", "glassP50Ms", "glassP95Ms", "glassP99Ms", "glassMaxMs",
              "clockOffsetMs", "clockUncertaintyMs", "presentedIntervalP50Ms", "presentedIntervalP90Ms",
              "presentedIntervalMinMs", "presentedAt120Share", "inputToPhotonP50Ms", "inputToPhotonP95Ms",
              "hostSummaryAgeMs", "packetLossPercent", "freezes", "rttMs", "inputBufferedPeakBytes", "coalescedMoves"],
}

def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int(round(fraction * len(ordered) + 0.5)) - 1))]

def main():
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    last = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--last=")), None)
    rows = []
    for path in paths:
        with open(path) as handle:
            rows += [json.loads(line) for line in handle if line.strip().startswith("{")]
    for role, fields in FIELDS.items():
        records = [r for r in rows if r.get("role") == role]
        if last:
            records = records[-int(last):]
        if not records:
            continue
        tuning = {r.get("tuning") for r in records if r.get("tuning")}
        print(f"{role}: {len(records)} samples · tuning {', '.join(sorted(tuning)) or 'unknown'}")
        for field in fields:
            values = [r[field] for r in records if isinstance(r.get(field), (int, float))]
            if values:
                print(f"  {field:24} p50 {statistics.median(values):9.1f}   p90 {percentile(values, 0.9):9.1f}   n={len(values)}")
        estimates = []
        for r in records:
            host = r.get("host") or {}
            if role == "phone" and r.get("rttMs") is not None and r.get("decodeMs") is not None:
                estimates.append(sum(v or 0 for v in [host.get("captureLatencyMs"), host.get("encodeMs"),
                                                       host.get("pacerDelayMs"), r["rttMs"] / 2,
                                                       r.get("jitterBufferMs"), r["decodeMs"],
                                                       r.get("presentLatencyMs")]))
        if estimates:
            print(f"  {'stage-sum display→draw':24} p50 {statistics.median(estimates):9.1f}   p90 {percentile(estimates, 0.9):9.1f}"
                  "   (estimate: sum of per-second stage averages, excludes panel scan-out and input)")

if __name__ == "__main__":
    main()
