#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mode="${1:-run}"
case "$mode" in run|--verify|--build) ;; *) print -u2 'Usage: build_and_run.sh [--verify|--build]'; exit 2;; esac
receipt="${POCKETDESK_RECEIPTS:-$PWD/outputs/host-run-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$receipt"
receipt="${receipt:A}"
derived="${POCKETDESK_DERIVED_DATA:-$PWD/outputs/RemoteBuild}"
derived="${derived:A}"
built="$derived/Build/Products/Debug/PocketDeskRemoteHost.app"
installed='/Applications/PocketDesk Host.app'
executable='PocketDeskRemoteHost'
bundle_id='com.roshan.PocketDesk.RemoteHost'

# A failed build leaves the installed app running.
xcodegen generate > "$receipt/project-generation.log" 2>&1
xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -configuration Debug -derivedDataPath "$derived" build > "$receipt/host-build.log" 2>&1
if [[ "$mode" == --build ]]; then
  print "Mac build passed. Receipts: $receipt"
  exit 0
fi

verify_bundle() {
  local candidate="$1"
  [[ ! -L "$candidate" && -d "$candidate" ]] || { print -u2 "Expected a regular app bundle: $candidate"; return 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")" == "$bundle_id" ]] || { print -u2 'Refusing to replace an unrelated application.'; return 1; }
  codesign --verify --deep --strict "$candidate" || return 1
  local identity
  identity="$(codesign -dv "$candidate" 2>&1)" || return 1
  [[ "$identity" == *'TeamIdentifier='* && "$identity" != *'TeamIdentifier=not set'* && "$identity" != *'Signature=adhoc'* ]] || { print -u2 'A development-team signature is required for the installed host.'; return 1; }
}
verify_bundle "$built" > "$receipt/built-signature.log" 2>&1
if [[ -e "$installed" || -L "$installed" ]]; then
  verify_bundle "$installed" > "$receipt/previous-signature.log" 2>&1
  built_team="$(codesign -dv "$built" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  previous_team="$(codesign -dv "$installed" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$built_team" == "$previous_team" ]] || { print -u2 'Installed and built signing teams differ; installation stopped.'; exit 1; }
  if ! /bin/zsh script/verify_host_identity.sh "$installed" "$built" > "$receipt/identity-continuity.log" 2>&1; then
    cat "$receipt/identity-continuity.log" >&2
    exit 1
  fi
fi
[[ -w /Applications ]] || { print -u2 '/Applications is not writable; installation stopped.'; exit 1; }
install_record="$(mktemp -d "$receipt/host-install.XXXXXX")"
staged="$install_record/PocketDesk Host.app"
previous="$install_record/previous-PocketDesk-Host.app"
ditto "$built" "$staged"
verify_bundle "$staged" > "$receipt/staged-signature.log" 2>&1
if [[ -e "$installed" || -L "$installed" ]]; then
  if ! /bin/zsh script/verify_host_identity.sh "$installed" "$staged" > "$receipt/staged-identity-continuity.log" 2>&1; then
    cat "$receipt/staged-identity-continuity.log" >&2
    exit 1
  fi
fi

# Match executable identity before stopping or accepting a launch.
matching_pids() {
  local bundle="$1" process_id process_path
  for process_id in $(pgrep -x "$executable" || true); do
    process_path="$(ps -p "$process_id" -o comm= || true)"
    [[ "$process_path" != "$bundle/Contents/MacOS/$executable" ]] || print "$process_id"
  done
}
stop_copy() {
  local bundle="$1" process_id attempt
  for process_id in $(matching_pids "$bundle"); do
    kill -TERM "$process_id" || return 1
    for attempt in {1..30}; do
      kill -0 "$process_id" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$process_id" 2>/dev/null; then
      print -u2 "Host did not quit: $bundle. No forced termination performed."
      return 1
    fi
  done
}
verify_launch() {
  local bundle="$1" attempt found
  for attempt in {1..40}; do
    found="$(matching_pids "$bundle")"
    if [[ -n "$found" ]]; then
      sleep 0.5
      [[ "$(matching_pids "$bundle")" == "$found" ]] && return 0
    fi
    sleep 0.1
  done
  return 1
}
install_pending=0
previous_expected=0
restore_on_failure() {
  local result="$1"
  trap - EXIT HUP INT TERM
  if (( install_pending )); then
    print -u2 'Installation or launch failed; restoring the previous installed copy.'
    if (( previous_expected )) && [[ ! -e "$previous" ]]; then
      print -u2 'The previous copy was not moved; its installed files were preserved.'
      open "$installed" && verify_launch "$installed" || true
      exit 1
    fi
    if ! stop_copy "$installed"; then
      print -u2 "Could not stop the candidate safely. Previous copy remains at: $previous"
      exit 1
    fi
    if [[ -e "$installed" ]]; then
      mv "$installed" "$install_record/rejected-PocketDesk-Host.app" || exit 1
    fi
    if [[ -e "$previous" ]]; then
      mv "$previous" "$installed" || exit 1
      if open "$installed" && verify_launch "$installed"; then
        print -u2 'Previous installed app restored and its launch verified.'
      else
        print -u2 'Previous installed app restored, but its launch could not be verified.'
      fi
    else
      print -u2 'No previous installed copy existed. Failed candidate retained in the receipt folder.'
    fi
    (( result != 0 )) || result=1
  fi
  exit "$result"
}
trap 'restore_on_failure $?' EXIT
trap 'restore_on_failure 130' HUP INT TERM

# Build and signature checks precede interruption of the running host.
stop_copy "$built"
stop_copy "$installed"
[[ ! -e "$installed" ]] || previous_expected=1
install_pending=1
if (( previous_expected )); then mv "$installed" "$previous" || restore_on_failure 1; fi
mv "$staged" "$installed" || restore_on_failure 1
verify_bundle "$installed" > "$receipt/installed-signature.log" 2>&1 || restore_on_failure 1
open "$installed" || restore_on_failure 1
verify_launch "$installed" || { print -u2 'Installed app launch could not be verified.'; restore_on_failure 1; }
install_pending=0
print "Built and launched $installed. Receipts: $receipt"
print 'App launch does not prove screen-capture or control permission. Check readiness in the app.'
