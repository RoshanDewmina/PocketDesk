#!/bin/zsh
# Local drag-to-Applications image only; no installation, notarization or publishing.
set -euo pipefail
: ${FARSIDE_DISTRIBUTION_APP:?Set an absolute signed app path}
: ${FARSIDE_DMG_OUTPUT:?Set a fresh absolute DMG path}
: ${FARSIDE_DEVELOPER_ID:?Set the Developer ID Application identity}
[[ "$FARSIDE_DISTRIBUTION_APP" == /* && -d "$FARSIDE_DISTRIBUTION_APP" ]] || exit 2
[[ "$FARSIDE_DMG_OUTPUT" == /* && ! -e "$FARSIDE_DMG_OUTPUT" ]] || exit 2
[[ "$FARSIDE_DEVELOPER_ID" == 'Developer ID Application:'* ]] || exit 2
codesign --verify --deep --strict "$FARSIDE_DISTRIBUTION_APP"
mkdir -p "${FARSIDE_DMG_OUTPUT:h}"
scratch=$(mktemp -d "${FARSIDE_DMG_OUTPUT:h}/dmg-work.XXXXXX")
mountpoint="$scratch/mount"
mounted=0
cleanup() {
  if (( mounted )); then hdiutil detach "$mountpoint" >/dev/null || return; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
mkdir "$scratch/content" "$mountpoint"
ditto "$FARSIDE_DISTRIBUTION_APP" "$scratch/content/Farside.app"
ln -s /Applications "$scratch/content/Applications"
printf '%s\n' 'Drag Farside to Applications, then open it. Grant Screen Recording and Accessibility when requested. Keep your iPhone or iPad on the same Wi-Fi as your Mac. Apple silicon and macOS 26 or later required.' > "$scratch/content/Install.txt"
hdiutil create -volname 'Farside for Mac' -srcfolder "$scratch/content" -format UDRW "$scratch/layout.dmg" >/dev/null
hdiutil attach -nobrowse -noautoopen -mountpoint "$mountpoint" "$scratch/layout.dmg" >/dev/null
mounted=1
# Configure only this mounted disk's Finder window; never open the application.
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Farside for Mac"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 150, 760, 490}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set position of item "Farside.app" to {140, 130}
    set position of item "Applications" to {410, 130}
    set position of item "Install.txt" to {275, 255}
    update without registering applications
    close
    delay 2
  end tell
end tell
APPLESCRIPT
sync
hdiutil detach "$mountpoint" >/dev/null
mounted=0
hdiutil convert "$scratch/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$FARSIDE_DMG_OUTPUT" >/dev/null
codesign --force --sign "$FARSIDE_DEVELOPER_ID" --timestamp "$FARSIDE_DMG_OUTPUT"
codesign --verify --strict "$FARSIDE_DMG_OUTPUT"
print "Local signed DMG prepared: $FARSIDE_DMG_OUTPUT"
