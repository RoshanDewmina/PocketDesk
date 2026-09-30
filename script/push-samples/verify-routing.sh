#!/bin/zsh
# Deliver each sample payload with `xcrun simctl push` while a push UI test waits, tap the real
# notification banner, and check that the alert sheet opens for the right agent or, for the invalid
# samples, that nothing routes. `<sample>:actions` instead long-presses the banner and checks that
# Snooze and Not now are offered and open nothing.
#
#   verify-routing.sh <simulator udid> <derived data dir> [sample[:actions] ...]
#
# Build for testing first, into the same derived data directory:
#   lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote \
#     -destination "id=<udid>" -derivedDataPath <derived data dir> build-for-testing
#
# Every xcodebuild here is wrapped in the shared lock, as the other agents' runs are.

set -u
udid=${1:?usage: verify-routing.sh <simulator udid> <derived data dir> [sample[:actions] ...]}
derived=${2:?usage: verify-routing.sh <simulator udid> <derived data dir> [sample[:actions] ...]}
shift 2
here=${0:A:h}
root=${here:h:h}
bundle=com.roshan.PocketDesk.Remote

# sample : text on the banner : sheet expected : sheet heading
typeset -A banner sheet title
# Every alert has the same fixed title; the unknown-agent sample is an old-format push whose stray
# title-loc-args must never reach the screen.
generic="A task on your Mac needs you"
banner=(agent-needs-you "$generic" agent-needs-you-active "$generic"
        agent-needs-you-unknown-agent "$generic" agent-malformed-id "$generic"
        agent-wrong-category "A notification that is not an agent alert.")
sheet=(agent-needs-you yes agent-needs-you-active yes agent-needs-you-unknown-agent yes
       agent-malformed-id no agent-wrong-category no)
title=(agent-needs-you "$generic." agent-needs-you-active "$generic."
       agent-needs-you-unknown-agent "$generic.")

samples=("$@")
[ ${#samples[@]} -gt 0 ] || samples=(agent-needs-you agent-needs-you-active agent-needs-you-unknown-agent agent-malformed-id agent-wrong-category agent-needs-you:actions)

failures=0
for spec in $samples; do
  name=${spec%%:*}
  mode=${spec#*:}
  [ "$mode" = "$spec" ] && mode=route
  case $mode in
    actions) only=RemotePhoneUITests/AgentAlertPushUITests/testTheBannerOffersSnoozeAndNotNowWithoutOpeningTheAlert ;;
    *) only=RemotePhoneUITests/AgentAlertPushUITests/testAPushedAlertRoutesToTheRightSheetOrNowhere ;;
  esac
  ready=$(mktemp -u /tmp/farside-push-ready.XXXXXX)
  result=$(mktemp -d /tmp/farside-push-result.XXXXXX)/routing.xcresult
  log=$(mktemp /tmp/farside-push-log.XXXXXX)
  print "== $name ($mode)"
  (
    cd "$root"
    export TEST_RUNNER_FARSIDE_PUSH_INJECTED=1
    export TEST_RUNNER_FARSIDE_PUSH_READY_FILE="$ready"
    export TEST_RUNNER_FARSIDE_PUSH_TAP_TEXT="${banner[$name]}"
    export TEST_RUNNER_FARSIDE_PUSH_EXPECT_SHEET="${sheet[$name]}"
    export TEST_RUNNER_FARSIDE_PUSH_EXPECT_TITLE="${title[$name]:-}"
    lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote \
      -destination "id=$udid" -derivedDataPath "$derived" -resultBundlePath "$result" \
      -only-testing:$only test-without-building > "$log" 2>&1
  ) &
  runner=$!
  waited=0
  while [ ! -e "$ready" ] && kill -0 $runner 2>/dev/null && [ $waited -lt 1800 ]; do sleep 1; waited=$((waited + 1)); done
  if [ -e "$ready" ]; then
    xcrun simctl push "$udid" "$bundle" "$here/$name.apns" && print "   pushed $name.apns"
  else
    print "   the test never became ready (see $log)"
  fi
  wait $runner
  code=$?
  rm -f "$ready"
  if [ $code -eq 0 ]; then
    print "   ok ($mode, sheet: ${sheet[$name]})"
  else
    print "   FAILED (exit $code); log: $log; result: $result"
    failures=$((failures + 1))
  fi
  print "   result bundle: $result"
done
print "failures: $failures"
exit $failures
