#!/usr/bin/env python3
"""Run the real pure state-machine test methods with minimal compile fixtures, without Xcode."""
from pathlib import Path
import re
import subprocess
import tempfile

receipt = Path(__file__).resolve().parent
root = receipt.parents[3]
source = (root / "RemoteTests/ConnectionQualityTests.swift").read_text()
source = source.split("final class ConnectionQualityWireTests")[0].replace("import XCTest", "import Foundation")
classes = list(re.finditer(r"final class (\w+): XCTestCase", source))
lines = ["import Foundation", "import Darwin", "var methods = 0"]
for i, match in enumerate(classes):
    section = source[match.end():classes[i + 1].start() if i + 1 < len(classes) else len(source)]
    tests = re.findall(r"    func (test\w+)\([^)]*\)([^\{]*)\{", section)
    instance = f"suite{i}"
    lines.append(f"let {instance} = {match[1]}()")
    for name, signature in tests:
        call = f"{instance}.{name}()"
        lines.append(f'do {{ try {call} }} catch {{ failures += 1; print("THREW {name} \\(error)") }}'
                     if "throws" in signature else call)
        lines.append("methods += 1")
lines += [r'print("\(methods) test methods, \(assertions) assertions, \(failures) failures")',
          "exit(failures == 0 ? 0 : 1)"]
with tempfile.TemporaryDirectory(prefix="farside-quality-pure-") as directory:
    scratch = Path(directory)
    (scratch / "Tests.swift").write_text(source)
    (scratch / "main.swift").write_text("\n".join(lines))
    files = [root / "RemoteShared" / name for name in ["ConnectionQuality.swift", "ResumeTiming.swift",
             "MacNetworkLink.swift", "NetworkLinkHint.swift", "WiFiStallDetector.swift"]]
    subprocess.run(["swiftc", *map(str, files), str(receipt / "Fixtures.swift"),
                    str(receipt / "Assertions.swift"), str(scratch / "Tests.swift"),
                    str(scratch / "main.swift"), "-o", str(scratch / "check")], check=True)
    subprocess.run([str(scratch / "check")], check=True)
