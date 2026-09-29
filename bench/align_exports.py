"""Usage: align.py phone-export.jsonl PHONE_START PHONE_END mac-log.jsonl MAC_START MAC_END
Aligns phone rows to Mac log lines by cross-correlating the encoded-fps sequence the phone rows carry in
their embedded host summary with the Mac's own sentFPS/encodedFPS, then prints the phone-row index of each
Mac line-range boundary the caller asks about (all 1-based Mac line numbers as in the file)."""
import json, sys


def rows(path):
    out = []
    for line in open(path):
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                out.append(None)
        else:
            out.append(None)
    return out


phone = rows(sys.argv[1])
ps, pe = int(sys.argv[2]), int(sys.argv[3])
mac = rows(sys.argv[4])
ms, me = int(sys.argv[5]), int(sys.argv[6])
p = [((r or {}).get("host") or {}).get("encodedFPS") for r in phone[ps:pe]]
m = [(r or {}).get("encodedFPS") for r in mac[ms - 1:me]]
best = None
for offset in range(-len(m), len(p)):
    score = 0
    n = 0
    for i, value in enumerate(p):
        j = i - offset
        if 0 <= j < len(m) and value is not None and m[j] is not None:
            n += 1
            score += 1 if abs(value - m[j]) < 1.5 else 0
    if n >= 40 and (best is None or score / n > best[1]):
        best = (offset, score / n, n)
print("best offset (phone row = mac index + offset):", best)
offset = best[0]
for mark in sys.argv[7:]:
    line = int(mark)
    print(f"mac line {line} -> phone row {ps + (line - ms) + offset}")
