#!/bin/zsh
# The system-integrations verification, in the order it was run: a device-style build on the wildcard
# profile, the Mac host build, the macOS tests, the host UI snapshots, the phone unit tests, push routing
# through `xcrun simctl push`, the SpringBoard tests for the Live Activity, and the whole phone UI suite.
#
#   SIM=<simulator udid> script/verify-system-integrations.sh [step ...]
#
#   steps  device host core host-ui unit routing springboard ui-all   (default: all, in that order)
#   SIM    a dedicated iPhone simulator (needed by unit, routing, springboard and ui-all)
#   DD     derived data (default /Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsideIntegrations)
#   OUT    logs and result bundles (default /tmp/farside-verify)
#
# Every xcodebuild is wrapped in the shared lock, so it queues behind other agents' runs. macOS tests run
# with `xcrun xctest` on the built bundle: under xcodebuild, with derived data outside ~/Documents, the
# test process cannot read this repository (EPERM), and the same bundle run directly can.
#
# The SpringBoard tests lock and unlock the simulated iPhone only. Nothing here installs anywhere but the
# simulator, and nothing signs with more than the wildcard development profile.

set -u
cd "${0:A:h:h}" || exit 1
DD=${DD:-/Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsideIntegrations}
OUT=${OUT:-/tmp/farside-verify}
SIM=${SIM:-}
mkdir -p "$OUT"
summary=$OUT/summary.txt
: > "$summary"

xb() {
  local name=$1; shift
  print "$name started $(date +%H:%M:%S)" >> "$summary"
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -collect-test-diagnostics never "$@" > "$OUT/$name.log" 2>&1
  local rc=$?
  print "$name exit=$rc finished $(date +%H:%M:%S)" >> "$summary"
  grep -E "\*\* (BUILD|TEST|TEST BUILD) (SUCCEEDED|FAILED)|Executed [0-9]+ tests?, with|Provisioning Profile:|Signing Identity:" "$OUT/$name.log" | sort -u | tail -5 >> "$summary"
  grep -E "\.swift:[0-9]+: error|error: -\[" "$OUT/$name.log" | sort -u | head -8 | cut -c1-300 >> "$summary"
  return $rc
}

need_sim() { [ -n "$SIM" ] || { print "SIM=<simulator udid> is required for this step" >&2; exit 2; } }

step_device() {
  xb device -scheme PocketDeskRemote -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=YES build
}
step_host() {
  xb host -scheme PocketDeskRemoteHost -destination platform=macOS -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build
}
step_core() {
  xb core-build -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath "$DD" build-for-testing || return
  lockf -k /tmp/farside-xcodebuild.lock xcrun xctest "$DD/Build/Products/Debug/RemoteCoreTests.xctest" > "$OUT/core-tests.log" 2>&1
  local rc=$?
  print "core tests (xctest) exit=$rc" >> "$summary"
  grep -E "Executed [0-9]+ tests?, with" "$OUT/core-tests.log" | tail -1 >> "$summary"
  return $rc
}
step_host_ui() {
  mkdir -p "$OUT/host-snapshots"
  export TEST_RUNNER_POCKETDESK_SNAPSHOT_DIR="$OUT/host-snapshots"
  xb host-ui -scheme HostUISnapshotTests -destination platform=macOS -derivedDataPath "$DD" test
  local rc=$?
  unset TEST_RUNNER_POCKETDESK_SNAPSHOT_DIR
  return $rc
}
step_unit() {
  need_sim
  xb unit -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" \
    -only-testing:RemotePhoneTests -resultBundlePath "$OUT/unit.xcresult" test
}
step_routing() {
  need_sim
  xb build-for-testing -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" build-for-testing || return
  zsh script/push-samples/verify-routing.sh "$SIM" "$DD" agent-needs-you agent-needs-you-unknown-agent \
    agent-malformed-id agent-wrong-category agent-needs-you:actions > "$OUT/routing.log" 2>&1
  local rc=$?
  print "routing exit=$rc" >> "$summary"
  grep -E "^==|   ok|FAILED|failures:|never became ready" "$OUT/routing.log" >> "$summary"
  return $rc
}
step_springboard() {
  need_sim
  export TEST_RUNNER_FARSIDE_SPRINGBOARD=1
  xb springboard -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" \
    -only-testing:RemotePhoneUITests/LiveActivityUITests -resultBundlePath "$OUT/springboard.xcresult" test
  local rc=$?
  unset TEST_RUNNER_FARSIDE_SPRINGBOARD
  return $rc
}
step_ui_all() {
  need_sim
  xb ui-all -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" \
    -only-testing:RemotePhoneUITests -resultBundlePath "$OUT/ui-all.xcresult" test
}

steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(device host core host-ui unit routing springboard ui-all)
for step in $steps; do
  case $step in
    device) step_device ;;
    host) step_host ;;
    core) step_core ;;
    host-ui) step_host_ui ;;
    unit) step_unit ;;
    routing) step_routing ;;
    springboard) step_springboard ;;
    ui-all) step_ui_all ;;
    *) print "unknown step: $step" >&2; exit 2 ;;
  esac
  result=$?
  if [ "$result" -ne 0 ]; then
    print "failed: $step (exit $result); see $summary" >&2
    exit "$result"
  fi
done
print "done: see $summary"
