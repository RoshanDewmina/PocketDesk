#!/bin/zsh
# Farside Anywhere (StoreKit) verification: build for testing, the Anywhere unit tests (SKTestSession,
# verify client, handshake, signaling), the paywall UI test, and the paywall screenshots.
#
#   SIM=<simulator udid> script/verify-storekit.sh [step ...]
#
#   steps  build unit ui shots   (default: all, in that order)
#   SIM    one iPhone simulator (required)
#   DD     derived data (default /Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsideStoreKit)
#   OUT    logs, result bundles and screenshots (default: timestamped /tmp/farside-storekit-*)
#
# Every xcodebuild takes the shared lock. Nothing installs outside the simulator.

set -u
cd "${0:A:h:h}" || exit 1
DD=${DD:-/Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsideStoreKit}
OUT=${OUT:-/tmp/farside-storekit-$(date +%Y%m%d-%H%M%S)}
SIM=${SIM:-}
[ -n "$SIM" ] || { print "SIM=<simulator udid> is required" >&2; exit 2; }
for name in build unit ui shots; do
  if [ -e "$OUT/$name.log" ] || [ -e "$OUT/$name.xcresult" ]; then
    print "Existing $name receipt in $OUT; choose a fresh OUT to preserve it" >&2
    exit 2
  fi
done
mkdir -p "$OUT"
summary=$OUT/summary.txt
: > "$summary"

xb() {
  local name=$1; shift
  print "$name started $(date +%H:%M:%S)" >> "$summary"
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote \
    -destination "id=$SIM" -derivedDataPath "$DD" -parallel-testing-enabled NO \
    -collect-test-diagnostics never "$@" > "$OUT/$name.log" 2>&1
  local rc=$?
  print "$name exit=$rc finished $(date +%H:%M:%S)" >> "$summary"
  grep -E "\*\* (BUILD|TEST|TEST BUILD|TEST EXECUTE) (SUCCEEDED|FAILED)|Executed [0-9]+ tests?, with" "$OUT/$name.log" | sort -u | tail -4 >> "$summary"
  grep -E "\.swift:[0-9]+: error" "$OUT/$name.log" | sort -u | head -8 | cut -c1-300 >> "$summary"
  return $rc
}

step_build() { xb build build-for-testing; }
step_unit() {
  xb unit test-without-building -resultBundlePath "$OUT/unit.xcresult" \
    -only-testing:RemotePhoneTests/AnywhereEntitlementTests -only-testing:RemotePhoneTests/EntitlementClientTests \
    -only-testing:RemotePhoneTests/AnywhereAccessTests -only-testing:RemotePhoneTests/AnywhereStoreKitTests
}
step_ui() {
  xb ui test-without-building -resultBundlePath "$OUT/ui.xcresult" -only-testing:RemotePhoneUITests/AnywherePaywallUITests
}
step_shots() {
  mkdir -p "$OUT/shots"
  TEST_RUNNER_FARSIDE_SNAPSHOT_DIR="$OUT/shots" xb shots test-without-building -resultBundlePath "$OUT/shots.xcresult" \
    -only-testing:RemotePhoneTests/AnywhereStoreKitTests/testCapturePaywallScreens
  local rc=$?
  [ $rc -eq 0 ] || return $rc
  ls "$OUT/shots" >> "$summary" 2>/dev/null
}

steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(build unit ui shots)
for step in $steps; do
  case $step in
    build) step_build || exit $? ;;
    unit) step_unit || exit $? ;;
    ui) step_ui || exit $? ;;
    shots) step_shots || exit $? ;;
    *) print "unknown step: $step" >&2; exit 2 ;;
  esac
done
print "done: see $summary"
