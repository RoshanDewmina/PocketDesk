#!/usr/bin/env python3
"""Align phone-export rows with Mac statistics rows without inventing precision.

Usage:
  align_exports.py PHONE.jsonl PHONE_START PHONE_END MAC.jsonl MAC_START MAC_END [MAC_LINE ...]

Ranges retain the historical convention: phone bounds are zero-based/end-exclusive and Mac
bounds are one-based/inclusive. New logs are aligned by their ``at`` timestamps. The embedded
host summary belongs to ``phone at - hostSummaryAgeMs`` rather than to the phone sample time.
Old logs without timestamps use several host fields and only emit a mapping when the best offset
is both well-supported and distinguishable from the runner-up. Ambiguous data exits 2.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import sys


MATCH_FIELDS = ("encodedFPS", "sentFPS", "sentKbps", "targetKbps", "encodeMs")


def parse_time(value):
    """Return epoch seconds for common JSON date encodings, or None."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        if not math.isfinite(value):
            return None
        magnitude = abs(value)
        if magnitude >= 1e17:  # nanoseconds
            return value / 1e9
        if magnitude >= 1e14:  # microseconds
            return value / 1e6
        if magnitude >= 1e11:  # milliseconds
            return value / 1e3
        return float(value)
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value:
        return None
    try:
        return parse_time(float(value))
    except ValueError:
        pass
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.timestamp()


def row_time(row):
    for key in ("at", "recordedAt", "timestamp", "sampleTime"):
        parsed = parse_time((row or {}).get(key))
        if parsed is not None:
            return parsed
    return None


def host_time_for_phone(row):
    """Wall time represented by a phone row's embedded host summary."""
    phone_time = row_time(row)
    if phone_time is None:
        return None
    age = (row or {}).get("hostSummaryAgeMs")
    if isinstance(age, (int, float)) and not isinstance(age, bool) and math.isfinite(age):
        return phone_time - max(0.0, age) / 1000.0
    return phone_time


def read_rows(path):
    out = []
    with open(path) as handle:
        for line_number, line in enumerate(handle, 1):
            try:
                row = json.loads(line)
            except (json.JSONDecodeError, TypeError):
                continue
            if isinstance(row, dict):
                out.append((line_number, row))
    return out


def timestamp_pairs(phone, mac, tolerance=0.75):
    """Pair each phone host-summary time to its nearest Mac sample, monotonically."""
    mac_times = [(index, row_time(row)) for index, (_, row) in enumerate(mac)]
    if not mac_times or any(value is None for _, value in mac_times):
        return None
    pairs = []
    minimum_index = 0
    for phone_index, (_, row) in enumerate(phone):
        target = host_time_for_phone(row)
        if target is None:
            continue
        candidates = [(abs(value - target), index) for index, value in mac_times
                      if index >= minimum_index and abs(value - target) <= tolerance]
        if not candidates:
            continue
        delta, mac_index = min(candidates)
        pairs.append((phone_index, mac_index, delta))
        minimum_index = mac_index + 1
    return pairs


def value_score(phone_host, mac_row):
    scores = []
    for field in MATCH_FIELDS:
        left, right = phone_host.get(field), mac_row.get(field)
        if not isinstance(left, (int, float)) or isinstance(left, bool):
            continue
        if not isinstance(right, (int, float)) or isinstance(right, bool):
            continue
        scale = max(1.0, abs(left), abs(right))
        scores.append(max(0.0, 1.0 - abs(left - right) / (0.08 * scale)))
    return sum(scores) / len(scores) if scores else None


def legacy_candidates(phone, mac, minimum_pairs=8):
    candidates = []
    for offset in range(-len(mac) + 1, len(phone)):
        scores = []
        for phone_index, (_, phone_row) in enumerate(phone):
            mac_index = phone_index - offset
            if not 0 <= mac_index < len(mac):
                continue
            score = value_score(phone_row.get("host") or {}, mac[mac_index][1])
            if score is not None:
                scores.append(score)
        if len(scores) >= minimum_pairs:
            candidates.append((offset, sum(scores) / len(scores), len(scores)))
    return sorted(candidates, key=lambda item: (item[1], item[2]), reverse=True)


def choose_legacy(candidates, minimum_score=0.80, minimum_margin=0.03):
    if not candidates or candidates[0][1] < minimum_score:
        return None, "no well-supported multi-field alignment"
    best = candidates[0]
    runner = candidates[1] if len(candidates) > 1 else None
    if runner and best[1] - runner[1] < minimum_margin:
        return None, (f"ambiguous offsets {best[0]} ({best[1]:.3f}) and "
                      f"{runner[0]} ({runner[1]:.3f})")
    return best, None


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 6:
        print(__doc__)
        return 2
    phone_all = read_rows(argv[0])
    ps, pe = int(argv[1]), int(argv[2])
    mac_all = read_rows(argv[3])
    ms, me = int(argv[4]), int(argv[5])
    phone = phone_all[ps:pe]
    mac = [(line, row) for line, row in mac_all if ms <= line <= me]
    if not phone or not mac:
        print("alignment unavailable: selected range is empty", file=sys.stderr)
        return 2

    pairs = timestamp_pairs(phone, mac)
    timestamp_alignment = False
    if pairs is not None and len(pairs) >= max(3, min(8, len(phone) // 2)):
        timestamp_alignment = True
        max_error = max(delta for _, _, delta in pairs)
        print(f"timestamp alignment: {len(pairs)} pairs, max error {max_error * 1000:.0f} ms")
    else:
        candidates = legacy_candidates(phone, mac)
        best, reason = choose_legacy(candidates)
        if best is None:
            print(f"alignment unavailable: {reason}; preserve explicit run boundaries", file=sys.stderr)
            return 2
        offset, score, count = best
        print(f"legacy multi-field alignment: offset {offset}, score {score:.3f}, pairs {count}")
        print("warning: no sample timestamps; this is sample-order alignment, not clock pairing")

    for mark in argv[6:]:
        line = int(mark)
        mac_index = next((index for index, (number, _) in enumerate(mac) if number == line), None)
        if mac_index is None:
            print(f"mac line {line} is outside selected range")
            continue
        if timestamp_alignment:
            exact = next((pair for pair in pairs if pair[1] == mac_index), None)
            if exact is None:
                phone_index, paired_mac_index, error = min(
                    pairs, key=lambda pair: abs(pair[1] - mac_index))
                nearest_line = mac[paired_mac_index][0]
                print(f"mac line {line} -> unpaired; nearest timestamp pair is mac line "
                      f"{nearest_line} / phone row {ps + phone_index} "
                      f"({error * 1000:.0f} ms error)")
                continue
            mapped = exact[0]
        else:
            mapped = mac_index + offset
        print(f"mac line {line} -> phone row {ps + mapped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
