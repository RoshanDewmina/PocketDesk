#!/bin/bash
# Offline only. Uses the existing core test target; never builds/launches an app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATES="$HOME/Documents/Codex/2026-10-01/testing"
DD="${FARSIDE_CODEC_DD:-/Volumes/Studio/Development/Caches/b7-codec/DD}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
MODE="${1:-help}"
OUT="${2:-$HOME/Documents/Codex/2026-10-01/perf-push/b7-codec/$MODE}"
gate() {
    [[ ! -e "$GATES/PAUSE-BUILDS" && ! -e "$GATES/PRIORITY-BUILD" ]] || return 1
    local flag
    for flag in "$GATES"/QUIET-GRANTED-*; do
        [[ -e "$flag" ]] || continue
        [[ "$MODE" == timing && "$flag" == "$GATES/QUIET-GRANTED-b7-codec" ]] || return 1
    done
    [[ "$MODE" != timing || -f "$GATES/QUIET-GRANTED-b7-codec" ]] || return 1
}
case "$MODE" in
    build|quality|timing|check) ;;
    *) echo 'Usage: script/codec-ab.sh build|check|quality|timing [output-directory]'; exit 2 ;;
esac
# Check again *after* acquiring the shared lock: a grant can arrive while queued.
if [[ "${FARSIDE_CODEC_LOCKED:-0}" != 1 ]]; then
    while ! gate; do echo "Waiting for build/quiet gate ($MODE)."; sleep 60; done
    exec /usr/bin/lockf -k /tmp/farside-xcodebuild.lock env FARSIDE_CODEC_LOCKED=1 "$0" "$MODE" "$OUT"
fi
if ! gate; then echo 'Gate changed while queued; no build/test started. Rerun when cleared.' >&2; exit 75; fi
mkdir -p "$OUT"
cd "$ROOT"
MANIFEST="$DD/codec-ab-build-manifest.json"
EXECUTABLE="$DD/Build/Products/Debug/RemoteCoreTests.xctest/Contents/MacOS/RemoteCoreTests"
if [[ "$MODE" == build ]]; then
    mkdir -p "$DD"
    python3 script/codec-ab-manifest.py snapshot "$ROOT" "$MANIFEST"
    xcodebuild -project PocketDesktop.xcodeproj -configuration Debug -scheme RemoteCoreTests \
        -destination 'platform=macOS' -derivedDataPath "$DD" \
        -clonedSourcePackagesDirPath /Users/roshansilva/Developer/PocketDesk/outputs/RemoteBuild/SourcePackages \
        -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build-for-testing \
        >"$OUT/build.log" 2>&1
    python3 script/codec-ab-manifest.py seal "$ROOT" "$MANIFEST" "$EXECUTABLE"
    tail -5 "$OUT/build.log"
else
    BUNDLE="$DD/Build/Products/Debug/RemoteCoreTests.xctest"
    [[ -d "$BUNDLE" ]] || { echo 'Run build first.' >&2; exit 1; }
    [[ -f "$MANIFEST" ]] || { echo 'No source/binary build manifest; run build first.' >&2; exit 1; }
    python3 script/codec-ab-manifest.py verify "$ROOT" "$MANIFEST" "$EXECUTABLE"
    cp "$MANIFEST" "$OUT/build-manifest.json"
    export FARSIDE_CODEC_OUT="$OUT" FARSIDE_CODEC_MODE="$MODE"
    if [[ "$MODE" == check ]]; then unset FARSIDE_CODEC_BENCH; else export FARSIDE_CODEC_BENCH=1; fi
    python3 - "$ROOT" "$OUT" "$MODE" <<'PY'
import datetime, hashlib, json, pathlib, subprocess, sys
root, out, mode = sys.argv[1:]
def command(*args):
    return subprocess.check_output(args, text=True).strip()
sources = ["RemoteTests/CodecABBenchTests.swift", "RemoteShared/OwnedVTEncoder.swift",
           "RemoteShared/OwnedHEVCCodec.swift", "RemoteShared/StreamTuning.swift", "RemoteHost/ViewportCapture.swift"]
manifest = {"mode": mode, "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "commit": command("git", "rev-parse", "HEAD"), "worktreeDiff": command("git", "diff", "--stat"),
            "os": command("sw_vers"), "hardware": command("sysctl", "-n", "machdep.cpu.brand_string"),
            "load": command("sysctl", "-n", "vm.loadavg"), "xcode": command("xcodebuild", "-version"),
            "sourceSHA256": {name: hashlib.sha256((pathlib.Path(root)/name).read_bytes()).hexdigest()
                             for name in sources if (pathlib.Path(root)/name).exists()}}
(pathlib.Path(out)/"environment.json").write_text(json.dumps(manifest, indent=2)+"\n")
PY
    xcrun xctest -XCTest RemoteCoreTests.CodecABBenchTests "$BUNDLE" >"$OUT/test.log" 2>&1
    tail -8 "$OUT/test.log"
fi
