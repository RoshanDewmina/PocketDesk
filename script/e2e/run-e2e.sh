#!/bin/zsh
# Farside end-to-end harness: the iOS Simulator phone app drives the real Mac host.
# See script/e2e/README.md for what each scenario proves and the safety model.
#   script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app" [--repeat N] [--scenarios a,b,...]
#   script/e2e/run-e2e.sh --self-test      # synthetic stub host; no capture, no input injection
set -uo pipefail
setopt NULL_GLOB
zmodload zsh/datetime

ORIGINAL_ARGS=("$@")
SCRIPT_DIR=${0:A:h}
REPO=${SCRIPT_DIR:h:h}
ROOT=/private/tmp/farside-e2e
RUN_LOCK=/private/tmp/farside-e2e.run.lock
XCB_LOCK=/tmp/farside-xcodebuild.lock
STARTUP_LIMIT=900   # installing the app and launching the UI test runner, before the test starts
LOCK_WAIT_LIMIT=3600  # waiting for other xcodebuild runs to release the shared lock
HOST_BUNDLE_ID=com.roshan.PocketDesk.RemoteHost
PHONE_BUNDLE_ID=com.roshan.PocketDesk.Remote

# One harness run at a time; a second invocation exits 75 instead of interfering.
if [[ -z ${FARSIDE_E2E_RUN_LOCKED:-} ]]; then
  export FARSIDE_E2E_RUN_LOCKED=1
  exec /usr/bin/lockf -t 0 "$RUN_LOCK" /bin/zsh "$0" "${ORIGINAL_ARGS[@]}"
fi

usage() {
  cat <<'EOF'
Usage: script/e2e/run-e2e.sh (--host-app PATH | --self-test) [options]

  --host-app PATH       Installed Debug host to drive (bundle com.roshan.PocketDesk.RemoteHost).
                        A second, isolated E2E instance is launched; the running host is untouched.
  --self-test           Drive the synthetic stub host instead (proves the harness; no real input).
  --scenarios LIST      Comma list of a,b,c,d,e,f,g (d = d1..d5; d1..d5 also accepted). Default: all.
  --repeat N            Run the selected scenarios N times (default 1).
  --soak-seconds S      Scenario f duration in seconds (default 1200 = 20 min).
  --long                Scenario f runs 45 min, past the 30-minute room lease; any disconnect fails.
  --room-lifetime S     The service's room lease, 60-3599 s (default: product default, 1800 s).
                        A short lease (e.g. 300) crosses several renewals in a shorter soak.
  --simulator NAME      Dedicated simulator (default "Farside E2E iPhone"; created if missing).
  --skip-build          Reuse existing build products in the derived-data folder.
  --derived-data PATH   Build products, reused across runs (default ~/Library/Developer/Xcode/DerivedData/FarsideE2E).
  --no-caffeinate       Do not hold display/system-awake assertions during the run.
  --keep-simulator      Leave the dedicated simulator booted afterwards.
  --keep-xcresults      Keep every scenario's .xcresult bundle (default: none; a failed scenario keeps its
                        logs and failure screenshots, a passing iteration keeps only the report).
Exit: 0 all passed, 1 a scenario failed, 2 usage, 3 preflight/setup failure, 75 another run is active.
EOF
}

HOST_APP=""
SELF_TEST=0
SCENARIO_ARG="a,b,c,d,e,g,f"
REPEAT=1
SOAK=1200
ROOM_LIFETIME=""
SIM_NAME="Farside E2E iPhone"
SKIP_BUILD=0
CAFFEINATE=1
KEEP_SIM=0
KEEP_XCRESULTS=0
# Outside ~/Documents: test bundles built there cannot be loaded (Documents privacy protection).
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/FarsideE2E"
while (( $# )); do
  case $1 in
    --host-app) HOST_APP=${2:-}; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    --scenarios) SCENARIO_ARG=${2:-}; shift 2 ;;
    --repeat) REPEAT=${2:-}; shift 2 ;;
    --soak-seconds) SOAK=${2:-}; shift 2 ;;
    --long) SOAK=2700; shift ;;
    --room-lifetime) ROOM_LIFETIME=${2:-}; shift 2 ;;
    --simulator) SIM_NAME=${2:-}; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --derived-data) DERIVED=${2:-}; shift 2 ;;
    --no-caffeinate) CAFFEINATE=0; shift ;;
    --keep-simulator) KEEP_SIM=1; shift ;;
    --keep-xcresults) KEEP_XCRESULTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
done
[[ $REPEAT == <1-> && $SOAK == <10-> ]] || { print -u2 "--repeat and --soak-seconds must be positive integers"; exit 2 }
# The service requires the lease to stay below its relay-credential lifetime (3600 s by default).
[[ -z $ROOM_LIFETIME || $ROOM_LIFETIME == <60-3599> ]] || { print -u2 "--room-lifetime must be 60-3599 seconds"; exit 2 }
if (( SELF_TEST )) && [[ -n $HOST_APP ]]; then print -u2 "Use either --host-app or --self-test"; exit 2; fi
if (( ! SELF_TEST )) && [[ -z $HOST_APP ]]; then print -u2 "--host-app PATH (or --self-test) is required"; usage >&2; exit 2; fi

typeset -A METHOD=(
  a test_a_PairConnectStream
  b test_b_PointerClicksDragScrollZoom
  c test_c_TypingModifiersClipboardDictation
  d1 test_d1_BackgroundShort
  d2 test_d2_BackgroundLong
  d3 test_d3_HostRebootRecovery
  d4 test_d4_SignalingRestart
  d5 test_d5_WatchdogRelaunch
  e test_e_FullScreenSpaces
  g test_g_ThreeFingerSwipesAndScrollRest
  f test_f_Soak
)
typeset -A LIMIT=( a 360 b 600 c 480 d1 300 d2 360 d3 600 d4 360 d5 480 e 480 g 480 f $(( SOAK + 900 )) )
SCENARIOS=()
for item in ${(s:,:)SCENARIO_ARG}; do
  case $item in
    d) SCENARIOS+=(d1 d2 d3 d4 d5) ;;
    a|b|c|d1|d2|d3|d4|d5|e|f|g) SCENARIOS+=($item) ;;
    *) print -u2 "Unknown scenario: $item"; exit 2 ;;
  esac
done

MODE=$([[ $SELF_TEST == 1 ]] && print stub || print real)
RUN_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
REPORT_DIR="$ROOT/reports/$RUN_STAMP"
RUN="$ROOT/run"
HARNESS_LOG=""
SERVICE_PID=""
HOST_PID=""
HOST_LAUNCH_ID=""
WATCHDOG_PID=""
WATCHDOG_EXEC=""
TESTPAD_PID=""
UDID=""
PORT=""
XCB_PID=""
AWAKE_PIDS=()
NEXT_SAMPLE=0
SPACE_KEYS=0
BUN=""

log() { print -r -- "[$(date +%H:%M:%S)] $*" | tee -a "${HARNESS_LOG:-/dev/null}" >&2 }
die() { log "SETUP FAILED: $*"; exit 3 }
jget() { [[ -f $1 ]] && /usr/bin/jq -r "($2) // empty" "$1" 2>/dev/null }
pid_alive() { [[ -n ${1:-} ]] && kill -0 "$1" 2>/dev/null }
wait_gone() { local pid=$1 tenths=$(( $2 * 10 )); while (( tenths-- > 0 )); do pid_alive $pid || return 0; sleep 0.1; done; ! pid_alive $pid }
json_line() { /usr/bin/jq -cn "$@" }

# MARK: Preflight

preflight() {
  for tool in xcrun /usr/bin/jq /usr/bin/plutil /usr/bin/lockf /usr/bin/openssl /usr/sbin/lsof curl; do
    command -v $tool >/dev/null || die "missing tool: $tool"
  done
  BUN=$(command -v bun || true)
  [[ -z $BUN && -x $HOME/.bun/bin/bun ]] && BUN=$HOME/.bun/bin/bun
  [[ -z $BUN && -x /opt/homebrew/bin/bun ]] && BUN=/opt/homebrew/bin/bun
  [[ -n $BUN ]] || die "bun is required for the signaling service and the report"
  if screen_locked; then die "this Mac's screen is locked; unlock it and rerun (the host stops sharing while locked)"; fi
  local free_kb=$(df -k "$REPO" | awk 'NR==2 {print $4}')
  (( free_kb > 4 * 1024 * 1024 )) || log "WARNING: less than 4 GB free on the repository volume"
  if (( ! SELF_TEST )); then
    [[ -d $HOST_APP && ! -L $HOST_APP ]] || die "host app not found: $HOST_APP"
    HOST_APP=${HOST_APP:A}
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HOST_APP/Contents/Info.plist" 2>/dev/null) == $HOST_BUNDLE_ID ]] \
      || die "$HOST_APP is not the PocketDesk host ($HOST_BUNDLE_ID)"
    local executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$HOST_APP/Contents/Info.plist")
    HOST_EXEC="$HOST_APP/Contents/MacOS/$executable"
    # A Release build has no E2E hooks and would start as a normal host with the real pairing.
    grep -q -a -- "FARSIDE_E2E_SIGNAL_URL" "$HOST_EXEC" \
      || die "$HOST_APP has no E2E hooks (not a Debug build of this branch); refusing to launch it"
    WATCHDOG_EXEC="$HOST_APP/Contents/MacOS/FarsideWatchdog"
    if [[ ! -x $WATCHDOG_EXEC ]] || ! grep -q -a -- "FARSIDE_E2E_LAUNCH_ID" "$WATCHDOG_EXEC"; then
      log "WARNING: $HOST_APP has no E2E-capable FarsideWatchdog; scenario d5 will fail"
      WATCHDOG_EXEC=""
    fi
  fi
  SPACE_KEYS=$(space_keys_enabled)
}

screen_locked() {
  /usr/sbin/ioreg -n Root -d1 -a 2>/dev/null | /usr/bin/plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw - 2>/dev/null | grep -q true
}

# Mission Control "Move left/right a space" (^← / ^→) must be on for scenario e.
space_keys_enabled() {
  local file="$RUN/symbolichotkeys.json"
  if ! /usr/bin/defaults export com.apple.symbolichotkeys - 2>/dev/null | /usr/bin/plutil -convert json -o "$file" - 2>/dev/null; then
    print 1; return
  fi
  local key code expected
  for key expected in 79 123 81 124; do
    [[ $(/usr/bin/jq -r ".AppleSymbolicHotKeys[\"$key\"].enabled // true" "$file") == false ]] && { print 0; return }
    code=$(/usr/bin/jq -r ".AppleSymbolicHotKeys[\"$key\"].value.parameters[1] // empty" "$file")
    [[ -n $code && $code != $expected ]] && { print 0; return }
  done
  print 1
}

# MARK: Build

build() {
  if (( SKIP_BUILD )); then log "Skipping build (--skip-build)"; return; fi
  log "Building Farside Test Pad, phone app and E2E UI tests (derived data: $DERIVED)"
  mkdir -p "$REPORT_DIR/build"
  local schemes=(FarsideTestPad)
  (( SELF_TEST )) && schemes+=(FarsideE2EStubHost)
  for scheme in $schemes; do
    /usr/bin/lockf -k "$XCB_LOCK" xcodebuild -project "$REPO/PocketDesktop.xcodeproj" -scheme $scheme -configuration Debug \
      -derivedDataPath "$DERIVED" build > "$REPORT_DIR/build/$scheme.log" 2>&1 \
      || die "building $scheme failed; see $REPORT_DIR/build/$scheme.log"
  done
  # Ad-hoc signing for the simulator only: it embeds the simulated application-identifier the
  # simulator Keychain needs to keep the phone's (E2E) trust. The project's signing is unchanged.
  /usr/bin/lockf -k "$XCB_LOCK" xcodebuild -project "$REPO/PocketDesktop.xcodeproj" -scheme FarsideE2E -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    build-for-testing > "$REPORT_DIR/build/FarsideE2E.log" 2>&1 \
    || die "building the phone app and RemoteE2ETests failed; see $REPORT_DIR/build/FarsideE2E.log"
}

locate_products() {
  TESTPAD_APP="$DERIVED/Build/Products/Debug/Farside Test Pad.app"
  [[ -d $TESTPAD_APP ]] || die "Farside Test Pad not built at $TESTPAD_APP"
  TESTPAD_EXEC="$TESTPAD_APP/Contents/MacOS/Farside Test Pad"
  XCTESTRUN=$(print -l "$DERIVED"/Build/Products/FarsideE2E_iphonesimulator*.xctestrun(om[1]))
  [[ -f $XCTESTRUN ]] || die "no FarsideE2E .xctestrun under $DERIVED/Build/Products"
  if (( SELF_TEST )); then
    HOST_APP="$DERIVED/Build/Products/Debug/FarsideE2EStubHost.app"
    [[ -d $HOST_APP ]] || die "stub host not built at $HOST_APP"
    HOST_EXEC="$HOST_APP/Contents/MacOS/FarsideE2EStubHost"
  fi
}

# MARK: Leftovers from a run that was killed before its cleanup (pids recorded by this harness)

PID_FILE="$ROOT/harness-pids"

record_pid() { [[ -n ${2:-} ]] && print -r -- "$1 $2" >> "$PID_FILE" }

reap_stale() {
  [[ -f $PID_FILE ]] || return 0
  local role pid command
  while read -r role pid; do
    pid_alive "$pid" || continue
    command=$(ps -o command= -p "$pid" 2>/dev/null)
    case $role in
      # Only processes this harness started carry these markers; the owner's host never does.
      host) [[ $command == *--farside-e2e* ]] || continue ;;
      testpad) [[ $command == *"Farside Test Pad"*--run-id* ]] || continue ;;
      service) [[ $command == *src/index.ts* ]] || continue ;;
      watchdog) [[ $command == *FarsideWatchdog*--farside-e2e* ]] || continue ;;
      *) continue ;;
    esac
    log "Stopping leftover $role (pid $pid) from an earlier interrupted run"
    kill -TERM "$pid" 2>/dev/null
    wait_gone "$pid" 5 || kill -KILL "$pid" 2>/dev/null
  done < "$PID_FILE"
  rm -f "$PID_FILE"
}

# MARK: Private harness directory

prepare_root() {
  if [[ -e $ROOT ]]; then
    [[ -d $ROOT && ! -L $ROOT && -O $ROOT ]] || die "$ROOT exists but is not a directory owned by you"
  else
    mkdir -m 700 "$ROOT" || die "cannot create $ROOT"
  fi
  chmod 700 "$ROOT"
  mkdir -p -m 700 "$ROOT/secrets" "$ROOT/reports" "$REPORT_DIR"
  chmod 700 "$ROOT/secrets"
  HARNESS_LOG="$REPORT_DIR/harness.log"
  : >> "$HARNESS_LOG"
  local old=("$ROOT"/reports/[0-9]*T[0-9]*Z(N/On))
  (( ${#old} > 30 )) && rm -rf -- "${(@)old[31,-1]}"
}

reset_iteration_state() {
  rm -rf "$RUN" "$ROOT/host" "$ROOT/phone" "$ROOT/stubhost"
  rm -f "$ROOT"/testpad.jsonl "$ROOT"/testpad-state.json "$ROOT"/testpad-commands.jsonl \
        "$ROOT/secrets/pairing-token" "$ROOT/secrets/invitation.code"
  mkdir -p -m 700 "$RUN" "$RUN/requests" "$RUN/requests-done" "$RUN/responses" "$RUN/results" "$ROOT/phone"
  : > "$ROOT/testpad-commands.jsonl"; chmod 600 "$ROOT/testpad-commands.jsonl"
  : > "$ROOT/phone/commands.jsonl"; chmod 600 "$ROOT/phone/commands.jsonl"
}

mint_token() {
  local token_file="$ROOT/secrets/pairing-token"
  ( umask 077; /usr/bin/openssl rand -hex 32 > "$token_file.tmp" ) && chmod 600 "$token_file.tmp" && mv -f "$token_file.tmp" "$token_file"
}

write_config() {
  json_line --arg runID "$RUN_ID" --arg mode "$MODE" --argjson soak $SOAK --argjson spaceKeys $([[ $SPACE_KEYS == 1 ]] && print true || print false) \
    --arg signal "ws://127.0.0.1:$PORT/signal" --arg hostApp "$HOST_APP" --argjson roomLifetime ${ROOM_LIFETIME:-1800} \
    '{runID: $runID, mode: $mode, soakSeconds: $soak, spaceKeysEnabled: $spaceKeys, backgroundShortSeconds: 5,
      backgroundLongSeconds: 60, reconnectTimeoutSeconds: 60, signalURL: $signal, hostApp: $hostApp,
      roomLifetimeSeconds: $roomLifetime}' > "$RUN/config.json"
}

# MARK: Signaling service (loopback only, product defaults except the connection-rate cap)

choose_port() {
  local port
  for port in {18790..18899}; do
    /usr/sbin/lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 || { print $port; return 0 }
  done
  return 1
}

start_service() {
  local extra=()
  [[ -n $ROOM_LIFETIME ]] && extra+=(ROOM_LIFETIME_SECONDS=$ROOM_LIFETIME)
  ( cd "$REPO/Server" && exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" PORT=$PORT BIND=127.0.0.1 \
      CONNECTION_ATTEMPTS_PER_MINUTE=600 "${extra[@]}" "$BUN" src/index.ts ) >> "$RUN/service.log" 2>&1 &
  SERVICE_PID=$!
  record_pid service $SERVICE_PID
  local tries=150
  while (( tries-- > 0 )); do
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { log "Signaling service up on 127.0.0.1:$PORT (pid $SERVICE_PID)"; return 0 }
    pid_alive $SERVICE_PID || break
    sleep 0.1
  done
  log "Signaling service failed to start; see $RUN/service.log"
  return 1
}

stop_service() {
  pid_alive $SERVICE_PID || { SERVICE_PID=""; return 0 }
  kill -TERM $SERVICE_PID
  wait_gone $SERVICE_PID 8 || kill -KILL $SERVICE_PID
  log "Signaling service stopped"
  SERVICE_PID=""
}

# MARK: Host (the installed app as a second, isolated E2E instance, or the stub)

host_state() { jget "$ROOT/host/state.json" "$1" }

our_host_alive() {
  pid_alive $HOST_PID || return 1
  [[ $(ps -p $HOST_PID -o comm= 2>/dev/null) == $HOST_EXEC ]] || return 1
  [[ $(host_state .launchID) == $HOST_LAUNCH_ID && $(host_state .pid) == $HOST_PID ]]
}

launch_host() {
  local reset=$1
  HOST_LAUNCH_ID="L$(date +%s)$RANDOM"
  local environment=(--env FARSIDE_E2E=1 --env "FARSIDE_E2E_DIR=$ROOT" --env "FARSIDE_E2E_RUN_ID=$RUN_ID"
    --env "FARSIDE_E2E_SIGNAL_URL=ws://127.0.0.1:$PORT/signal" --env "FARSIDE_E2E_LAUNCH_ID=$HOST_LAUNCH_ID")
  (( SPACE_KEYS )) && environment+=(--env FARSIDE_E2E_ALLOW_SPACE_KEYS=1)
  local arguments=(--farside-e2e)
  (( reset )) && arguments+=(--farside-e2e-reset-pairing)
  rm -f "$ROOT/host/refused.txt"
  log "Launching E2E host instance ${HOST_APP:t} (reset=$reset, launch $HOST_LAUNCH_ID)"
  /usr/bin/open -n -g "$HOST_APP" "${environment[@]}" --stdout "$RUN/host-$HOST_LAUNCH_ID.out" \
    --stderr "$RUN/host-$HOST_LAUNCH_ID.err" --args "${arguments[@]}" || { log "open failed for $HOST_APP"; return 1 }
  local tries=300
  while (( tries-- > 0 )); do
    if [[ -f $ROOT/host/refused.txt ]]; then log "Host refused E2E mode: $(cat "$ROOT/host/refused.txt")"; return 1; fi
    if [[ $(host_state .launchID) == $HOST_LAUNCH_ID ]]; then
      HOST_PID=$(host_state .pid)
      if our_host_alive; then record_pid host $HOST_PID; return 0; fi
    fi
    sleep 0.1
  done
  log "E2E host did not publish state within 30 s; see $RUN/host-$HOST_LAUNCH_ID.err"
  return 1
}

wait_host_ready() {
  local tries=$(( ${1:-90} * 10 ))
  if (( ! SELF_TEST )); then
    sleep 1
    [[ $(host_state .screenRecording) == true ]] || { log "The installed host lacks Screen Recording permission; grant it to $HOST_APP, then rerun"; return 2 }
    [[ $(host_state .accessibility) == true ]] || { log "The installed host lacks Accessibility (control) permission; grant it, then rerun"; return 2 }
  fi
  while (( tries-- > 0 )); do
    our_host_alive || { log "E2E host exited while starting"; return 1 }
    [[ $(host_state .hostRegistered) == true ]] && return 0
    sleep 0.1
  done
  log "E2E host never registered with the signaling service (status: $(host_state .coordinatorStatus))"
  return 1
}

kill_host() {
  local signal=${1:-TERM}
  if ! our_host_alive; then HOST_PID=""; return 0; fi
  log "Stopping E2E host pid $HOST_PID with SIG$signal"
  kill -$signal $HOST_PID
  wait_gone $HOST_PID 10 || { kill -KILL $HOST_PID; wait_gone $HOST_PID 5 }
  HOST_PID=""
}

# The installed host's own FarsideWatchdog, run directly (never through launchd) in its E2E mode:
# it supervises only E2E instances through the run record under $ROOT/host/watchdog and relaunches
# them with the same E2E contract. The owner's registered helper and its crash ledger are untouched.
start_watchdog() {
  pid_alive $WATCHDOG_PID && return 0
  [[ -n $WATCHDOG_EXEC ]] || return 1
  local environment=(FARSIDE_E2E=1 "FARSIDE_E2E_DIR=$ROOT" "FARSIDE_E2E_RUN_ID=$RUN_ID"
    "FARSIDE_E2E_SIGNAL_URL=ws://127.0.0.1:$PORT/signal")
  (( SPACE_KEYS )) && environment+=(FARSIDE_E2E_ALLOW_SPACE_KEYS=1)
  /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" "${environment[@]}" "$WATCHDOG_EXEC" --farside-e2e \
    >> "$RUN/watchdog.log" 2>&1 &
  WATCHDOG_PID=$!
  record_pid watchdog $WATCHDOG_PID
  sleep 1
  pid_alive $WATCHDOG_PID || { log "E2E watchdog exited at once; see $RUN/watchdog.log"; WATCHDOG_PID=""; return 1 }
  log "E2E watchdog running (pid $WATCHDOG_PID)"
}

stop_watchdog() {
  pid_alive $WATCHDOG_PID || { WATCHDOG_PID=""; return 0 }
  kill -TERM $WATCHDOG_PID
  wait_gone $WATCHDOG_PID 5 || kill -KILL $WATCHDOG_PID
  log "E2E watchdog stopped"
  WATCHDOG_PID=""
}

# After a kill -9 with the watchdog running: wait for the host it relaunched and adopt it.
await_relaunched_host() {
  local previous=$1 deadline=$(( SECONDS + $2 )) launch pid
  while (( SECONDS < deadline )); do
    launch=$(host_state .launchID); pid=$(host_state .pid)
    if [[ -n $launch && $launch != $previous && -n $pid ]] && pid_alive $pid \
       && [[ $(ps -p $pid -o comm= 2>/dev/null) == $HOST_EXEC && $(ps -o command= -p $pid 2>/dev/null) == *--farside-e2e* ]]; then
      HOST_PID=$pid; HOST_LAUNCH_ID=$launch
      record_pid host $HOST_PID
      return 0
    fi
    sleep 0.1
  done
  return 1
}

service_ready() { curl -sS --max-time 3 "http://127.0.0.1:$PORT/ready" 2>/dev/null | /usr/bin/jq -c . 2>/dev/null }

ensure_host() {
  our_host_alive && return 0
  log "E2E host not running; relaunching it with its saved E2E pairing"
  launch_host 0 && wait_host_ready 90
}

# MARK: Farside Test Pad

testpad_alive() { pid_alive $TESTPAD_PID && [[ $(ps -p $TESTPAD_PID -o comm= 2>/dev/null) == $TESTPAD_EXEC ]] }

testpad_command() {
  print -r -- "$(json_line --arg id "h$RANDOM$RANDOM" --arg cmd "$1" '{id: $id, cmd: $cmd}')" >> "$ROOT/testpad-commands.jsonl"
}

launch_testpad() {
  rm -f "$ROOT/testpad-state.json"
  /usr/bin/open -n "$TESTPAD_APP" --args --log "$ROOT/testpad.jsonl" --state "$ROOT/testpad-state.json" \
    --commands "$ROOT/testpad-commands.jsonl" --run-id "$RUN_ID" || return 1
  local tries=200
  while (( tries-- > 0 )); do
    TESTPAD_PID=$(jget "$ROOT/testpad-state.json" .pid)
    testpad_alive && { record_pid testpad $TESTPAD_PID; log "Farside Test Pad running (pid $TESTPAD_PID)"; return 0 }
    sleep 0.1
  done
  log "Farside Test Pad did not start"
  return 1
}

ensure_testpad() { testpad_alive || launch_testpad }

# In-window synthetic events only (no global input): proves the fixture logs clicks, drags and typing.
testpad_self_check() {
  local id="selfcheck$RANDOM$RANDOM" line="" tries=150
  print -r -- "$(json_line --arg id "$id" '{id: $id, cmd: "selfCheck"}')" >> "$ROOT/testpad-commands.jsonl"
  while (( tries-- > 0 )); do
    line=$(grep -F "\"id\":\"$id\"" "$ROOT/testpad.jsonl" 2>/dev/null | tail -1)
    [[ -n $line ]] && break
    sleep 0.1
  done
  [[ -n $line ]] || { log "Farside Test Pad self-check did not answer"; return 1 }
  print -r -- "$line" > "$REPORT_DIR/testpad-selfcheck-$RUN_ID.json"
  if [[ $(print -r -- "$line" | /usr/bin/jq -r .ok) != true ]]; then
    log "Farside Test Pad self-check failed: $(print -r -- "$line" | /usr/bin/jq -c .checks)"
    return 1
  fi
  log "Farside Test Pad self-check passed (click, right-click, double-click, drag, typing, ⌘A, state)"
}

activate_testpad() { /usr/bin/open -a "$TESTPAD_APP" }

testpad_restore_window() {
  testpad_alive || return 0
  if [[ $(jget "$ROOT/testpad-state.json" .fullscreen) == true ]]; then
    log "Test Pad is in full screen; exiting it"
    testpad_command exitFullScreen
    local tries=100
    while (( tries-- > 0 )) && [[ $(jget "$ROOT/testpad-state.json" .fullscreen) == true ]]; do sleep 0.1; done
  fi
}

quit_testpad() {
  testpad_alive || return 0
  testpad_restore_window
  testpad_command quit
  wait_gone $TESTPAD_PID 5 || kill -TERM $TESTPAD_PID
  TESTPAD_PID=""
}

# MARK: Simulator

ensure_simulator() {
  UDID=$(xcrun simctl list devices -j | /usr/bin/jq -r --arg name "$SIM_NAME" \
    '[.devices[][] | select(.name == $name and .isAvailable)] | first | .udid // empty')
  if [[ -z $UDID ]]; then
    local runtime=$(xcrun simctl list runtimes -j | /usr/bin/jq -r \
      '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version) | last | .identifier // empty')
    [[ -n $runtime ]] || die "no available iOS simulator runtime"
    local types=$(xcrun simctl list devicetypes -j | /usr/bin/jq -r '.devicetypes[].identifier')
    local type
    for candidate in iPhone-17-Pro iPhone-17 iPhone-18-Pro iPhone-16-Pro; do
      type=$(print -r -- "$types" | grep -x "com.apple.CoreSimulator.SimDeviceType.$candidate" | head -1)
      [[ -n $type ]] && break
    done
    [[ -n $type ]] || die "no suitable iPhone simulator device type"
    UDID=$(xcrun simctl create "$SIM_NAME" "$type" "$runtime") || die "could not create simulator $SIM_NAME"
    log "Created dedicated simulator $SIM_NAME ($UDID)"
  fi
  local state=$(xcrun simctl list devices -j | /usr/bin/jq -r --arg udid "$UDID" '.devices[][] | select(.udid == $udid) | .state')
  [[ $state == Booted ]] || xcrun simctl boot "$UDID" >/dev/null 2>&1
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || die "simulator $SIM_NAME did not finish booting"
  log "Simulator $SIM_NAME ($UDID) booted"
}

phone_pid() { pgrep -f "Devices/$UDID/data/Containers/Bundle/Application/.*/PocketDeskRemote.app/PocketDeskRemote" | head -1 }

# MARK: Requests from the UI tests (only actions on processes this harness owns)

reply() {
  local file="$RUN/responses/$1.json" extra=${4:-}
  [[ -n $extra ]] || extra='{}'
  json_line --arg id "$1" --argjson ok $2 --arg message "$3" --argjson at $(date +%s) --argjson extra "$extra" \
    '$extra + {id: $id, ok: $ok, message: $message, at: $at}' > "$file.tmp" && mv -f "$file.tmp" "$file"
}

serve_requests() {
  local request id action done_file
  for request in "$RUN"/requests/*.json; do
    id=$(jget "$request" .id); action=$(jget "$request" .action)
    done_file="$RUN/requests-done/${request:t}"
    mv -f "$request" "$done_file"
    [[ $id =~ '^[A-Za-z0-9._-]{1,120}$' ]] || { log "Ignoring malformed request ${request:t}"; continue }
    log "Request $action ($id)"
    case $action in
      host.kill)
        local signal=$(jget "$done_file" .signal) previous=$HOST_LAUNCH_ID killed_at
        [[ $signal == KILL ]] || signal=TERM
        if ! our_host_alive; then reply "$id" false "no harness-owned host is running"
        elif [[ $(jget "$done_file" .awaitRelaunch) == true ]]; then
          if ! pid_alive $WATCHDOG_PID; then reply "$id" false "the E2E watchdog is not running"
          else
            killed_at=$EPOCHREALTIME
            kill_host $signal
            if await_relaunched_host "$previous" 20; then
              local seconds=$(( EPOCHREALTIME - killed_at ))
              log "Watchdog relaunched the E2E host in ${seconds}s (pid $HOST_PID, launch $HOST_LAUNCH_ID)"
              reply "$id" true "host relaunched by the watchdog (pid $HOST_PID)" \
                "$(json_line --argjson s $seconds --argjson pid $HOST_PID --arg launch $HOST_LAUNCH_ID '{seconds: $s, pid: $pid, launchID: $launch}')"
            else
              reply "$id" false "no relaunched E2E host within 20 s of SIG$signal; see $RUN/watchdog.log"
            fi
          fi
        else kill_host $signal; reply "$id" true "host stopped with SIG$signal"; fi ;;
      host.launch)
        kill_host TERM
        if launch_host 0 && wait_host_ready 90; then reply "$id" true "host relaunched (pid $HOST_PID)"
        else reply "$id" false "host relaunch failed: $(host_state .coordinatorStatus)"; fi ;;
      service.stop)
        stop_service; reply "$id" true "signaling service stopped" ;;
      service.ready)
        local ready=$(service_ready)
        if [[ -n $ready ]]; then reply "$id" true "service readiness" "$(json_line --argjson r "$ready" '{ready: $r}')"
        else reply "$id" false "service readiness unavailable"; fi ;;
      watchdog.start)
        if (( SELF_TEST )); then reply "$id" false "the stub host has no watchdog"
        elif start_watchdog; then reply "$id" true "E2E watchdog running (pid $WATCHDOG_PID)"
        else reply "$id" false "E2E watchdog unavailable; see $RUN/watchdog.log"; fi ;;
      watchdog.stop)
        stop_watchdog; reply "$id" true "E2E watchdog stopped" ;;
      service.start)
        if pid_alive $SERVICE_PID || start_service; then reply "$id" true "signaling service running on $PORT"
        else reply "$id" false "signaling service did not start"; fi ;;
      testpad.activate)
        if ensure_testpad && activate_testpad; then reply "$id" true "Test Pad activated"
        else reply "$id" false "Test Pad unavailable"; fi ;;
      mark)
        log "MARK $(jget "$done_file" .label)"; reply "$id" true "marked" ;;
      *)
        reply "$id" false "unknown action $action" ;;
    esac
  done
}

sample_resources() {
  (( SECONDS >= NEXT_SAMPLE )) || return 0
  NEXT_SAMPLE=$(( SECONDS + 5 ))
  local phone=$(phone_pid) role pid cpu rss
  for role pid in host "$HOST_PID" phone "$phone" testpad "$TESTPAD_PID" service "$SERVICE_PID" watchdog "$WATCHDOG_PID"; do
    pid_alive "$pid" || continue
    read -r cpu rss <<< "$(ps -o %cpu=,rss= -p $pid 2>/dev/null)"
    [[ -n ${cpu:-} ]] || continue
    json_line --arg role $role --argjson pid $pid --argjson cpu ${cpu:-0} --argjson rss ${rss:-0} --argjson t $(date +%s) \
      '{t: $t, role: $role, pid: $pid, cpuPercent: $cpu, rssKB: $rss}' >> "$RUN/resources.jsonl"
  done
}

# MARK: Scenarios

prepare_for() {
  local scenario=$1
  pid_alive $SERVICE_PID || start_service || return 1
  case $scenario in
    a)
      kill_host TERM
      mint_token
      launch_host 1 || return 1
      wait_host_ready 120 || return $? ;;
    f)
      # A fresh registration puts the 30-minute room-lease boundary at a known point of the soak.
      kill_host TERM
      launch_host 0 || return 1
      wait_host_ready 120 || return $? ;;
    *)
      ensure_host || return $? ;;
  esac
  if [[ $(host_state .paired) != true && ! -f $ROOT/secrets/pairing-token ]]; then mint_token; fi
  ensure_testpad || return 1
  testpad_restore_window
  testpad_command reset
  activate_testpad
  local covered=$(jget "$ROOT/testpad-state.json" '.coveredBy | if type == "array" then join(", ") else . end')
  [[ -n $covered ]] && log "Test Pad currently covered by: $covered (the scenario relocates it or fails)"
  return 0
}

run_scenario() {
  local iteration=$1 scenario=$2 method=${METHOD[$2]} limit=${LIMIT[$2]}
  local out="$REPORT_DIR/iter-$iteration/$scenario"
  mkdir -p "$out"
  local started_epoch=$(date +%s) started=$SECONDS timed_out=0 rc
  log "Scenario $scenario ($method), limit ${limit}s"
  prepare_for $scenario
  local prepare_rc=$?
  if (( prepare_rc != 0 )); then
    log "Scenario $scenario setup failed"
    json_line --arg s $scenario --arg m $method --argjson start $started_epoch --argjson end $(date +%s) \
      '{scenario: $s, method: $m, exitCode: -1, timedOut: false, setupFailed: true, startedAt: $start, finishedAt: $end}' > "$out/harness.json"
    (( prepare_rc == 2 )) && die "host permissions missing; aborting the run"
    return 1
  fi
  export TEST_RUNNER_FARSIDE_E2E_CONFIG="$RUN/config.json"
  /usr/bin/lockf -k "$XCB_LOCK" xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" \
    -only-testing:"RemoteE2ETests/RemoteE2ETests/$method" -resultBundlePath "$out/result.xcresult" \
    -collect-test-diagnostics never > "$out/xcodebuild.log" 2>&1 &
  XCB_PID=$!
  # The limit counts from the test's own start: waiting for the shared xcodebuild lock (other
  # builds on this Mac), then installing the app and launching the runner, have their own allowances.
  local test_started=0 xcodebuild_started=0 lock_noted=0
  while pid_alive $XCB_PID; do
    serve_requests
    sample_resources
    if (( ! xcodebuild_started )) && [[ -s $out/xcodebuild.log ]]; then
      xcodebuild_started=$SECONDS
      (( lock_noted )) && log "Shared xcodebuild lock acquired after $(( SECONDS - started ))s"
    fi
    if (( ! xcodebuild_started && ! lock_noted && SECONDS - started > 60 )); then
      lock_noted=1
      log "Waiting for the shared xcodebuild lock (another build or test run is using it)"
    fi
    if (( ! test_started )) && grep -q "Test Case '.*' started" "$out/xcodebuild.log" 2>/dev/null; then
      test_started=$SECONDS
    fi
    if (( test_started && SECONDS - test_started > limit )) \
       || (( xcodebuild_started && ! test_started && SECONDS - xcodebuild_started > STARTUP_LIMIT )) \
       || (( ! xcodebuild_started && SECONDS - started > LOCK_WAIT_LIMIT )); then
      timed_out=1
      log "Scenario $scenario exceeded its time limit (${limit}s test, ${STARTUP_LIMIT}s startup, ${LOCK_WAIT_LIMIT}s lock wait); stopping the test run"
      stop_xcodebuild
      break
    fi
    sleep 0.2
  done
  wait $XCB_PID 2>/dev/null; rc=$?
  XCB_PID=""
  serve_requests
  [[ -f $RUN/results/$scenario.json ]] && cp "$RUN/results/$scenario.json" "$out/result.json"
  json_line --arg s $scenario --arg m $method --argjson rc $rc --argjson timedOut $([[ $timed_out == 1 ]] && print true || print false) \
    --argjson start $started_epoch --argjson end $(date +%s) \
    '{scenario: $s, method: $m, exitCode: $rc, timedOut: $timedOut, setupFailed: false, startedAt: $start, finishedAt: $end}' > "$out/harness.json"
  stop_watchdog
  log "Scenario $scenario finished: exit $rc$([[ $timed_out == 1 ]] && print ' (timed out)') in $(( SECONDS - started ))s"
  # Result bundles are large (screen recordings); a failure keeps its screenshots and logs instead.
  local outcome=$(jget "$out/result.json" .status)
  if [[ -d $out/result.xcresult ]]; then
    [[ $rc == 0 && $outcome == (passed|skipped) ]] || save_failure_screenshots "$out"
    (( KEEP_XCRESULTS )) || rm -rf "$out/result.xcresult"
  fi
  [[ $rc == 0 && $outcome == (passed|skipped) ]] && rm -f "$out/xcodebuild.log"
  testpad_restore_window
  return 0
}

save_failure_screenshots() {
  local out=$1 staging=$1/attachments index=0 file
  mkdir -p "$staging"
  xcrun xcresulttool export attachments --path "$out/result.xcresult" --output-path "$staging" >/dev/null 2>&1
  for file in $(/usr/bin/jq -r '.[].attachments[] | select(.suggestedHumanReadableName | test("failure|covered"; "i"))
      | select(.exportedFileName | test("[.]png$")) | .exportedFileName' "$staging/manifest.json" 2>/dev/null); do
    [[ $file =~ '^[A-Za-z0-9._-]+$' && -f $staging/$file ]] || continue
    mv "$staging/$file" "$out/failure-$(( ++index )).png"
  done
  rm -rf "$staging"
}

# After the report: a passing iteration keeps only its scenario results; build logs go when builds passed.
prune_run_artifacts() {
  local iteration scenario failed
  for iteration in "$REPORT_DIR"/iter-*(N/); do
    failed=0
    for scenario in "$iteration"/*(N/); do
      [[ ${scenario:t} == logs ]] && continue
      [[ -f $scenario/xcodebuild.log || -f $scenario/failure-1.png ]] && failed=1
      [[ $(jget "$scenario/harness.json" .exitCode) == 0 ]] || failed=1
    done
    (( failed )) || rm -rf "$iteration/logs"
  done
  rm -rf "$REPORT_DIR/build"
  rm -rf "$RUN" "$ROOT/host" "$ROOT/phone" "$ROOT/stubhost"
}

stop_xcodebuild() {
  pid_alive $XCB_PID || return 0
  local children=($(pgrep -P $XCB_PID))
  kill -TERM $children $XCB_PID 2>/dev/null
  wait_gone $XCB_PID 15 || kill -KILL $children $XCB_PID 2>/dev/null
}

collect_iteration_logs() {
  local destination="$REPORT_DIR/iter-$1/logs"
  mkdir -p "$destination"
  cp -R "$ROOT/host" "$destination/host" 2>/dev/null
  cp -R "$ROOT/phone" "$destination/phone" 2>/dev/null
  rm -f "$destination/phone/commands.jsonl"
  cp "$ROOT"/testpad.jsonl "$ROOT"/testpad-state.json "$destination/" 2>/dev/null
  cp "$RUN"/service.log "$RUN"/resources.jsonl "$RUN"/config.json "$RUN"/watchdog.log "$destination/" 2>/dev/null
  cp "$RUN"/host-*.err "$destination/" 2>/dev/null
}

# MARK: Cleanup (only processes this run started)

CLEANED=0
cleanup() {
  (( CLEANED )) && return
  CLEANED=1
  log "Cleaning up"
  stop_watchdog
  stop_xcodebuild
  quit_testpad
  kill_host TERM
  stop_service
  for pid in $AWAKE_PIDS; do kill -TERM $pid 2>/dev/null; done
  rm -f "$ROOT/secrets/pairing-token" "$ROOT/secrets/invitation.code"
  if [[ -n $UDID && $KEEP_SIM == 0 ]]; then xcrun simctl shutdown "$UDID" >/dev/null 2>&1; fi
}
trap 'cleanup' EXIT
trap 'log "Interrupted"; cleanup; exit 130' INT TERM HUP

keep_awake() {
  (( CAFFEINATE )) || return 0
  # Assertions end with this process: the display never sleeps mid-run and the Mac never locks.
  /usr/bin/caffeinate -dims -w $$ &
  AWAKE_PIDS+=($!)
  ( while kill -0 $$ 2>/dev/null; do /usr/bin/caffeinate -u -t 2; sleep 25; done ) >/dev/null 2>&1 &
  AWAKE_PIDS+=($!)
}

# MARK: Main

prepare_root
reap_stale
mkdir -p -m 700 "$RUN"
log "Farside E2E run $RUN_STAMP: mode=$MODE scenarios=${(j:,:)SCENARIOS} repeat=$REPEAT soak=${SOAK}s"
preflight
ensure_simulator
build
locate_products
keep_awake
json_line --arg run $RUN_STAMP --arg mode $MODE --arg hostApp "$HOST_APP" --arg scenarios "${(j:,:)SCENARIOS}" \
  --argjson repeat $REPEAT --argjson soak $SOAK --argjson start $(date +%s) --arg simulator "$SIM_NAME ($UDID)" \
  --arg head "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)" --argjson spaceKeys $([[ $SPACE_KEYS == 1 ]] && print true || print false) \
  --arg macOS "$(sw_vers -productVersion)" --arg xcode "$(xcodebuild -version 2>/dev/null | head -1)" \
  '{run: $run, mode: $mode, hostApp: $hostApp, scenarios: ($scenarios | split(",")), repeat: $repeat, soakSeconds: $soak,
    startedAt: $start, simulator: $simulator, commit: $head, spaceKeysEnabled: $spaceKeys, macOS: $macOS, xcode: $xcode}' \
  > "$REPORT_DIR/meta.json"
(( SPACE_KEYS )) || log "Mission Control Space shortcuts are off; scenario e will be skipped"

for (( iteration = 1; iteration <= REPEAT; iteration++ )); do
  RUN_ID="${RUN_STAMP}-i$iteration"
  log "=== Iteration $iteration of $REPEAT ($RUN_ID) ==="
  stop_watchdog; stop_service; kill_host TERM; quit_testpad
  reset_iteration_state
  PORT=$(choose_port) || die "no free loopback port in 18790-18899"
  write_config
  start_service || die "signaling service did not start"
  launch_testpad || die "Farside Test Pad did not start"
  testpad_self_check || die "Farside Test Pad self-check failed; see $ROOT/testpad.jsonl"
  for scenario in $SCENARIOS; do
    run_scenario $iteration $scenario
  done
  collect_iteration_logs $iteration
done

cleanup
json_line --argjson end $(date +%s) '{finishedAt: $end}' > "$REPORT_DIR/finished.json"
"$BUN" "$SCRIPT_DIR/report.ts" "$REPORT_DIR"
report_rc=$?
prune_run_artifacts
ln -sfn "$REPORT_DIR" "$ROOT/reports/latest"
log "Report: $REPORT_DIR/report.md"
exit $report_rc
