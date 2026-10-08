#!/bin/zsh
# Farside physical-iPhone UI tests against this Mac's installed host. Built so a run cannot stall on a
# locked iPhone and cannot type into this Mac while someone is using it.
#   script/physical/run.sh --dry-run        # pre-flight verdict only: builds, installs and sends nothing
#   script/physical/run.sh                  # read-only tests (they send no input to the Mac)
#   script/physical/run.sh --mac-input      # also the Mac-input tests (refused until the idle check is verified)
#   script/physical/run.sh --features       # also the tests that need the Mac prepared by feature-tests/driver.py
# Notes: ~/Documents/Codex/2026-10-07/latency-ideas/plan2/impl/claude-device-test-runner.md
set -uo pipefail
setopt NULL_GLOB EXTENDED_GLOB
zmodload zsh/datetime

ORIGINAL_ARGS=("$@")
SCRIPT_DIR=${0:A:h}
REPO=${SCRIPT_DIR:h:h}
TARGET=FarsidePhysicalLifecycleUITests
TEAM=39HM2X8GS6
MAC_INPUT_BASE=PhysicalMacInputTestCase
PREFLIGHT_CLASS=PhysicalPreflightTests
PREFLIGHT_TEST=testAutomationReady
# Classes reviewed to send no input to the Mac. A class that is neither listed here nor a
# PhysicalMacInputTestCase subclass is never run.
READ_ONLY_CLASSES=(PhysicalLifecycleSmokeTests PhysicalFeatureTests)
# Read-only classes that need the Mac prepared by feature-tests/driver.py and read its real clipboard or
# screen; they run only with --features.
FEATURE_CLASSES=(PhysicalMacFixtureFeatureTests)
MIN_IDLE=120
# HIDIdleTime may also count the host's own injected events (unverified; checking needs input on this Mac).
# If it does, it cannot tell Roshan's hand from the test's, so live --mac-input runs stay refused until a
# supervised check proves otherwise or an idle source that excludes our events replaces it.
MAC_INPUT_IDLE_SOURCE_VERIFIED=0
# Host SIGSTOP on a Mac-input trip stays below the watchdog's shortest hang timeout (6 s with the curtain
# up, RemoteHost/HostWatchdogState.swift:141), so a pause can never get the host killed and relaunched.
HOST_PAUSE_LIMIT=4
PHONE_STATE='Unlock .* to Continue|the device is locked|Device is locked|Not authorized for performing UI testing actions|Timed out while enabling automation mode|Enable UI Automation'
AUTO_LOCK_ADVICE="Set the iPhone's Auto-Lock to Never while testing (Settings > Display & Brightness > Auto-Lock) and back afterwards."

ROOT=/private/tmp/farside-physical
SOURCES=$REPO/RemotePhysicalUITests
DEVICECTL=(xcrun devicectl)
XCODEBUILD=(xcodebuild)
IOREG=/usr/sbin/ioreg
XCB_LOCK=/tmp/farside-xcodebuild.lock
HOST_PROCESS=PocketDeskRemoteHost
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/FarsidePhysical"
DEVICE_LIMIT=60
PROBE_LIMIT=150
READ_ONLY_LIMIT=480
READ_ONLY_PER_TEST=150
MAC_INPUT_LIMIT=360
IDLE_WAIT_LIMIT=600
BUILD_LIMIT=2700
LOCK_POLL_INTERVAL=20
POLL=0.25
TEST_MODE=0
# Seams for script/tests/test_physical_runner.py, honoured only when xcodebuild itself is faked, so a real
# run can never be pointed at a fake ioreg or devicectl.
if [[ -n ${FARSIDE_RUNNER_XCODEBUILD:-} ]]; then
  TEST_MODE=1
  XCODEBUILD=(${=FARSIDE_RUNNER_XCODEBUILD})
  ROOT=${FARSIDE_RUNNER_ROOT:-$ROOT}
  SOURCES=${FARSIDE_RUNNER_TEST_SOURCES:-$SOURCES}
  DEVICECTL=(${=FARSIDE_RUNNER_DEVICECTL:-xcrun devicectl})
  IOREG=${FARSIDE_RUNNER_IOREG:-$IOREG}
  HOST_PROCESS=${FARSIDE_RUNNER_HOST_PROCESS:-$HOST_PROCESS}
  DERIVED=${FARSIDE_RUNNER_DERIVED:-$DERIVED}
  XCB_LOCK=$ROOT/xcodebuild.lock
  DEVICE_LIMIT=${FARSIDE_RUNNER_DEVICE_LIMIT:-$DEVICE_LIMIT}
  PROBE_LIMIT=${FARSIDE_RUNNER_PROBE_LIMIT:-$PROBE_LIMIT}
  READ_ONLY_LIMIT=${FARSIDE_RUNNER_READ_ONLY_LIMIT:-$READ_ONLY_LIMIT}
  READ_ONLY_PER_TEST=${FARSIDE_RUNNER_READ_ONLY_PER_TEST:-0}
  MAC_INPUT_LIMIT=${FARSIDE_RUNNER_MAC_INPUT_LIMIT:-$MAC_INPUT_LIMIT}
  IDLE_WAIT_LIMIT=${FARSIDE_RUNNER_IDLE_WAIT_LIMIT:-$IDLE_WAIT_LIMIT}
  LOCK_POLL_INTERVAL=${FARSIDE_RUNNER_LOCK_POLL_INTERVAL:-$LOCK_POLL_INTERVAL}
fi

mkdir -p -m 700 "$ROOT"
# One run at a time; a second invocation exits 75. The re-exec marker counts only while the lock is held.
if [[ -z ${FARSIDE_RUNNER_LOCKED:-} ]] || /usr/bin/lockf -k -t 0 "$ROOT/run.lock" /usr/bin/true 2>/dev/null; then
  export FARSIDE_RUNNER_LOCKED=1
  exec /usr/bin/lockf -k -t 0 "$ROOT/run.lock" /bin/zsh "$0" "${ORIGINAL_ARGS[@]}"
fi
unset FARSIDE_RUNNER_LOCKED
# Test gates reach the iPhone only from this script, per phase; nothing is inherited from the caller.
for name in ${(k)parameters[(I)TEST_RUNNER_*]} ${(k)parameters[(I)FARSIDE_PHYSICAL_*]}; do unset $name; done
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

usage() {
  cat <<'EOF'
Usage: script/physical/run.sh [options]

  --dry-run            Check the Mac and the iPhone and print what would run. Builds, installs and
                       launches nothing, and sends nothing to the iPhone's UI or to this Mac.
  --mac-input          Also run the tests that click and type on this Mac (PhysicalMacInputTestCase
                       subclasses). Refused in live runs until the Mac idle check is verified (see the
                       notes). When enabled: typed by a person at this Mac and confirmed on its keyboard;
                       each test runs alone, only after nobody has touched this Mac for 120 s, and is
                       stopped the moment the keyboard, mouse or trackpad is used.
  --features           Also run the tests that need this Mac prepared by feature-tests/driver.py
                       (FEATURE_CLASSES, and Mac-input tests that check for it). They read this Mac's
                       real clipboard and screen, so a plain run leaves them out.
  --only ID            Run only Class or Class/testMethod (repeatable).
  --device NAME|UDID   The iPhone to use (default: the one paired iPhone with Developer Mode on).
  --skip-build         Reuse the build products in the derived-data folder.
  --derived-data PATH  Default ~/Library/Developer/Xcode/DerivedData/FarsidePhysical.
Exit: 0 passed, 1 a test failed, 2 usage/refused/cancelled, 3 not ready (one instruction printed),
      4 stopped because this Mac was used or locked during a Mac-input test, 5 a time limit ran out,
      75 another run is active.
EOF
}

DRY_RUN=0
MAC_INPUT=0
FEATURES=0
SKIP_BUILD=0
DEVICE_ARG=""
ONLY=()
need_value() { (( $1 >= 2 )) || { print -u2 -r -- "$2 needs a value"; usage >&2; exit 2 } }
while (( $# )); do
  case $1 in
    --dry-run) DRY_RUN=1; shift ;;
    --mac-input) MAC_INPUT=1; shift ;;
    --features) FEATURES=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --device) need_value $# $1; DEVICE_ARG=$2; shift 2 ;;
    --only) need_value $# $1; ONLY+=($2); shift 2 ;;
    --derived-data) need_value $# $1; DERIVED=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
done
for item in $ONLY; do
  [[ $item == [A-Za-z_][A-Za-z0-9_]#(/test[A-Za-z0-9_]#|) ]] || { print -u2 "--only takes Class or Class/testMethod, got: $item"; exit 2 }
done

RUN_STAMP=$(date +%Y%m%dT%H%M%S)
RUN="$ROOT/runs/$RUN_STAMP-$$"
mkdir -p -m 700 "$RUN"
RUN_LOG="$RUN/run.log"
RESULTS=()
UDID=""
CURRENT_PID=""
CAFFEINATE_PID=""
LAST_IDLE_MS=0
STOP_KIND=""
STOP_REASON=""
IN_MAC_INPUT=0
HOST_PAUSED=()
LOCK_POLL_PID=""
LOCK_POLL_STARTED=0
LOCK_POLL_FILE=""
NEXT_LOCK_POLL=0

log() { print -r -- "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG" >&2 }
# The last line on stdout is the outcome, written for Roshan: what happened and the one thing to do.
finish() {
  local code=$1; shift
  if (( $#RESULTS )); then log "Results:"; for line in $RESULTS; do log "  $line"; done; fi
  log "Logs: $RUN"
  print -r -- "$*" | tee -a "$RUN_LOG"
  exit $code
}

# MARK: Bounded processes

kill_tree() {
  local sig=$1 pid=$2 child
  for child in $(/usr/bin/pgrep -P $pid 2>/dev/null); do kill_tree $sig $child; done
  kill -$sig $pid 2>/dev/null
}

reap() {
  local pid=${1:-} tenths=50
  [[ -n $pid ]] || return 0
  while (( tenths-- > 0 )) && kill -0 $pid 2>/dev/null; do sleep 0.1; done
  kill -0 $pid 2>/dev/null && kill_tree KILL $pid
  wait $pid 2>/dev/null
  return 0
}

# run_bounded LIMIT LOG WATCH CMD...: 124 when LIMIT seconds pass, 125 when WATCH (a function given the
# log, or -) returns non-zero. Either way the command has been sent SIGTERM, since background jobs of a
# script ignore SIGINT; the caller reaps it.
run_bounded() {
  local limit=$1 out=$2 watch=$3; shift 3
  STOP_KIND=""; STOP_REASON=""
  NEXT_LOCK_POLL=$(( EPOCHREALTIME + LOCK_POLL_INTERVAL ))
  "$@" > "$out" 2>&1 < /dev/null &
  CURRENT_PID=$!
  local pid=$CURRENT_PID start=$EPOCHREALTIME
  while kill -0 $pid 2>/dev/null; do
    if (( EPOCHREALTIME - start > limit )); then
      STOP_KIND=timeout; STOP_REASON="no result after ${limit%.*} s"
      kill_tree TERM $pid; end_lock_poll; return 124
    fi
    if [[ $watch != - ]] && ! $watch "$out"; then kill_tree TERM $pid; end_lock_poll; return 125; fi
    sleep $POLL
  done
  end_lock_poll
  CURRENT_PID=""
  wait $pid
}

stop_current() { local pid=$CURRENT_PID; CURRENT_PID=""; reap "$pid" }

# MARK: Mac checks

screen_locked() {
  $IOREG -n Root -d1 -a 2>/dev/null | /usr/bin/plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw - 2>/dev/null | grep -q true
}

# Milliseconds since the last keyboard, mouse or trackpad event, from IOHIDSystem's HIDIdleTime (ns).
hid_idle_ms() {
  local ns
  ns=$($IOREG -r -c IOHIDSystem -d 1 2>/dev/null | awk '/"HIDIdleTime" = / {print $NF; exit}')
  [[ $ns == <-> ]] || return 1
  print $(( ns / 1000000 ))
}

pause_host() {
  HOST_PAUSED=($(/usr/bin/pgrep -x $HOST_PROCESS 2>/dev/null))
  (( $#HOST_PAUSED )) || return 0
  kill -STOP $HOST_PAUSED 2>/dev/null
  log "Paused $HOST_PROCESS (pid ${(j:, :)HOST_PAUSED}) so no more input reaches this Mac"
}

resume_host() {
  (( $#HOST_PAUSED )) || return 0
  kill -CONT $HOST_PAUSED 2>/dev/null
  log "Resumed $HOST_PROCESS (pid ${(j:, :)HOST_PAUSED})"
  HOST_PAUSED=()
}

# MARK: iPhone lock state

lock_verdict() {
  /usr/bin/jq -r '[.result | .. | objects | to_entries[] | select(.value | type == "boolean") | {k: (.key | ascii_downcase), v: .value}
      | select(.k == "passcoderequired" or .k == "islocked" or .k == "locked" or .k == "devicelocked" or .k == "unlockedsinceboot")
      | if .k == "unlockedsinceboot" then (.v | not) else .v end]
    | if length == 0 then "unknown" elif any then "locked" else "unlocked" end' "$1" 2>/dev/null || print unknown
}

end_lock_poll() {
  [[ -n $LOCK_POLL_PID ]] || return 0
  kill_tree TERM $LOCK_POLL_PID
  wait $LOCK_POLL_PID 2>/dev/null
  LOCK_POLL_PID=""
}

# Every LOCK_POLL_INTERVAL s while a test runs, ask the iPhone for its lock state in the background, so an
# auto-lock is caught even when xcodebuild prints nothing. Returns 1 when a finished poll says locked.
lock_poll() {
  [[ -n $UDID ]] || return 0
  if [[ -n $LOCK_POLL_PID ]]; then
    if kill -0 $LOCK_POLL_PID 2>/dev/null; then
      (( EPOCHREALTIME - LOCK_POLL_STARTED > 30 )) && end_lock_poll
      return 0
    fi
    wait $LOCK_POLL_PID 2>/dev/null
    LOCK_POLL_PID=""
    if [[ -s $LOCK_POLL_FILE && $(lock_verdict "$LOCK_POLL_FILE") == locked ]]; then
      STOP_KIND=phone; STOP_REASON="the iPhone locked"
      return 1
    fi
  fi
  (( EPOCHREALTIME >= NEXT_LOCK_POLL )) || return 0
  LOCK_POLL_FILE="$RUN/lockpoll-$EPOCHSECONDS.json"
  $DEVICECTL device info lockState --device $UDID --timeout 15 --json-output "$LOCK_POLL_FILE" --quiet > /dev/null 2>&1 < /dev/null &
  LOCK_POLL_PID=$! LOCK_POLL_STARTED=$EPOCHREALTIME
  NEXT_LOCK_POLL=$(( EPOCHREALTIME + LOCK_POLL_INTERVAL ))
}

phone_watch() {
  local hit
  if hit=$(grep -m1 -oE "$PHONE_STATE" "$1" 2>/dev/null); then STOP_KIND=phone; STOP_REASON=$hit; return 1; fi
  lock_poll
}

mac_input_watch() {
  phone_watch "$1" || return 1
  if screen_locked; then STOP_KIND=maclocked; STOP_REASON="this Mac's screen locked"; return 1; fi
  local now
  if ! now=$(hid_idle_ms); then STOP_KIND=human; STOP_REASON="this Mac's input idle time could not be read"; return 1; fi
  if (( now + 500 < LAST_IDLE_MS )); then
    STOP_KIND=human
    STOP_REASON="this Mac's keyboard, mouse or trackpad was used (idle fell from $(( LAST_IDLE_MS / 1000 )) s to $(( now / 1000 )) s)"
    return 1
  fi
  LAST_IDLE_MS=$now
}

phone_instruction() {
  case $STOP_REASON in
    (*uthoriz*|*utomation*) print -r -- "Unlock the iPhone and run this again; if the iPhone asks for its passcode to allow UI automation, enter it." ;;
    ("the iPhone locked") print -r -- "Set the iPhone's Auto-Lock to Never (Settings > Display & Brightness > Auto-Lock), unlock it, and run this again." ;;
    (*) print -r -- "Unlock the iPhone and leave it on the Home Screen, then run this again." ;;
  esac
}

# MARK: Test classification

typeset -A SUPER_OF TESTS_OF
CLASSES=()
MAC_INPUT_CLASSES=()
RO_SELECTED=()
MAC_SELECTED=()
UNCLASSIFIED=()

scan_sources() {
  local files=($SOURCES/*.swift)
  (( $#files )) || return 0
  awk '
    FNR == 1 { cls = "" }
    /^[[:space:]]*(\/\/|\/\*|\*)/ { next }
    match($0, /^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|internal|open|final|private|fileprivate)[[:space:]]+)*class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
      n = split(substr($0, RSTART, RLENGTH), w, /[[:space:]]+/); name = w[n]
      if (name != "func" && name != "var" && name != "let") {
        rest = substr($0, RSTART + RLENGTH); sup = "-"
        if (match(rest, /^[[:space:]]*:[[:space:]]*[A-Za-z_][A-Za-z0-9_.]*/)) { sup = substr(rest, RSTART, RLENGTH); gsub(/[[:space:]:]/, "", sup) }
        cls = name; print "class", cls, sup; next
      }
    }
    match($0, /^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|internal|private|fileprivate)[[:space:]]+)*extension[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
      n = split(substr($0, RSTART, RLENGTH), w, /[[:space:]]+/); cls = w[n]; next
    }
    cls != "" && match($0, /func[[:space:]]+test[A-Za-z0-9_]*[[:space:]]*\(\)/) {
      t = substr($0, RSTART, RLENGTH); sub(/^func[[:space:]]+/, "", t); sub(/[[:space:]]*\(\)$/, "", t)
      print "test", cls, t
    }
  ' $files
}

classify_tests() {
  local kind a b cls changed item t
  scan_sources | while read -r kind a b; do
    case $kind in
      class) SUPER_OF[$a]=$b; CLASSES+=($a) ;;
      test) TESTS_OF[$a]="${TESTS_OF[$a]:-} $b" ;;
    esac
  done
  typeset -A is_mac=()
  is_mac[$MAC_INPUT_BASE]=1
  changed=1
  while (( changed )); do
    changed=0
    for cls in $CLASSES; do
      [[ -z ${is_mac[$cls]:-} && -n ${is_mac[${SUPER_OF[$cls]}]:-} ]] && { is_mac[$cls]=1; changed=1 }
    done
  done
  for cls in ${(u)CLASSES}; do
    [[ -n ${TESTS_OF[$cls]:-} && $cls != $PREFLIGHT_CLASS ]] || continue
    if [[ -n ${is_mac[$cls]:-} ]]; then
      MAC_INPUT_CLASSES+=($cls)
      (( ${READ_ONLY_CLASSES[(Ie)$cls]} || ${FEATURE_CLASSES[(Ie)$cls]} )) && log "WARNING: $cls is listed as read-only but subclasses $MAC_INPUT_BASE; treating it as Mac input"
    elif (( ! ${READ_ONLY_CLASSES[(Ie)$cls]} && ! ${FEATURE_CLASSES[(Ie)$cls]} )); then
      UNCLASSIFIED+=($cls)
    fi
  done
  if (( $#ONLY )); then
    for item in $ONLY; do
      cls=${item%%/*}
      if [[ $item == */* ]] && [[ -n ${TESTS_OF[$cls]:-} ]] && (( ! ${${=TESTS_OF[$cls]}[(Ie)${item#*/}]} )); then
        finish 2 "REFUSED: $item does not exist (tests in $cls:${TESTS_OF[$cls]})."
      fi
      if (( ${MAC_INPUT_CLASSES[(Ie)$cls]} )); then
        if [[ $item == */* ]]; then MAC_SELECTED+=($item); else for t in ${=TESTS_OF[$cls]}; do MAC_SELECTED+=($cls/$t); done; fi
      elif (( ${READ_ONLY_CLASSES[(Ie)$cls]} )) && [[ -n ${TESTS_OF[$cls]:-} ]]; then
        RO_SELECTED+=($item)
      elif (( ${FEATURE_CLASSES[(Ie)$cls]} )) && [[ -n ${TESTS_OF[$cls]:-} ]]; then
        (( FEATURES )) || finish 2 "REFUSED: $cls needs this Mac prepared by feature-tests/driver.py and reads its real clipboard. Prepare it, then add --features."
        RO_SELECTED+=($item)
      else
        finish 2 "REFUSED: $cls is not a known physical test class. Classify it first: subclass $MAC_INPUT_BASE if any test clicks, types or pastes on the Mac; otherwise add it to READ_ONLY_CLASSES in script/physical/run.sh after checking that none does."
      fi
    done
  else
    for cls in $READ_ONLY_CLASSES; do [[ -n ${TESTS_OF[$cls]:-} ]] && RO_SELECTED+=($cls); done
    for cls in $FEATURE_CLASSES; do
      [[ -n ${TESTS_OF[$cls]:-} ]] || continue
      if (( FEATURES )); then RO_SELECTED+=($cls); else log "Skipping $cls; it needs this Mac prepared by feature-tests/driver.py and runs only with --features"; fi
    done
    for cls in $MAC_INPUT_CLASSES; do for t in ${=TESTS_OF[$cls]}; do MAC_SELECTED+=($cls/$t); done; done
  fi
  (( $#UNCLASSIFIED )) && log "WARNING: never run until classified (see READ_ONLY_CLASSES in this script): ${(j:, :)UNCLASSIFIED}"
  if (( $#MAC_SELECTED && ! MAC_INPUT )); then
    (( $#ONLY && ! $#RO_SELECTED )) && finish 2 "REFUSED: ${(j:, :)MAC_SELECTED} click or type on this Mac. Add --mac-input, typed by you at this Mac, to run them."
    log "Skipping ${#MAC_SELECTED} Mac-input test(s); they run only with --mac-input: ${(j:, :)MAC_SELECTED}"
    MAC_SELECTED=()
  fi
}

# MARK: Device checks

DEVICE_NAME=""
DEVICE_SUMMARY=""
LOCK_SUMMARY=""

check_device() {
  local deadline=$(( EPOCHREALTIME + DEVICE_LIMIT )) list="$RUN/devices.json" rc
  run_bounded 30 "$RUN/devicectl-list.log" - $DEVICECTL list devices --timeout 20 --json-output "$list" --quiet
  rc=$?; stop_current
  [[ $rc == 0 && -s $list ]] || finish 3 "NOT READY: this Mac could not list iPhones (devicectl: ${STOP_REASON:-exit $rc}). Plug the iPhone into this Mac with its cable, unlock it, and run this again."
  local -a rows=("${(@f)$(/usr/bin/jq -r '.result.devices[]? | select(.hardwareProperties.platform == "iOS" and .hardwareProperties.reality == "physical")
    | [.hardwareProperties.udid, .deviceProperties.name, .connectionProperties.pairingState, .deviceProperties.developerModeStatus,
       .connectionProperties.tunnelState, .identifier] | map(. // "unknown" | tostring) | join("\u001f")' "$list" 2>/dev/null)}")
  rows=(${rows:#})
  local -a picked=() ready=() connected=() f
  local row
  for row in $rows; do
    f=("${(@ps:\x1f:)row}")
    if [[ -n $DEVICE_ARG ]]; then
      [[ $DEVICE_ARG == "$f[1]" || $DEVICE_ARG == "$f[2]" || $DEVICE_ARG == "$f[6]" ]] && picked+=($row)
    else
      picked+=($row)
      [[ $f[3] == paired && $f[4] == enabled ]] && ready+=($row)
      [[ $f[3] == paired && $f[4] == enabled && $f[5] == connected ]] && connected+=($row)
    fi
  done
  if [[ -z $DEVICE_ARG ]]; then
    (( $#ready )) && picked=($ready)
    (( $#picked > 1 && $#connected == 1 )) && picked=($connected)
    (( $#picked > 1 )) && finish 2 "REFUSED: more than one iPhone is paired with this Mac. Pass --device with its name or UDID."
  fi
  (( $#picked )) || finish 3 "NOT READY: ${${DEVICE_ARG:+$DEVICE_ARG is not}:-no iPhone is} paired with this Mac. Plug the iPhone in with its cable, unlock it, tap Trust if it asks, and run this again."
  f=("${(@ps:\x1f:)picked[1]}")
  UDID=$f[1]; DEVICE_NAME=$f[2]
  DEVICE_SUMMARY="$DEVICE_NAME ($UDID) pairing ${f[3]}, Developer Mode ${f[4]}, tunnel ${f[5]}"
  log "iPhone: $DEVICE_SUMMARY"
  [[ $f[3] == paired ]] || finish 3 "NOT READY: $DEVICE_NAME is not paired with this Mac. Plug it in with its cable, unlock it, tap Trust, and run this again."
  [[ $f[4] == enabled ]] || finish 3 "NOT READY: Developer Mode is off on $DEVICE_NAME. Turn it on in Settings > Privacy & Security > Developer Mode, then run this again."
  local remaining=$(( deadline - EPOCHREALTIME ))
  (( remaining < 5 )) && remaining=5
  check_lock_state $remaining
}

# Field names in `devicectl device info lockState` JSON are pinned on the first real run; until then any
# recognisable boolean decides and the raw file stays in the run folder. The automation pre-flight is
# the authoritative check either way.
check_lock_state() {
  local limit=$1 json="$RUN/lockstate-$EPOCHSECONDS.json" rc
  run_bounded $limit "$RUN/devicectl-lockstate.log" - $DEVICECTL device info lockState --device $UDID --timeout 20 --json-output "$json" --quiet
  rc=$?; stop_current
  [[ $rc == 0 && -s $json ]] || finish 3 "NOT READY: $DEVICE_NAME did not answer within ${limit%.*} s. Unlock it, plug it into this Mac, and run this again."
  local fields=$(/usr/bin/jq -r '[.result | .. | objects | to_entries[] | select(.value | type == "boolean") | "\(.key)=\(.value)"] | unique | join(" ")' "$json" 2>/dev/null)
  local verdict=$(lock_verdict "$json")
  LOCK_SUMMARY="$verdict [${fields:-no boolean fields}]"
  log "iPhone lock state: $LOCK_SUMMARY"
  [[ $verdict == locked ]] && finish 3 "NOT READY: $DEVICE_NAME is locked. Unlock it and leave it on the Home Screen, then run this again."
  [[ $verdict == unlocked ]] || log "Lock state not recognised (raw JSON: $json); the automation pre-flight decides"
}

# Ends the UI-test runner and Farside on the iPhone: one listing, then every terminate at once, all bounded.
stop_device_processes() {
  [[ -n $UDID ]] || return 0
  local json="$RUN/processes-$EPOCHSECONDS.json" pid rc start
  local -a killers=()
  log "Ending the test runner and Farside on the iPhone"
  run_bounded 15 "$RUN/devicectl-processes.log" - $DEVICECTL device info processes --device $UDID --timeout 10 --json-output "$json" --quiet
  rc=$?; stop_current
  if [[ $rc != 0 ]]; then log "WARNING: could not list the iPhone's processes (${STOP_REASON:-exit $rc})"; return 0; fi
  for pid in $(/usr/bin/jq -r '.result.runningProcesses[]? | select((.executable // "") | test("/(FarsidePhysicalLifecycleUITests-Runner|PocketDeskRemote)\\.app/")) | .processIdentifier' "$json" 2>/dev/null); do
    $DEVICECTL device process terminate --device $UDID --pid $pid --kill --timeout 10 >> "$RUN/devicectl-terminate.log" 2>&1 < /dev/null &
    killers+=($!)
  done
  start=$EPOCHREALTIME
  for pid in $killers; do
    while kill -0 $pid 2>/dev/null && (( EPOCHREALTIME - start < 15 )); do sleep 0.1; done
    kill -0 $pid 2>/dev/null && kill_tree KILL $pid
    wait $pid 2>/dev/null
  done
}

# On a Mac-input trip: freeze the host first so nothing more reaches this Mac, end xcodebuild and the
# iPhone's processes, and resume the host within HOST_PAUSE_LIMIT seconds whatever happens.
emergency_stop() {
  local xcb=$1 start=$EPOCHREALTIME stopper
  pause_host
  [[ -n $xcb ]] && kill_tree TERM $xcb
  stop_device_processes &
  stopper=$!
  while kill -0 $stopper 2>/dev/null && (( EPOCHREALTIME - start < HOST_PAUSE_LIMIT )); do sleep 0.1; done
  resume_host
  while kill -0 $stopper 2>/dev/null && (( EPOCHREALTIME - start < 40 )); do sleep 0.1; done
  kill -0 $stopper 2>/dev/null && kill_tree KILL $stopper
  wait $stopper 2>/dev/null
  reap "$xcb"
}

# MARK: xcodebuild

XCB=(-project "$REPO/PocketDesktop.xcodeproj" -scheme $TARGET -configuration Debug -derivedDataPath "$DERIVED"
     -allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=$TEAM)
test_flags() {
  print -rl -- -destination "id=$UDID" -destination-timeout 30 -collect-test-diagnostics never \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 300
}
LOCKER=(/usr/bin/lockf -k $XCB_LOCK)
(( ! TEST_MODE )) && [[ -x $HOME/bin/farside-lock ]] && LOCKER=($HOME/bin/farside-lock)

# run_tests NAME LIMIT WATCH ENV... -- XCODEBUILD-ARGS...; leaves the log in LAST_LOG. The limit includes
# any wait for the shared xcodebuild lock.
LAST_LOG=""
run_tests() {
  local name=$1 limit=$2 watch=$3; shift 3
  local -a envs=()
  while [[ $1 != -- ]]; do envs+=($1); shift; done
  shift
  LAST_LOG="$RUN/$name.log"
  log "xcodebuild $name: env ${envs:-none} ${*}"
  run_bounded $limit "$LAST_LOG" $watch /usr/bin/lockf -k $XCB_LOCK /usr/bin/env $envs $XCODEBUILD test-without-building $XCB \
    "${(@f)$(test_flags)}" -resultBundlePath "$RUN/$name.xcresult" "$@"
}

# "executed skipped failures" from XCTest's last summary line, or nothing.
counts() {
  local line=$(grep -E 'Executed [0-9]+ tests?, with' "$1" 2>/dev/null | tail -1)
  [[ $line =~ 'Executed ([0-9]+) tests?, with (([0-9]+) tests? skipped and )?([0-9]+) failures?' ]] || return 1
  print -r -- "$match[1] ${match[3]:-0} $match[4]"
}

# MARK: Phases

phase_env() {
  print -r -- TEST_RUNNER_FARSIDE_PHYSICAL_LIFECYCLE_SMOKE=1
  (( FEATURES )) && print -r -- TEST_RUNNER_FARSIDE_PHYSICAL_FEATURES=1
  return 0
}

# The read-only phase is one xcodebuild run, so its limit grows with the number of selected tests.
read_only_limit() {
  local n=0 item
  for item in $RO_SELECTED; do
    if [[ $item == */* ]]; then (( n += 1 )); else (( n += ${#${=TESTS_OF[$item]}} )); fi
  done
  local scaled=$(( n * READ_ONLY_PER_TEST ))
  print $(( scaled > READ_ONLY_LIMIT ? scaled : READ_ONLY_LIMIT ))
}

confirm_mac_input() {
  [[ -t 0 && -t 1 ]] || finish 2 "REFUSED: --mac-input needs a person at this Mac's terminal; it never runs unattended or from a pipe."
  local minutes=$(( $#MAC_SELECTED * 4 )) answer="" idle
  print -r -- ""
  print -r -- "  This run will CLICK AND TYPE ON THIS MAC: ${#MAC_SELECTED} test(s), about $minutes minutes."
  print -r -- "  ${(j:, :)MAC_SELECTED}"
  print -r -- "  Before each test it waits until nobody has touched this Mac for $MIN_IDLE s, and it stops the"
  print -r -- "  moment the keyboard, mouse or trackpad is used. $AUTO_LOCK_ADVICE"
  print -r -- "  Then walk away from this Mac."
  print -r -- ""
  print -n -- "  Type yes on this Mac's keyboard to continue: "
  read -r -t 120 answer || answer=""
  [[ $answer == yes ]] || finish 2 "Cancelled: nothing was sent to this Mac."
  # A pseudo-terminal can type "yes" too; only a real keyboard moves the HID idle clock.
  idle=$(hid_idle_ms) || idle=999999
  (( idle < 5000 )) || finish 2 "REFUSED: \"yes\" did not come from this Mac's keyboard (no local input in the last 5 s), so nothing was sent."
  print -r -- "  Confirmed at this Mac's keyboard."
  log "Mac-input run confirmed at this Mac's keyboard"
}

build() {
  if (( SKIP_BUILD )); then log "Skipping build (--skip-build)"; return; fi
  log "Building $TARGET for iOS (waits for the shared xcodebuild lock)"
  run_bounded $BUILD_LIMIT "$RUN/build.log" - $LOCKER $XCODEBUILD build-for-testing $XCB -destination generic/platform=iOS
  local rc=$?; stop_current
  (( rc == 124 )) && finish 5 "STOPPED: the build did not finish within $(( BUILD_LIMIT / 60 )) minutes. See $RUN/build.log."
  (( rc == 0 )) || finish 1 "FAILED: the build failed. See $RUN/build.log."
}

check_products() {
  local products=($DERIVED/Build/Products/${TARGET}_iphoneos*.xctestrun)
  (( $#products )) || finish 3 "NOT READY: there is no iPhone build of the physical tests in $DERIVED. Run this again without --skip-build."
}

probe() {
  log "Automation pre-flight on $DEVICE_NAME (presses Home, reads the Home Screen)"
  run_tests preflight $PROBE_LIMIT phone_watch TEST_RUNNER_FARSIDE_PHYSICAL_PREFLIGHT=1 -- \
    -only-testing:$TARGET/$PREFLIGHT_CLASS/$PREFLIGHT_TEST
  local rc=$?; stop_current
  (( rc == 125 )) && finish 3 "NOT READY: $STOP_REASON. $(phone_instruction)"
  (( rc == 124 )) && finish 3 "NOT READY: the iPhone did not finish the automation check within $PROBE_LIMIT s. Keep it unlocked on the Home Screen and plugged into this Mac, and run this again; if it repeats, see $LAST_LOG."
  grep -q "Test Case '-\[$TARGET.$PREFLIGHT_CLASS $PREFLIGHT_TEST\]' passed" "$LAST_LOG" && return 0
  STOP_REASON=$(grep -m1 -oE "$PHONE_STATE" "$LAST_LOG")
  [[ -n $STOP_REASON ]] && finish 3 "NOT READY: $STOP_REASON. $(phone_instruction)"
  finish 3 "NOT READY: the iPhone's UI-automation check failed (see $LAST_LOG). Unlock the iPhone, leave it on the Home Screen, and run this again."
}

record() {
  local label=$1 rc=$2 summary
  local -a c
  if summary=$(counts "$LAST_LOG"); then
    c=(${=summary})
    RESULTS+=("$label: $(( c[1] - c[2] - c[3] )) passed, ${c[3]} failed, ${c[2]} skipped")
  else
    RESULTS+=("$label: no XCTest summary (xcodebuild exit $rc)")
  fi
  (( rc == 0 ))
}

run_read_only() {
  (( $#RO_SELECTED )) || return 0
  local -a only=()
  for item in $RO_SELECTED; do only+=(-only-testing:$TARGET/$item); done
  local limit=$(read_only_limit)
  log "Read-only tests (no Mac input): ${(j:, :)RO_SELECTED}; limit $limit s"
  run_tests read-only $limit phone_watch ${(f)"$(phase_env)"} -- $only
  local rc=$?; stop_current
  (( rc == 125 )) && finish 3 "NOT READY: $STOP_REASON during the read-only tests. $(phone_instruction)"
  (( rc == 124 )) && finish 5 "STOPPED: the read-only tests gave no result within $(( limit / 60 )) minutes. See $LAST_LOG."
  record "read-only" $rc || FAILED=1
}

wait_for_idle() {
  local start=$EPOCHREALTIME next_note=0 idle
  while true; do
    screen_locked && finish 3 "NOT READY: this Mac is locked, so no Mac input was sent. Unlock it, then run this again."
    idle=$(hid_idle_ms) || finish 3 "NOT READY: this Mac's input idle time (HIDIdleTime) could not be read, so no Mac input was sent."
    if (( idle >= MIN_IDLE * 1000 )); then LAST_IDLE_MS=$idle; return 0; fi
    (( EPOCHREALTIME - start > IDLE_WAIT_LIMIT )) && finish 5 "STOPPED: this Mac was in use for $(( IDLE_WAIT_LIMIT / 60 )) minutes, so no more Mac input was sent. Run --mac-input again when you can leave it alone."
    if (( EPOCHREALTIME >= next_note )); then
      log "Waiting until nobody has touched this Mac for $MIN_IDLE s (idle now $(( idle / 1000 )) s). Hands off the keyboard, mouse and trackpad."
      next_note=$(( EPOCHREALTIME + 15 ))
    fi
    sleep 1
  done
}

run_mac_input() {
  (( $#MAC_SELECTED )) || return 0
  local index=0 item rc pid
  for item in $MAC_SELECTED; do
    (( index++ ))
    wait_for_idle
    check_lock_state 30
    IN_MAC_INPUT=1
    log "=================================================================="
    log "MAC INPUT $index/${#MAC_SELECTED}: $item will now click and type on this Mac."
    log "Touching the keyboard, mouse or trackpad stops it immediately."
    log "=================================================================="
    run_tests "mac-input-$index-${item//\//-}" $MAC_INPUT_LIMIT mac_input_watch \
      ${(f)"$(phase_env)"} TEST_RUNNER_FARSIDE_PHYSICAL_MAC_INPUT=1 -- -only-testing:$TARGET/$item
    rc=$?
    if (( rc == 124 || rc == 125 )); then
      local kind=$STOP_KIND reason=$STOP_REASON
      pid=$CURRENT_PID; CURRENT_PID=""
      log "Stopping $item: $reason"
      emergency_stop $pid
      IN_MAC_INPUT=0
      RESULTS+=("mac-input $item: stopped ($reason)")
      case $kind in
        human) finish 4 "STOPPED: $reason during $item, so nothing more was sent. Run --mac-input again when you can leave this Mac alone." ;;
        maclocked) finish 4 "STOPPED: $reason during $item, so nothing more was sent. Unlock it and run this again." ;;
        phone) STOP_REASON=$reason; finish 3 "NOT READY: $reason during $item; nothing more was sent. $(phone_instruction)" ;;
        *) finish 5 "STOPPED: $item gave no result within $(( MAC_INPUT_LIMIT / 60 )) minutes; nothing more was sent. See $LAST_LOG." ;;
      esac
    fi
    stop_current
    IN_MAC_INPUT=0
    if ! record "mac-input $item" $rc; then
      FAILED=1
      finish 1 "FAILED: $item failed, so the remaining Mac-input tests were not run. Check this Mac for anything the test left open. See $LAST_LOG."
    fi
  done
}

cleanup() {
  resume_host
  end_lock_poll
  [[ -n $CURRENT_PID ]] && { kill_tree TERM $CURRENT_PID; stop_current }
  [[ -n $CAFFEINATE_PID ]] && kill $CAFFEINATE_PID 2>/dev/null
}
on_signal() {
  log "Interrupted"
  local pid=$CURRENT_PID
  CURRENT_PID=""
  if (( IN_MAC_INPUT )); then
    emergency_stop "$pid"
  elif [[ -n $pid ]]; then
    kill_tree TERM $pid
    reap $pid
  fi
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM HUP

# MARK: Main

FAILED=0
log "Farside physical run $RUN_STAMP: $([[ $DRY_RUN == 1 ]] && print dry-run || print live) mac-input=$MAC_INPUT features=$FEATURES"
for tool in /usr/bin/jq /usr/bin/plutil /usr/bin/lockf /usr/bin/pgrep; do
  [[ -x $tool ]] || finish 3 "NOT READY: missing tool $tool"
done
classify_tests
MAC_INPUT_LIVE=$(( MAC_INPUT_IDLE_SOURCE_VERIFIED || TEST_MODE ))
if (( MAC_INPUT && $#MAC_SELECTED && ! DRY_RUN && ! MAC_INPUT_LIVE )); then
  finish 2 "REFUSED: --mac-input stays off until the Mac idle check is shown to ignore Farside's own clicks and typing (see the runner notes). Nothing was sent to this Mac."
fi
screen_locked && finish 3 "NOT READY: this Mac is locked. Unlock it, then run this again."
if (( MAC_INPUT && $#MAC_SELECTED && ! DRY_RUN )); then confirm_mac_input; fi
if (( MAC_INPUT && ! $#MAC_SELECTED )); then log "No Mac-input tests selected ($MAC_INPUT_BASE subclasses); nothing will be sent to this Mac"; fi
check_device

if (( DRY_RUN )); then
  idle=$(hid_idle_ms) && idle="$(( idle / 1000 )) s" || idle="unreadable (Mac-input tests would not start)"
  print -r -- "DRY RUN: nothing was built, installed or launched, and nothing was sent to the iPhone's UI or to this Mac."
  print -r -- "Mac:          unlocked; idle $idle (Mac-input tests wait for $MIN_IDLE s untouched)"
  print -r -- "iPhone:       $DEVICE_SUMMARY; lock state $LOCK_SUMMARY"
  print -r -- "Automation:   would run $PREFLIGHT_CLASS/$PREFLIGHT_TEST (presses Home, reads the Home Screen), limit $PROBE_LIMIT s"
  print -r -- "Read-only:    ${${(j:, :)RO_SELECTED}:-none} (env ${(j: :)${(@)${(f)"$(phase_env)"}#TEST_RUNNER_}}), limit $(read_only_limit) s"
  if (( MAC_INPUT && ! MAC_INPUT_LIVE )); then
    print -r -- "Mac input:    ${${(j:, :)MAC_SELECTED}:-none}; a live run refuses until the idle check is verified"
  elif (( MAC_INPUT )); then
    print -r -- "Mac input:    ${${(j:, :)MAC_SELECTED}:-none}; would ask for keyboard confirmation, then run each alone (env FARSIDE_PHYSICAL_MAC_INPUT=1), limit $MAC_INPUT_LIMIT s each"
  else
    print -r -- "Mac input:    not requested (needs --mac-input)"
  fi
  (( $#UNCLASSIFIED )) && print -r -- "Never run:    ${(j:, :)UNCLASSIFIED} (not classified)"
  print -r -- "Build:        ${(j: :)LOCKER} xcodebuild build-for-testing ${(j: :)XCB} -destination generic/platform=iOS"
  print -r -- "Test flags:   ${(j: :)${(@f)$(test_flags)}}"
  print -r -- "Advice:       $AUTO_LOCK_ADVICE"
  finish 0 "READY: $DEVICE_NAME and this Mac passed the pre-flight checks (the automation check runs only in a live run)."
fi

log "$AUTO_LOCK_ADVICE"
/usr/bin/caffeinate -dims -w $$ &
CAFFEINATE_PID=$!
build
check_products
probe
run_read_only
run_mac_input
(( FAILED )) && finish 1 "FAILED: at least one physical test failed. See the results above."
finish 0 "PASSED: physical tests finished; nothing failed."
