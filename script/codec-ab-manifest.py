#!/usr/bin/env python3
"""Bind a benchmark bundle to the source files used for its build."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[2])
paths = [p for folder in ("RemoteTests", "RemoteShared", "RemoteHost", "RemotePhone")
         for p in (root / folder).rglob("*.swift")]
paths += [root / "PocketDesktop.xcodeproj/project.pbxproj", root / "project.yml",
          root / "PocketDesktop.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
          root / "script/codec-ab.sh", root / "script/codec-ab-manifest.py", root / "script/codec-ab-report.py"]
current = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
action, manifest = sys.argv[1], pathlib.Path(sys.argv[3])
if action == "snapshot":
    manifest.write_text(json.dumps({"sources": current}, indent=2) + "\n")
else:
    recorded = json.loads(manifest.read_text())
    if recorded["sources"] != current:
        raise SystemExit("Source changed since build snapshot; rebuild before collecting receipts.")
    executable = pathlib.Path(sys.argv[4])
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    if action == "seal":
        recorded["executableSHA256"] = digest
        manifest.write_text(json.dumps(recorded, indent=2) + "\n")
    elif action == "verify":
        if recorded.get("executableSHA256") != digest:
            raise SystemExit("Benchmark executable differs from build manifest; rebuild.")
    else:
        raise SystemExit("Unknown manifest action")
