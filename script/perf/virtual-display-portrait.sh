#!/bin/zsh
# Bounded Debug-only portrait experiment. Default action is check (NO display creation).
# Usage: script/perf/virtual-display-portrait.sh [--app APP] [--action check|smoke|interactive]
#        [--mode 1x|2x] [--log LOG] [--direct] [--moving-seconds 1..10] [--idle-seconds 1..5]
#        [--validate-only]
# LaunchServices is the default permission identity. --direct makes the invoking terminal responsible.
# Nothing is built, installed, paired, permission-prompted or sent over a network here.
set -euo pipefail
umask 077

die() { print -u2 -- "virtual-display-portrait: $*"; exit 2 }
APP=/Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsidePortraitPrototype/Build/Products/Debug/PocketDeskRemoteHost.app
action=check
mode=1x
log_path=""
direct=0
validate=0
moving=""
idle=""
typeset -A seen
while (( $# )); do
  flag=$1
  [[ -z ${seen[$flag]:-} ]] || die "duplicate option $flag"
  seen[$flag]=1
  case $flag in
    --app|--action|--mode|--log|--moving-seconds|--idle-seconds)
      (( $# >= 2 )) || die "$flag needs a value"
      [[ $2 != --* ]] || die "$flag needs a value"
      case $flag in
        --app) APP=$2 ;;
        --action) action=$2 ;;
        --mode) mode=$2 ;;
        --log) log_path=$2 ;;
        --moving-seconds) moving=$2 ;;
        --idle-seconds) idle=$2 ;;
      esac
      shift ;;
    --direct) direct=1 ;;
    --validate-only) validate=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) die "unknown option $flag" ;;
  esac
  shift
done
[[ $action == check || $action == smoke || $action == interactive ]] || die "invalid action"
[[ $mode == 1x || $mode == 2x ]] || die "invalid mode"
if [[ -n $moving || -n $idle ]]; then
  [[ $action == smoke ]] || die "durations require smoke action"
fi
[[ -z $moving || ( $moving == <-> && $moving -ge 1 && $moving -le 10 ) ]] || die "moving seconds must be an integer in 1..10"
[[ -z $idle || ( $idle == <-> && $idle -ge 1 && $idle -le 5 ) ]] || die "idle seconds must be an integer in 1..5"
[[ -d $APP && ! -L $APP ]] || die "app must be a real directory"
APP=${APP:A}
[[ $APP != /Applications/* ]] || die "use the isolated built artifact, not the installed host"
plist=$APP/Contents/Info.plist
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)
[[ $bundle == com.roshan.PocketDesk.RemoteHost ]] || die "wrong bundle identifier"
binary=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)
[[ -n $binary && $binary != . && $binary != .. && $binary != *[^A-Za-z0-9._-]* ]] || die "invalid executable name"
EXEC=$APP/Contents/MacOS/$binary
[[ -f $EXEC && -x $EXEC && ! -L $EXEC ]] || die "missing regular executable"
hooked=0
for image in "$EXEC" "$EXEC.debug.dylib"; do
  if [[ -f $image ]] && /usr/bin/grep -aqF -- '--virtual-display-portrait' "$image" \
      && /usr/bin/grep -aqF -- 'VIRTUAL-DISPLAY-PORTRAIT-JSON:' "$image"; then hooked=1; fi
done
(( hooked )) || die "portrait Debug hook missing; refusing ordinary/Release host launch"
if (( validate )); then
  print -- "virtual-display-portrait: bundle/arguments validated; no executable launched"
  exit 0
fi
if [[ $action != check && -e /tmp/farside-quiet ]]; then die "a measurement owns /tmp/farside-quiet"; fi
if [[ -z $log_path ]]; then
  task_dir=$(mktemp -d /private/tmp/farside-portrait.XXXXXX)
  log_path=$task_dir/result.log
fi
mkdir -p "${log_path:h}"
[[ ! -e $log_path && ! -L $log_path ]] || die "log destination must be a new file"
log_path=${log_path:A}
err_path=$log_path.stderr
[[ ! -e $log_path && ! -L $log_path && ! -e $err_path && ! -L $err_path ]] || die "log and stderr destinations must be new files"
# noclobber rejects a raced regular file or symlink at creation; generated logs have private permissions.
setopt noclobber
: > "$log_path"
: > "$err_path"
unsetopt noclobber
arguments=(--virtual-display-portrait --portrait-mode "$mode" --portrait-action "$action")
[[ -z $moving ]] || arguments+=(--portrait-moving-seconds "$moving")
[[ -z $idle ]] || arguments+=(--portrait-idle-seconds "$idle")
task_root=${0:A:h:h:h}
export FARSIDE_PORTRAIT_REVISION=$(git -C "$task_root" rev-parse HEAD 2>/dev/null || print unknown)
print -- "virtual-display-portrait: action=$action mode=$mode log=$log_path"
print -- "virtual-display-portrait: only the new experiment process can be signalled; installed hosts are preserved"

app_pid=""
app_started=""
launcher_pid=""
launcher_started=""
interrupted=0
owned_pid() {
  [[ $app_pid == <-> && -n $app_started ]] || return 1
  local current_started current_command
  current_started=$(/bin/ps -p "$app_pid" -o lstart= 2>/dev/null || true)
  current_command=$(/bin/ps -p "$app_pid" -o command= 2>/dev/null || true)
  [[ $current_started == "$app_started" && $current_command == "$EXEC --virtual-display-portrait "* ]]
}
read_owner() {
  [[ -z $app_pid ]] || return 0
  local found command
  found=$(sed -n 's/^VIRTUAL-DISPLAY-PORTRAIT-PROCESS: \([0-9][0-9]*\)$/\1/p' "$log_path" | head -n 1)
  [[ $found == <-> ]] || return 0
  command=$(/bin/ps -p "$found" -o command= 2>/dev/null || true)
  [[ $command == "$EXEC --virtual-display-portrait "* ]] || return 0
  app_pid=$found
  app_started=$(/bin/ps -p "$found" -o lstart= 2>/dev/null || true)
}
stop_owned() {
  read_owner
  if owned_pid; then kill -TERM "$app_pid" 2>/dev/null || true; fi
}
trap 'interrupted=1; stop_owned' INT TERM HUP
if (( direct )); then
  "$EXEC" "${arguments[@]}" >> "$log_path" 2>> "$err_path" &
else
  /usr/bin/open -n -W -g "$APP" --stdout "$log_path" --stderr "$err_path" --args "${arguments[@]}" &
fi
launcher_pid=$!
launcher_started=$(/bin/ps -p "$launcher_pid" -o lstart= 2>/dev/null || true)
outer_seconds=60
[[ $action != interactive ]] || outer_seconds=300
started_seconds=$SECONDS
forced=0
while kill -0 "$launcher_pid" 2>/dev/null; do
  read_owner
  if (( interrupted || SECONDS - started_seconds >= outer_seconds )); then
    forced=1
    stop_owned
    grace_started=$SECONDS
    while kill -0 "$launcher_pid" 2>/dev/null && (( SECONDS - grace_started < 12 )); do
      # The app may produce its identity header only after a slow launch. Recheck before each signal.
      stop_owned
      sleep 0.2
    done
    if owned_pid; then kill -KILL "$app_pid" 2>/dev/null || true; fi
    # The LaunchServices waiter belongs to this shell; never search for or kill other host processes.
    current_launcher_started=$(/bin/ps -p "$launcher_pid" -o lstart= 2>/dev/null || true)
    if [[ -n $launcher_started && $current_launcher_started == "$launcher_started" ]]; then
      kill -TERM "$launcher_pid" 2>/dev/null || true
    fi
    break
  fi
  sleep 0.2
done
wait "$launcher_pid" 2>/dev/null || true
trap - INT TERM HUP
cat "$log_path"
[[ ! -s $err_path ]] || cat "$err_path" >&2
if (( interrupted )); then
  print -u2 -- "virtual-display-portrait: runner interrupted; result failed and cleanup is not established by process termination"
  exit 130
fi
if (( forced )); then
  print -u2 -- "virtual-display-portrait: outer timeout/process termination; cleanup remains unverified"
  exit 3
fi
python3 - "$log_path" <<'PY'
import json, sys
prefix = "VIRTUAL-DISPLAY-PORTRAIT-JSON: "
reports = []
with open(sys.argv[1]) as handle:
    for line in handle:
        if line.startswith(prefix):
            try:
                reports.append(json.loads(line[len(prefix):]))
            except (ValueError, TypeError):
                pass
if not reports:
    print("virtual-display-portrait: no valid JSON report", file=sys.stderr)
    sys.exit(2)
result = reports[-1]
if result.get("result") == "check-only":
    sys.exit(0 if result.get("abiSupported") is True and result.get("screenRecordingGranted") is True else 2)
sys.exit(0 if result.get("result") in ("passed", "stopped") and result.get("cleanupVerified") is True else 2)
PY
