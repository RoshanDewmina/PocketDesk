#!/bin/zsh
# Read-only preflight. Never repair or reset macOS permission records here.
set -euo pipefail
if (( $# != 2 )); then
  print -u2 'Usage: verify_host_identity.sh INSTALLED_APP CANDIDATE_APP'
  exit 2
fi
requirements=()
teams=()
for candidate in "$@"; do
  [[ -d "$candidate" && ! -L "$candidate" ]] || { print -u2 'Expected a regular app bundle.'; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")" == com.roshan.PocketDesk.RemoteHost ]] || { print -u2 'Unexpected host bundle identifier.'; exit 1; }
  /usr/bin/codesign --verify --deep --strict "$candidate"
  identity="$(/usr/bin/codesign -dv "$candidate" 2>&1)"
  team="$(print -r -- "$identity" | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
  [[ -n "$team" && "$team" != 'not set' && "$identity" != *'Signature=adhoc'* ]] || { print -u2 'A stable development-team signature is required.'; exit 1; }
  requirement="$(/usr/bin/codesign -d -r- "$candidate" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
  [[ -n "$requirement" && "$requirement" != *cdhash* ]] || { print -u2 'Missing or build-specific signing requirement; installation stopped.'; exit 1; }
  teams+=("$team")
  requirements+=("$requirement")
done
# Intentionally conservative: even an equivalent rewritten requirement requires
# explicit migration review, rather than silently replacing the trusted host.
if [[ "${teams[1]}" != "${teams[2]}" || "${requirements[1]}" != "${requirements[2]}" ]]; then
  print -u2 'Host signing identity changed; installation stopped before touching the running app.'
  print -u2 'See Docs/MAC-PERMISSION-IDENTITY.md for an intentional identity migration.'
  exit 1
fi
# -R= passes literal requirement text, not a filename or shell expression.
/usr/bin/codesign --verify --deep --strict "-R=${requirements[1]}" "$2"
print 'Host signing identity is unchanged. Permission grants still require runtime verification.'
