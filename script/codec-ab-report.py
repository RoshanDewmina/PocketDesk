#!/usr/bin/env python3
"""Validate same-source codec pairs and summarize offline benchmark JSONL receipts."""
import argparse
import collections
import json
import pathlib


def percentile(values, fraction):
    values = sorted(v for v in values if v is not None)
    return values[min(len(values) - 1, int((len(values) - 1) * fraction))] if values else None


def number(value, precision=2):
    return "—" if value is None else f"{value:.{precision}f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipts", type=pathlib.Path, nargs="+")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    rows, clips, inventories = [], {}, []
    for receipt in args.receipts:
        records = [json.loads(line) for line in receipt.read_text().splitlines() if line.strip()]
        meta = next(r for r in records if r["kind"] == "meta")
        inventories.append((str(receipt), meta.get("filter", ""), meta["frames"], len(meta["caseLabels"])))
        frames = collections.defaultdict(list)
        for record in records:
            if record["kind"] == "frame":
                frames[record["run"]].append(record)
        aggregates = [r for r in records if r["kind"] == "aggregate"]
        if not aggregates:
            raise ValueError(f"No completed aggregates: {receipt}")
        expected = {f"{case}-r{repeat + 1}" for case in meta["caseLabels"] for repeat in range(meta["repeatCount"])}
        actual = [r["run"] for r in aggregates]
        if len(actual) != len(set(actual)) or set(actual) != expected or set(frames) != expected:
            raise ValueError(f"Incomplete/duplicate/aborted matrix: {receipt}; expected {len(expected)} runs, got {len(actual)}")
        grouped = collections.defaultdict(set)
        for row in aggregates:
            repeat = row["run"].rsplit("-r", 1)[1]
            grouped[(row["geometry"], row["kbps"], repeat)].add(row["codec"])
        if any(codecs != {"H264", "H265"} for codecs in grouped.values()):
            raise ValueError(f"Matrix must include both codecs at every geometry/rate/repeat: {receipt}")
        for row in aggregates:
            runframes = frames[row["run"]]
            if len(runframes) != row["frames"] or {f["index"] for f in runframes} != set(range(row["frames"])):
                raise ValueError(f"Incomplete frame timeline: {receipt}: {row['run']}")
            if row["wrongTimestamp"] or row["wrongDimensions"] or row["decodeMissing"]:
                raise ValueError(f"Invalid decoded frame receipt: {row['run']}")
            signature = [(f["index"], f["phase"], f["sourceHash"]) for f in sorted(runframes, key=lambda f: f["index"])]
            pair = (row["geometry"], row["frames"])
            if pair in clips and clips[pair] != signature:
                raise ValueError(f"Different source clip across codecs/modes/repeats: {pair}")
            clips[pair] = signature
            rows.append((meta["mode"], row, runframes))
    text = ["# Offline codec receipts", "", "Complete codec pairs, source identity, frame timeline and decoded timestamp/dimension checks passed.",
            "Timing is serial submit-to-callback cost on this Mac; it is not achieved live fps or phone latency.", ""]
    for path, filter_value, frame_count, case_count in inventories:
        scope = "DIAGNOSTIC SUBSET" if filter_value or frame_count != 240 else "Full configured matrix"
        text.append(f"- {scope}: `{path}`; filter `{filter_value or '(none)'}`, {frame_count} frames/case, {case_count} cases.")
    text += ["",
            "| Mode | Geometry | Mb/s | Codec | Frames emitted/offered | PSNR Y median dB | Text SSIM median | Encode p50/p90 ms | Decode p50/p90 ms | Mean bytes/emitted frame | Max key KB |", "|---|---|---:|---|---|---:|---:|---:|---:|---:|---:|"]
    for mode, row, _ in rows:
        text.append(f"| {mode} | {row['geometry']} {row['width']}×{row['height']} | {row['kbps']/1000:g} | {row['codec']} | {row['emitted']}/{row['frames']} | {number(row['psnrYP50'])} | {number(row['textSSIMP50'], 4)} | {number(row['encodeP50Ms'])}/{number(row['encodeP90Ms'])} | {number(row['decodeP50Ms'])}/{number(row['decodeP90Ms'])} | {number(row['meanBytesPerFrame'], 0)} | {number(max((k['bytes'] for k in row['keyFrames']), default=0)/1000, 1)} |")
    text += ["", "## Per-content evidence", "", "Quality includes emitted frames only; missing frames are counted explicitly. A lower emitted count cannot be read as better overall quality.", "",
             "| Mode | Run | Content | Emitted/offered | PSNR Y median | Text SSIM median | Encode p50/p90 ms | Decode p50/p90 ms | Bytes/offered frame |", "|---|---|---|---|---:|---:|---:|---:|---:|"]
    for mode, row, frames in rows:
        phases = collections.defaultdict(list)
        for frame in frames:
            phases[frame["phase"]].append(frame)
        for phase, fs in phases.items():
            valid = [f for f in fs if not f.get("encodeMissing", False) and not f.get("decodeMissing", False)]
            psnr = percentile([f.get("psnrY") for f in valid], .5)
            ssim = percentile([f.get("textSSIM") for f in valid], .5)
            ep = [f.get("encodeMs") for f in valid]
            dp = [f.get("decodeMs") for f in valid]
            text.append(f"| {mode} | {row['run']} | {phase} | {len(valid)}/{len(fs)} | {number(psnr)} | {number(ssim,4)} | {number(percentile(ep,.5))}/{number(percentile(ep,.9))} | {number(percentile(dp,.5))}/{number(percentile(dp,.9))} | {sum(f.get('bytes',0) for f in fs)/len(fs):.0f} |")
    args.output.write_text("\n".join(text) + "\n")
    print(f"Validated {len(rows)} aggregate runs, {len(clips)} identical-source clips; wrote {args.output}")


if __name__ == "__main__":
    main()
