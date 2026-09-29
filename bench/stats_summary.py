#!/usr/bin/env python3
"""Usage: stats_summary.py PocketDeskStreamStats.jsonl [--last=SECONDS]
Summarizes the per-second stream statistics that PocketDesk writes when "Stream statistics" is on
(phone: exported log; Mac: ~/Library/Caches/PocketDeskStreamStats.jsonl). Marker latency is
reported only for distinct-motion samples with a valid clock and remains uncalibrated until the
camera gate. Prints p50/p90 per stage."""
import json, math, statistics, sys

from align_exports import row_time

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

def last_seconds(records, seconds):
    times = [row_time(record) for record in records]
    present = [value for value in times if value is not None]
    if present:
        return [record for record, value in zip(records, times)
                if value is not None and value >= max(present) - seconds]
    return records[-int(seconds):]

def field_values(records, role, field):
    selected = records
    if role == "phone" and field.startswith("glass"):
        selected = [record for record in records
                    if isinstance(record.get("markerDistinctFPS"), (int, float))
                    and record["markerDistinctFPS"] > 0
                    and isinstance(record.get("clockUncertaintyMs"), (int, float))
                    and not isinstance(record.get("clockUncertaintyMs"), bool)
                    and math.isfinite(record["clockUncertaintyMs"])
                    and record["clockUncertaintyMs"] >= 0]
    return [record[field] for record in selected
            if isinstance(record.get(field), (int, float)) and not isinstance(record.get(field), bool)]

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
            records = last_seconds(records, last)
        if not records:
            continue
        tuning = {r.get("tuning") for r in records if r.get("tuning")}
        print(f"{role}: {len(records)} samples · tuning {', '.join(sorted(tuning)) or 'unknown'}")
        for field in fields:
            values = field_values(records, role, field)
            if values:
                suffix = "   uncalibrated marker" if role == "phone" and field.startswith("glass") else ""
                print(f"  {field:24} p50 {statistics.median(values):9.1f}   p90 {percentile(values, 0.9):9.1f}   n={len(values)}{suffix}")
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
        if role == "phone":
            print("  physical latency          unavailable until camera calibration")

if __name__ == "__main__":
    main()
