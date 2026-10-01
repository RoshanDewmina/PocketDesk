#!/bin/zsh
# Proves a built Mac host carries none of the gated prototypes (Docs/prototypes/PROTOTYPE-GATES.md).
# Usage: verify-prototype-exclusion.sh /path/PocketDeskRemoteHost.app                 Release: exit 1 on any marker
#        verify-prototype-exclusion.sh --expect-debug /path/PocketDeskRemoteHost.app  Debug: entry markers must be found
# Every Mach-O image in the bundle is read three ways: raw bytes, `strings -a` and `nm -a`.
# Read-only: no build, launch, signing or install.
# Every marker must exceed 15 UTF-8 bytes: shorter Swift literals are small strings encoded in instructions,
# invisible to any byte or `strings` scan.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C

expect_debug=0
if [[ "${1:-}" == --expect-debug ]]; then expect_debug=1; shift; fi
app="${1:-}"
if [[ $# -ne 1 || "$app" != *.app || ! -d "$app" ]]; then
  print -u2 'usage: verify-prototype-exclusion.sh [--expect-debug] /absolute/path/PocketDeskRemoteHost.app'
  exit 2
fi
app="${app:A}"

# X24 device-matched virtual display: DEBUG-only private CGVirtualDisplay prototypes and their entry points.
virtual_markers=(--virtual-display-portrait VIRTUAL-DISPLAY-PORTRAIT-JSON: VirtualDisplayPortraitPrototype
                 CGVirtualDisplayDescriptor CGVirtualDisplaySettings CGVirtualDisplayMode CGVirtualDisplay
                 --virtual-display-spike)
# X22 relay FlexFEC send: the host preference key, anywhere in the bundle.
repair_markers=(farsideRelayPacketRepair)
# X22 field trial. The vendored WebRTC.framework defines these itself (the receiver path needs it), so they
# are prototype markers only when Farside's own images reference them.
trial_markers=(WebRTC-FlexFEC-03 kRTCFieldTrialFlexFec03Key kRTCFieldTrialFlexFec03AdvertisedKey)
# A Debug build must expose these from its own executables, or the scanner itself is not trusted.
debug_required=(--virtual-display-portrait VIRTUAL-DISPLAY-PORTRAIT-JSON: farsideRelayPacketRepair kRTCFieldTrialFlexFec03Key)

is_macho() {
  local magic
  magic=$(head -c 4 "$1" 2>/dev/null | xxd -p) || return 1
  [[ "$magic" == (feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca) ]]
}

hits_in() {
  local file="$1"; shift
  local -a patterns found
  local marker
  for marker in "$@"; do patterns+=(-e "$marker"); done
  found=(${(f)"$( { grep -a -o -F "${patterns[@]}" "$file"; strings -a "$file" | grep -o -F "${patterns[@]}"; nm -a "$file" 2>/dev/null | grep -o -F "${patterns[@]}"; } | sort -u )"})
  print -l -- $found
}

images=0
failures=0
debug_found=()
while IFS= read -r -d '' file; do
  is_macho "$file" || continue
  images=$((images + 1))
  relative="${file#$app/}"
  markers=($virtual_markers $repair_markers)
  [[ "$relative" == */WebRTC.framework/* ]] || markers+=($trial_markers)
  found=(${(f)"$(hits_in "$file" $markers)"})
  if (( ${#found} )); then
    print "HIT  $relative: ${(j:, :)found}"
    [[ "$relative" == Contents/MacOS/* ]] && debug_found+=($found)
    (( expect_debug )) || failures=$((failures + 1))
  else
    print "ok   $relative"
  fi
done < <(find "$app" -type f -print0)

if (( images == 0 )); then print -u2 'FAIL: no Mach-O images found'; exit 1; fi
if (( expect_debug )); then
  missing=(${debug_required:|debug_found})
  if (( ${#missing} )); then
    print "FAIL Debug control: $images Mach-O images; expected markers missing from Contents/MacOS: ${(j:, :)missing}"
    exit 1
  fi
  print "PASS Debug control: $images Mach-O images; Contents/MacOS exposes ${(j:, :)debug_required}"
  exit 0
fi
if (( failures )); then
  print "FAIL Release exclusion: $failures of $images Mach-O images carry prototype markers"
  exit 1
fi
print "PASS Release exclusion: $images Mach-O images, no prototype markers"
