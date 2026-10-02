#!/bin/zsh
# Runs after framework embedding, before Xcode seals the host app. Never signs --deep.
# Sparkle 2.6+ guidance: https://sparkle-project.org/documentation/sandboxing/#code-signing
set -euo pipefail
[[ "${CONFIGURATION:-}" == Release && "${CODE_SIGNING_ALLOWED:-NO}" == YES ]] || exit 0
[[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == 'Developer ID Application:'* ]] || exit 0
: ${TARGET_BUILD_DIR:?Xcode build directory required}
: ${WRAPPER_NAME:?Xcode app wrapper required}
app="$TARGET_BUILD_DIR/$WRAPPER_NAME"
[[ "$app" != /Applications/* && "$app" != /System/* ]] || { print -u2 'Refusing installed app signing'; exit 2; }
framework="$app/Contents/Frameworks/Sparkle.framework"
sparkle="$framework/Versions/B"
identity="$EXPANDED_CODE_SIGN_IDENTITY_NAME"
for item in "$sparkle/XPCServices/Installer.xpc" "$sparkle/XPCServices/Downloader.xpc" "$sparkle/Autoupdate" "$sparkle/Updater.app"; do
  [[ -e "$item" ]] || { print -u2 "Missing Sparkle code: $item"; exit 2; }
done
codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/XPCServices/Installer.xpc"
# Downloader's sandbox/network entitlements belong only to this XPC service.
codesign --force --sign "$identity" --options runtime --timestamp --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/Autoupdate"
codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/Updater.app"
codesign --force --sign "$identity" --options runtime --timestamp "$framework"
codesign --verify --deep --strict "$framework"
