#!/bin/bash
# Build/sign artifacts only. Does not install, launch, prompt for TCC, or notarize.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=/Volumes/Studio/Development/Caches/b7-unlock/DD/SPM
identity=${UNLOCK_SIGN_IDENTITY:-Developer ID Application: Roshan Dewmina Imalsha Silva Pulle (39HM2X8GS6)}
if [[ ${1:-} != --locked ]]; then
    "$here/check-build-gates.sh"
    exec /usr/bin/lockf -k /tmp/farside-xcodebuild.lock "$0" --locked
fi
# Recheck after acquiring the lock, since a testing quiet window may have started in the queue.
"$here/check-build-gates.sh"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift build --package-path "$here" --scratch-path "$scratch" -c debug -j 2
bin=$(xcrun swift build --package-path "$here" --scratch-path "$scratch" -c debug --show-bin-path)
out="$scratch/artifacts"
mkdir -p "$out/UnlockAgent.app/Contents/MacOS"
cp "$bin/UnlockDaemon" "$out/UnlockDaemon"
cp "$bin/UnlockControl" "$out/UnlockControl"
cp "$bin/UnlockAgent" "$out/UnlockAgent.app/Contents/MacOS/UnlockAgent"
cp "$here/plists/Info.plist" "$out/UnlockAgent.app/Contents/Info.plist"
for role in daemon control; do
    case "$role" in daemon) name=UnlockDaemon;; control) name=UnlockControl;; esac
    codesign --force --options runtime --timestamp=none --sign "$identity" --identifier "com.roshan.Farside.UnlockPrototype.$role" "$out/$name"
    codesign --verify --strict "$out/$name"
done
codesign --force --options runtime --timestamp=none --sign "$identity" "$out/UnlockAgent.app"
codesign --verify --strict --deep "$out/UnlockAgent.app"
echo "Signed artifacts: $out (development-only; not notarized)"
