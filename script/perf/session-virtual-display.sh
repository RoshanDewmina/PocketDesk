#!/bin/zsh
# Bounded synthetic-content virtual-display capture. This script never builds or installs.
# Usage: script/perf/session-virtual-display.sh /path/to/Debug/PocketDeskRemoteHost.app
set -euo pipefail

ROOT=${0:A:h:h:h}
LANE_NAME=${FARSIDE_VDISPLAY_LANE:-b8-vdisplay}
[[ $LANE_NAME == b8-vdisplay || $LANE_NAME == b9-ipad-workspace ]] || { print -u2 -- "session-virtual-display: unsupported lane"; exit 2; }
export FARSIDE_VDISPLAY_LANE=$LANE_NAME
LANE=/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/$LANE_NAME
QUIET=/Users/roshansilva/Documents/Codex/2026-10-01/testing/QUIET-GRANTED-$LANE_NAME
BUNDLE_ID=com.roshan.PocketDesk.RemoteHost

fail() { print -u2 -- "session-virtual-display: $*"; exit 2 }
[[ $# == 1 ]] || fail "pass a built Debug PocketDeskRemoteHost.app path"
[[ -e $QUIET ]] || fail "missing exact quiet grant: $QUIET"
APP_INPUT=$1
[[ -d $APP_INPUT && ! -L $APP_INPUT ]] || fail "app bundle must be a real directory, not a symlink"
APP=${APP_INPUT:A}
[[ $APP == */Build/Products/Debug/PocketDeskRemoteHost.app ]] || fail "requires a Debug build product; installed and Release apps are refused"
[[ $APP != /Applications/* ]] || fail "installed apps are refused"
EXEC=$APP/Contents/MacOS/PocketDeskRemoteHost
[[ -x $EXEC ]] || fail "missing host executable: $EXEC"
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ $BUNDLE == $BUNDLE_ID ]] || fail "unexpected bundle identifier: $BUNDLE"
HARNESS_MARKER=0
GUARD_MARKER=0
for image in "$EXEC" "$EXEC.debug.dylib"; do
  if [[ -f $image ]]; then
    if /usr/bin/grep -q -a -F -- '--session-virtual-display-output' "$image"; then HARNESS_MARKER=1; fi
    if /usr/bin/grep -q -a -F -- '--session-virtual-display-window-guard' "$image"; then GUARD_MARKER=1; fi
  fi
done
(( HARNESS_MARKER && GUARD_MARKER )) || fail "Debug artifact is missing the session harness or window-guard marker"
EXECUTABLE=${EXEC:t}
for process_line in ${(f)"$(/bin/ps -ww -axo pid=,command=)"}; do
  process_pid=${process_line%% *}
  process_command=${process_line#* }
  if [[ $process_command == *PocketDeskRemoteHost* && $process_command == *--session-virtual-display* ]]; then
    fail "another marked virtual-display harness is already running (pid=$process_pid); leaving it untouched"
  fi
done

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
OUT=$LANE/runs/$RUN_ID
mkdir -p "$OUT"
BEFORE=$OUT/windows-before.json
LOG=$OUT/harness.log
CHILD_PID=""
CHILD_START=""
GUARD_PID=""
GUARD_START=""
GUARD_ACTION_CURRENT=""
CLEANED=0
RESTORE_ERROR=""

owns_child() {
  [[ -n $CHILD_PID ]] || return 1
  /bin/kill -0 "$CHILD_PID" 2>/dev/null || return 1
  local process_start command
  process_start=$(/bin/ps -ww -p "$CHILD_PID" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  command=$(/bin/ps -ww -p "$CHILD_PID" -o command= 2>/dev/null || true)
  [[ $process_start == "$CHILD_START" && $command == *"$EXEC"* && \
     $command == *"--session-virtual-display"* && \
     $command == *"--session-virtual-display-output $OUT"* ]]
}

guard_owns_child() {
  [[ -n $GUARD_PID && -n $GUARD_START ]] || return 1
  /bin/kill -0 "$GUARD_PID" 2>/dev/null || return 1
  local process_start command
  process_start=$(/bin/ps -ww -p "$GUARD_PID" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  command=$(/bin/ps -ww -p "$GUARD_PID" -o command= 2>/dev/null || true)
  [[ $process_start == "$GUARD_START" && $command == *"$EXEC"* && \
     $command == *"--session-virtual-display-window-guard $GUARD_ACTION_CURRENT $BEFORE"* ]]
}

run_guard() {
  local label=$1 guardResult=0 finished=0 quietMissing=0
  GUARD_ACTION_CURRENT=$label
  if [[ ! -e $QUIET ]]; then
    quietMissing=1
    RESTORE_ERROR="${RESTORE_ERROR}${RESTORE_ERROR:+; }quiet grant absent before guard ${label}"
    [[ $label != snapshot ]] || return 1
  fi
  "$EXEC" --session-virtual-display-window-guard "$GUARD_ACTION_CURRENT" "$BEFORE" > "$OUT/window-guard-${label}.log" 2>&1 &
  GUARD_PID=$!
  for _ in {1..3}; do
    GUARD_START=$(/bin/ps -ww -p "$GUARD_PID" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n $GUARD_START ]] && break
    sleep 0.1
  done
  if [[ -z $GUARD_START ]]; then
    for _ in {1..8}; do
      local state
      state=$(/bin/ps -p "$GUARD_PID" -o stat= 2>/dev/null || true)
      if [[ -z $state || $state == Z* ]]; then finished=1; break; fi
      sleep 1
    done
    if (( finished )); then wait "$GUARD_PID" || guardResult=$?; fi
    RESTORE_ERROR="${RESTORE_ERROR}${RESTORE_ERROR:+; }guard ${label} process start could not be pinned; result unverified"
    GUARD_PID=""; GUARD_START=""; GUARD_ACTION_CURRENT=""
    return 1
  fi
  for _ in {1..8}; do
    local state
    state=$(/bin/ps -p "$GUARD_PID" -o stat= 2>/dev/null || true)
    if [[ -z $state || $state == Z* ]]; then finished=1; break; fi
    if [[ ! -e $QUIET ]]; then
      if (( ! quietMissing )); then
        RESTORE_ERROR="${RESTORE_ERROR}${RESTORE_ERROR:+; }quiet grant withdrawn during guard ${label}"
        quietMissing=1
      fi
      [[ $label != snapshot ]] || break
    fi
    sleep 1
  done
  if (( ! finished )); then
    if guard_owns_child; then
      /bin/kill -TERM "$GUARD_PID" 2>/dev/null || true
      for _ in {1..1}; do
        local state
        state=$(/bin/ps -p "$GUARD_PID" -o stat= 2>/dev/null || true)
        [[ -z $state || $state == Z* ]] && break
        sleep 1
      done
      if guard_owns_child; then /bin/kill -KILL "$GUARD_PID" 2>/dev/null || true; fi
    fi
    RESTORE_ERROR="${RESTORE_ERROR}${RESTORE_ERROR:+; }guard ${label} exceeded 8 seconds; result unverified"
  else
    wait "$GUARD_PID" || guardResult=$?
    if (( guardResult != 0 )); then
      RESTORE_ERROR="${RESTORE_ERROR}${RESTORE_ERROR:+; }guard ${label} exited ${guardResult}"
    fi
  fi
  GUARD_PID=""; GUARD_START=""; GUARD_ACTION_CURRENT=""
  if [[ ! -e $QUIET ]] && (( ! quietMissing )); then
    RESTORE_ERROR="${RESTORE_ERROR}${RESTORE_ERROR:+; }quiet grant absent after guard ${label}"
    quietMissing=1
  fi
  (( finished && guardResult == 0 ))
}

cleanup() {
  (( CLEANED )) && return 0
  CLEANED=1
  trap '' INT TERM HUP
  if guard_owns_child; then
    /bin/kill -TERM "$GUARD_PID" 2>/dev/null || true
    for _ in {1..2}; do
      local state
      state=$(/bin/ps -p "$GUARD_PID" -o stat= 2>/dev/null || true)
      [[ -z $state || $state == Z* ]] && break
      sleep 1
    done
    if guard_owns_child; then /bin/kill -KILL "$GUARD_PID" 2>/dev/null || true; fi
    RESTORE_ERROR="${RESTORE_ERROR}${RESTORE_ERROR:+; }guard interrupted during signal cleanup"
    GUARD_PID=""; GUARD_START=""; GUARD_ACTION_CURRENT=""
  fi
  if owns_child; then
    /bin/kill -INT "$CHILD_PID" 2>/dev/null || true
    for _ in {1..6}; do
      local state
      state=$(/bin/ps -p "$CHILD_PID" -o stat= 2>/dev/null || true)
      [[ -z $state || $state == Z* ]] && break
      sleep 1
    done
    if owns_child; then
      print -u2 -- "session-virtual-display: bounded cleanup sending TERM only to own harness pid=$CHILD_PID"
      /bin/kill -TERM "$CHILD_PID" 2>/dev/null || true
      for _ in {1..6}; do
        local state
        state=$(/bin/ps -p "$CHILD_PID" -o stat= 2>/dev/null || true)
        [[ -z $state || $state == Z* ]] && break
        sleep 1
      done
      if owns_child; then /bin/kill -KILL "$CHILD_PID" 2>/dev/null || true; fi
    fi
  fi
  if [[ -s $BEFORE ]]; then
    run_guard restore || true
    run_guard verify || true
  else
    RESTORE_ERROR="${RESTORE_ERROR}${RESTORE_ERROR:+; }baseline snapshot missing; no state restoration could be verified"
    print -u2 -- "session-virtual-display: cleanup failure: $RESTORE_ERROR"
  fi
  [[ -z $RESTORE_ERROR ]] || print -u2 -- "session-virtual-display: restoration failed: $RESTORE_ERROR (see $OUT/window-guard-*.log)"
  print -- "session-virtual-display: receipts=$OUT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ -e $QUIET ]] || fail "quiet grant was withdrawn before snapshot"
run_guard snapshot || fail "bounded window-guard snapshot failed; inspect $OUT/window-guard-snapshot.log"
[[ -s $BEFORE ]] || fail "window guard reported snapshot success without an immutable journal"
[[ -e $QUIET ]] || fail "quiet grant was withdrawn before launch"

print -- "session-virtual-display: launching own Debug artifact pid will be scoped to run=$RUN_ID"
"$EXEC" --session-virtual-display --session-virtual-display-output "$OUT" > "$LOG" 2>&1 &
CHILD_PID=$!
CHILD_START=$(/bin/ps -ww -p "$CHILD_PID" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
[[ -n $CHILD_START ]] || fail "could not pin child process start time; refusing unscoped cleanup"
print -- "session-virtual-display: child=$CHILD_PID output=$OUT"

finished=0
for _ in {1..55}; do
  CHILD_STATE=$(/bin/ps -p "$CHILD_PID" -o stat= 2>/dev/null || true)
  if [[ -z $CHILD_STATE || $CHILD_STATE == Z* ]]; then finished=1; break; fi
  if [[ ! -e $QUIET ]]; then print -u2 -- "session-virtual-display: quiet grant withdrawn"; break; fi
  sleep 1
done
if (( ! finished )); then
  cleanup
  fail "harness exceeded 55 seconds or lost its quiet grant"
fi
APP_STATUS=0
wait "$CHILD_PID" || APP_STATUS=$?
CHILD_PID=""
[[ -e $QUIET ]] || fail "quiet grant was withdrawn before receipt acceptance"
[[ $APP_STATUS == 0 ]] || fail "harness exited with status $APP_STATUS; see $LOG"
[[ -s $OUT/metrics.json ]] || fail "metrics.json missing; see $LOG"
/usr/bin/grep -q 'SESSION-VD-HARNESS: complete' "$LOG" || fail "no complete harness receipt; see $LOG"
cleanup
[[ -z $RESTORE_ERROR ]] || fail "window/display restoration failed: $RESTORE_ERROR (see $OUT/window-guard-*.log)"
trap - EXIT INT TERM HUP
SHOT_OUT=$LANE/shots/$RUN_ID
mkdir -p "$SHOT_OUT"
[[ -s $OUT/shots/physical-source-raw.png && -s $OUT/shots/physical-phone-fill-baseline.png && \
   -s $OUT/shots/side-by-side.png && -s $OUT/shots/iphone17-portrait.png && \
   -s $OUT/shots/iphone17-landscape.png && -s $OUT/shots/ipad-air-5.png ]] || fail "one or more synthetic screenshot receipts are missing"
/bin/cp -p "$OUT"/shots/*.png "$SHOT_OUT"/
print -- "session-virtual-display: complete metrics=$OUT/metrics.json screenshots=$SHOT_OUT"
