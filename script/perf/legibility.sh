#!/bin/zsh
# Scores bench-chart screenshots with the phone's Vision scorer.
#   script/perf/legibility.sh [--seed 0x3a7] [--marker] [--json] image.png ...
# The seed is read from the marker strip when the screenshot contains it (Fit view); pass --seed otherwise.
# Builds the CLI once into ~/Library/Caches/farside-perf (no Xcode project involved).
set -euo pipefail
REPO=${0:A:h:h:h}
CACHE=${HOME}/Library/Caches/farside-perf
BIN=$CACHE/legibility
SOURCES=("$REPO/script/perf/legibility/main.swift" "$REPO/RemoteShared/LegibilityChart.swift"
         "$REPO/RemoteShared/LegibilityScore.swift" "$REPO/RemoteShared/BenchMarker.swift")
mkdir -p "$CACHE"
stale=0
for source in "${SOURCES[@]}"; do
  [[ -x $BIN && $BIN -nt $source ]] || stale=1
done
if (( stale )); then
  echo "building $BIN" >&2
  swiftc -O -swift-version 5 "${SOURCES[@]}" -o "$BIN" -framework Vision -framework CoreGraphics -framework ImageIO
fi
exec "$BIN" "$@"
