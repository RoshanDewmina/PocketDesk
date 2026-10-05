#!/bin/zsh
# Deliver each sample payload with `xcrun simctl push` while a push UI test waits, tap the real
# notification banner, and check that the alert sheet opens for the right agent or, for the invalid
# samples, that nothing routes. `<sample>:snooze` and `<sample>:not-now` long-press the banner,
# check that both actions are offered, choose the named action, and verify it opens nothing.
#
#   verify-routing.sh <simulator udid> <derived data dir> [sample[:snooze|not-now] ...]
#
# Build for testing first, into the same derived data directory:
#   lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote \
#     -destination "id=<udid>" -derivedDataPath <derived data dir> build-for-testing
#
# Every xcodebuild here is wrapped in the shared lock, as the other agents' runs are.

set -u
udid=${1:?usage: verify-routing.sh <simulator udid> <derived data dir> [sample[:snooze|not-now] ...]}
derived=${2:?usage: verify-routing.sh <simulator udid> <derived data dir> [sample[:snooze|not-now] ...]}
shift 2
here=${0:A:h}
root=${here:h:h}
bundle=com.roshan.PocketDesk.Remote
out=${FARSIDE_PUSH_OUT:-$root/work/system-acceptance/routing-$(date -u +%Y%m%dT%H%M%SZ)-$$}
mkdir -p "$out"

# sample : text on the banner : sheet expected : sheet heading
typeset -A banner sheet title
banner=(agent-needs-you "Claude Code needs you" agent-needs-you-active "Codex needs you"
        agent-needs-you-unknown-agent "An agent needs you" agent-malformed-id "Claude Code needs you"
        agent-wrong-category "A notification that is not an agent alert.")
sheet=(agent-needs-you yes agent-needs-you-active yes agent-needs-you-unknown-agent yes
       agent-malformed-id no agent-wrong-category no)
title=(agent-needs-you "Claude Code needs you." agent-needs-you-active "Codex needs you."
       agent-needs-you-unknown-agent "An agent needs you.")

samples=("$@")
[ ${#samples[@]} -gt 0 ] || samples=(agent-needs-you agent-needs-you-active agent-needs-you-unknown-agent
                                     agent-malformed-id agent-wrong-category agent-needs-you:snooze
                                     agent-needs-you:not-now)

failures=0
for spec in $samples; do
  name=${spec%%:*}
  mode=${spec#*:}
  [ "$mode" = "$spec" ] && mode=route
  if [ ! -r "$here/$name.apns" ] || [ -z "${banner[$name]:-}" ] || [ -z "${sheet[$name]:-}" ]; then
    print "== $spec"
    print "   FAILED: unknown or unreadable sample"
    failures=$((failures + 1))
    continue
  fi
  action=""
  case $mode in
    snooze|not-now)
      action=$mode
      only=RemotePhoneUITests/AgentAlertActionPushUITests/testTheSelectedBannerActionDismissesWithoutOpeningTheAlert
      ;;
    actions)
      print "== $spec"
      print "   FAILED: use :snooze and :not-now so each action is exercised"
      failures=$((failures + 1))
      continue
      ;;
    route)
      if [ "${sheet[$name]}" = no ]; then
        only=RemotePhoneUITests/AgentAlertInvalidPushUITests/testAnInvalidPushedAlertDismissesButRoutesNowhere
      else
        only=RemotePhoneUITests/AgentAlertPushUITests/testAPushedAlertRoutesToTheRightSheetOrNowhere
      fi
      ;;
    *)
      print "== $spec"
      print "   FAILED: unknown mode $mode"
      failures=$((failures + 1))
      continue
      ;;
  esac
  slug=${spec//:/-}
  ready=$(mktemp -u /tmp/farside-push-ready.XXXXXX)
  result="$out/$slug.xcresult"
  log="$out/$slug.log"
  print "== $name ($mode)"
  (
    cd "$root"
    export TEST_RUNNER_FARSIDE_PUSH_INJECTED=1
    export TEST_RUNNER_FARSIDE_PUSH_READY_FILE="$ready"
    export TEST_RUNNER_FARSIDE_PUSH_TAP_TEXT="${banner[$name]}"
    export TEST_RUNNER_FARSIDE_PUSH_EXPECT_SHEET="${sheet[$name]}"
    export TEST_RUNNER_FARSIDE_PUSH_EXPECT_TITLE="${title[$name]:-}"
    export TEST_RUNNER_FARSIDE_PUSH_ACTION_INJECTED="$([ -n "$action" ] && print 1 || print 0)"
    export TEST_RUNNER_FARSIDE_PUSH_ACTION="$action"
    lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote \
      -destination "id=$udid" -derivedDataPath "$derived" -resultBundlePath "$result" \
      -only-testing:$only test-without-building > "$log" 2>&1
  ) &
  runner=$!
  waited=0
  while [ ! -e "$ready" ] && kill -0 $runner 2>/dev/null && [ $waited -lt 300 ]; do sleep 1; waited=$((waited + 1)); done
  push_code=1
  if [ -e "$ready" ]; then
    xcrun simctl push "$udid" "$bundle" "$here/$name.apns"
    push_code=$?
    [ $push_code -eq 0 ] && print "   pushed $name.apns"
  else
    print "   the test never became ready (see $log)"
  fi
  # Always reap the lockf/xcodebuild controller. Killing only the shell wrapper here can orphan its
  # child and leave an untracked build on the shared Mac.
  wait $runner
  code=$?
  rm -f "$ready"
  if [ $code -eq 0 ] && [ $push_code -eq 0 ]; then
    print "   ok ($mode, sheet: ${sheet[$name]})"
  else
    print "   FAILED (push=$push_code test=$code); log: $log; result: $result"
    failures=$((failures + 1))
  fi
  print "   result bundle: $result"
done
print "failures: $failures"
exit $failures
