#!/bin/zsh
# Produces a local archive only. Does not create profiles, upload or submit for review.
set -euo pipefail
cd "${0:A:h:h:h}"
: ${FARSIDE_RELEASE_OUTPUT:?Set a new absolute output directory}
[[ "$FARSIDE_RELEASE_OUTPUT" == /* && ! -e "$FARSIDE_RELEASE_OUTPUT" ]] || { print -u2 'Use a fresh absolute output path'; exit 2; }
mkdir -p "$FARSIDE_RELEASE_OUTPUT"
lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj \
  -scheme PocketDeskRemote -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$FARSIDE_RELEASE_OUTPUT/Farside-iOS.xcarchive" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY='Apple Distribution' archive \
  > "$FARSIDE_RELEASE_OUTPUT/archive.log" 2>&1
app="$FARSIDE_RELEASE_OUTPUT/Farside-iOS.xcarchive/Products/Applications/PocketDeskRemote.app"
codesign --verify --deep --strict "$app"
python3 script/release/validate_archive.py "$app"
print 'iPhone/iPad archive prepared locally. Export, TestFlight and App Store submission remain separate gates.'
