#!/bin/zsh
# Runs the Debug host's CGVirtualDisplay spike (Docs/perf/VIRTUAL-DISPLAY-SPIKE.md) and reports GO / NO-GO.
#   script/perf/virtual-display-spike.sh [HOST_APP] [LOG] [--direct] [--scenarios 1x-120,1x-144,hidpi-120]
#       [--portrait] [--steps encode,rotate,mirror:virtual,sleep,hold:60] [--max-pixels 8192] [--kill9 SECONDS]
# HOST_APP: a built Debug PocketDeskRemoteHost.app (default: the FarsidePerf DerivedData product).
# LOG: where the spike's output goes (default /tmp/farside-virtual-display-spike-<time>.log).
# By default the app is started through LaunchServices (open -n, like script/e2e) so macOS checks the
# app's own Screen Recording grant; --direct executes the binary instead, which makes the terminal the
# responsible process for that check. Nothing is built here.
# --kill9 N: SIGKILLs the spike N seconds after its "HOLD display" line (pair with --steps hold:60) and
# polls CGGetOnlineDisplayList for 15 s to see when the virtual display disappears (Q5 teardown).
# Exit status: 0 GO, 1 NO-GO, 2 error or no verdict.
set -euo pipefail

HOST_BUNDLE_ID=com.roshan.PocketDesk.RemoteHost
DERIVED=/Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsidePerf
DEFAULT_APP=$DERIVED/Build/Products/Debug/PocketDeskRemoteHost.app
QUIET_FLAG=/tmp/farside-quiet

die() { print -u2 -- "virtual-display-spike: $*"; exit 2 }

direct=0
scenarios=""
portrait=0
steps=""
max_pixels=""
kill9=""
positional=()
while (( $# )); do
  case $1 in
    --direct) direct=1 ;;
    --scenarios) (( $# >= 2 )) || die "--scenarios needs a value"; scenarios=$2; shift ;;
    --portrait) portrait=1 ;;
    --steps) (( $# >= 2 )) || die "--steps needs a value"; steps=$2; shift ;;
    --max-pixels) (( $# >= 2 )) || die "--max-pixels needs a value"; max_pixels=$2; shift ;;
    --kill9) (( $# >= 2 )) || die "--kill9 needs seconds"; kill9=$2; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) positional+=("$1") ;;
  esac
  shift
done
(( ${#positional} <= 2 )) || die "expected at most HOST_APP and LOG"
APP=${positional[1]:-$DEFAULT_APP}
LOG=${positional[2]:-/tmp/farside-virtual-display-spike-$(date +%Y%m%d-%H%M%S).log}

if [[ -e $QUIET_FLAG && ${FARSIDE_SPIKE_IGNORE_QUIET:-0} != 1 ]]; then
  die "$QUIET_FLAG exists (a latency measurement is running);" \
    "rerun with FARSIDE_SPIKE_IGNORE_QUIET=1 only if the quiet window is yours"
fi
[[ -d $APP && ! -L $APP ]] || die "host app not found: $APP"
APP=${APP:A}
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ $bundle_id == $HOST_BUNDLE_ID ]] || die "$APP is not the Farside host ($HOST_BUNDLE_ID)"
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
EXEC=$APP/Contents/MacOS/$executable
[[ -x $EXEC ]] || die "no executable at $EXEC"
# A Release build has no spike and would start as a normal host; a Debug build keeps its code in .debug.dylib.
hooked=0
for image in "$EXEC" "$EXEC.debug.dylib"; do
  if [[ -f $image ]] && /usr/bin/grep -q -a -F -e "--virtual-display-spike" "$image"; then hooked=1; fi
done
(( hooked )) || die "$APP has no --virtual-display-spike hook (not a Debug build of the spike branch)"

spike_pids() {
  local pid
  for pid in $(/usr/bin/pgrep -f -- '--virtual-display-spike' 2>/dev/null || true); do
    if [[ $(/bin/ps -p $pid -o comm= 2>/dev/null) == $EXEC ]]; then print -- $pid; fi
  done
  return 0
}
[[ -z $(spike_pids) ]] || die "a spike from $APP is already running (pid $(spike_pids | tr '\n' ' '))"
if /usr/bin/pgrep -x "$executable" >/dev/null 2>&1; then
  print -- "virtual-display-spike: note: another $executable is running; it will see the extra display." \
    "For a quiet measurement pause or quit the installed host first."
fi

arguments=(--virtual-display-spike)
[[ -n $scenarios ]] && arguments+=(--virtual-display-spike-scenarios "$scenarios")
(( portrait )) && arguments+=(--virtual-display-spike-portrait)
[[ -n $steps ]] && arguments+=(--virtual-display-spike-steps "$steps")
[[ -n $max_pixels ]] && arguments+=(--virtual-display-spike-max-pixels "$max_pixels")
mkdir -p "${LOG:h}"
: > "$LOG"
print -- "virtual-display-spike: $EXEC ${arguments[*]}"
print -- "virtual-display-spike: log $LOG"

stop_spike() {
  local pid
  for pid in $(spike_pids); do kill -INT $pid 2>/dev/null || true; done
}

# Q5 teardown: SIGKILL the held spike and watch the online display list from this shell. The poller is
# a one-file Swift tool compiled once per run (the interpreter is too slow for a 100 ms poll).
online_ids() { "$ONLINE_IDS" 2>/dev/null || true }
build_online_ids() {
  local dir
  dir=$(mktemp -d /tmp/farside-online-ids.XXXXXX)
  cat > "$dir/main.swift" <<'SWIFT'
import CoreGraphics
var count: UInt32 = 0
_ = CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
_ = CGGetOnlineDisplayList(count, &ids, &count)
print(ids.prefix(Int(count)).map(String.init).joined(separator: ","))
SWIFT
  xcrun swiftc -O -o "$dir/online-ids" "$dir/main.swift" >/dev/null 2>&1 || die "could not compile the display poller"
  ONLINE_IDS=$dir/online-ids
}
kill9_watch() {
  local line display pid t0 now
  while ! line=$(/usr/bin/grep -m1 -E 'HOLD display [0-9]+ pid [0-9]+' "$LOG"); do
    sleep 0.5
    [[ -z $(spike_pids) ]] && { print -- "virtual-display-spike: kill9: spike ended before HOLD"; return; }
  done
  display=$(print -- "$line" | /usr/bin/sed -E 's/.*HOLD display ([0-9]+) pid ([0-9]+).*/\1/')
  pid=$(print -- "$line" | /usr/bin/sed -E 's/.*HOLD display ([0-9]+) pid ([0-9]+).*/\2/')
  sleep "$kill9"
  print -- "virtual-display-spike: kill9: online before kill: $(online_ids); kill -9 $pid (display $display)"
  t0=$(date +%s.%N)
  kill -9 "$pid" 2>/dev/null || true
  for _ in {1..150}; do
    now=$(date +%s.%N)
    if [[ ",$(online_ids)," != *",$display,"* ]]; then
      print -- "virtual-display-spike: kill9: display $display GONE $(printf '%.0f' $(( (now - t0) * 1000 ))) ms after kill -9"
      return
    fi
    sleep 0.1
  done
  print -- "virtual-display-spike: kill9: display $display STILL ONLINE 15 s after kill -9 (online: $(online_ids))"
}
[[ -n $kill9 ]] && { build_online_ids; kill9_watch & kill9_pid=$!; }

if (( direct )); then
  trap 'stop_spike' INT TERM
  "$EXEC" "${arguments[@]}" 2>&1 | tee "$LOG" || true
else
  ERR=$LOG.stderr
  : > "$ERR"
  tail -n +1 -f "$LOG" &
  tail_pid=$!
  trap 'stop_spike; kill $tail_pid 2>/dev/null || true' INT TERM
  /usr/bin/open -n -W -g "$APP" --stdout "$LOG" --stderr "$ERR" --args "${arguments[@]}" || true
  sleep 0.3
  kill $tail_pid 2>/dev/null || true
  wait $tail_pid 2>/dev/null || true
  if [[ -s $ERR ]]; then
    print -- "virtual-display-spike: stderr ($ERR):"
    cat "$ERR"
  fi
fi
trap - INT TERM
[[ -n ${kill9_pid:-} ]] && { wait $kill9_pid 2>/dev/null || true; }

if /usr/bin/grep -q -F "CGPreflightScreenCaptureAccess false" "$LOG"; then
  print -- "virtual-display-spike: Screen Recording is not granted to the responsible process;" \
    "see Docs/perf/VIRTUAL-DISPLAY-SPIKE.md (Permissions)"
fi
verdict=$(/usr/bin/grep -E '^VIRTUAL-DISPLAY-SPIKE: ' "$LOG" | tail -n 1 || true)
print -- ""
if [[ -z $verdict ]]; then
  print -- "VIRTUAL-DISPLAY-SPIKE: ERROR reason=\"no verdict line in $LOG\""
  exit 2
fi
print -- "$verdict"
case $verdict in
  "VIRTUAL-DISPLAY-SPIKE: GO "*) exit 0 ;;
  "VIRTUAL-DISPLAY-SPIKE: NO-GO "*) exit 1 ;;
  *) exit 2 ;;
esac
