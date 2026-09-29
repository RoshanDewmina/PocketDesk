#!/bin/zsh
# End-to-end check of the built FarsideWatchdog helper against a stand-in host app: crash relaunch,
# crash-loop stop with one safe-mode launch, clean quit respected, and hang detection. Never touches
# the real host, its pairing, launchd or ServiceManagement; only the fixture's own processes are signalled.
set -euo pipefail
cd "${0:A:h:h}"
built="${1:-$PWD/outputs/RemoteBuild/Build/Products/Debug/PocketDeskRemoteHost.app}"
helper="$built/Contents/MacOS/FarsideWatchdog"
[[ -x "$helper" ]] || { print -u2 "Build the host first; no helper at $helper"; exit 2; }
work="$PWD/outputs/watchdog-fixture"
app="$work/WatchdogFixture.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp scripts/watchdog-fixture/Info.plist "$app/Contents/Info.plist"
swiftc -O scripts/watchdog-fixture/main.swift RemoteHost/HostWatchdogState.swift -o "$app/Contents/MacOS/WatchdogFixture"
cp "$helper" "$app/Contents/MacOS/FarsideWatchdog"
codesign --force --sign - "$app/Contents/MacOS/FarsideWatchdog" >/dev/null 2>&1
codesign --force --sign - "$app" >/dev/null 2>&1
result=0
python3 scripts/watchdog-fixture/drive.py "$app" || result=$?
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" >/dev/null 2>&1 || true
exit $result
