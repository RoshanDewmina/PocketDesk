#!/bin/zsh
# Builds an isolated distribution archive. Never replaces the installed development host.
set -euo pipefail
cd "${0:A:h:h:h}"
: ${FARSIDE_DEVELOPER_ID:?Set the full Developer ID Application identity}
: ${FARSIDE_UPDATE_PUBLIC_KEY:?Set the public Ed25519 update key}
: ${FARSIDE_RELEASE_OUTPUT:?Set a new absolute output directory}
[[ "$FARSIDE_DEVELOPER_ID" == 'Developer ID Application:'* ]] || { print -u2 'Developer ID Application required'; exit 2; }
[[ "$FARSIDE_RELEASE_OUTPUT" == /* && ! -e "$FARSIDE_RELEASE_OUTPUT" ]] || { print -u2 'Use a fresh absolute output path'; exit 2; }
mkdir -p "$FARSIDE_RELEASE_OUTPUT"
lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj \
  -scheme PocketDeskRemoteHost -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$FARSIDE_RELEASE_OUTPUT/Farside.xcarchive" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$FARSIDE_DEVELOPER_ID" \
  FARSIDE_UPDATE_PUBLIC_KEY="$FARSIDE_UPDATE_PUBLIC_KEY" OTHER_CODE_SIGN_FLAGS='--timestamp' archive \
  > "$FARSIDE_RELEASE_OUTPUT/archive.log" 2>&1
app="$FARSIDE_RELEASE_OUTPUT/Farside.xcarchive/Products/Applications/PocketDeskRemoteHost.app"
codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app" > "$FARSIDE_RELEASE_OUTPUT/entitlements.plist" 2>/dev/null
python3 script/release/validate_archive.py "$app"
print 'Archive prepared. Notarization, publishing and installed identity migration are separate gates.'
