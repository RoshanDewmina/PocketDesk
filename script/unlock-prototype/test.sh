#!/bin/bash
# No live capture/input/launchd: compile and unit-test policy only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [[ ${1:-} != --locked ]]; then
    "$here/check-build-gates.sh"
    exec /usr/bin/lockf -k /tmp/farside-xcodebuild.lock "$0" --locked
fi
"$here/check-build-gates.sh"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
exec xcrun swift test --package-path "$here" --scratch-path /Volumes/Studio/Development/Caches/b7-unlock/DD/SPM -j 2
