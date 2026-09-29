#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
receipt="${POCKETDESK_RECEIPTS:-$PWD/outputs/remote-check-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$receipt"
xcodegen generate > "$receipt/project-generation.log" 2>&1
(cd Server && bun test) > "$receipt/service-tests.log" 2>&1
xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -configuration Debug -derivedDataPath outputs/RemoteBuild build > "$receipt/host-build.log" 2>&1
for resource in Doto-Variable.ttf InstrumentSerif-Italic.ttf OFL-Doto.txt OFL-InstrumentSerif.txt; do
  [[ -f "outputs/RemoteBuild/Build/Products/Debug/PocketDeskRemoteHost.app/Contents/Resources/$resource" ]] || { print -u2 "The host app is missing $resource"; exit 1; }
done
xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -configuration Debug -destination 'generic/platform=iOS Simulator' ARCHS=arm64 -derivedDataPath outputs/RemoteBuild build > "$receipt/phone-build.log" 2>&1
xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -configuration Debug -destination 'platform=macOS' -derivedDataPath outputs/RemoteBuild build-for-testing > "$receipt/core-build.log" 2>&1
xcrun xctest outputs/RemoteBuild/Build/Products/Debug/RemoteCoreTests.xctest > "$receipt/core-tests.log" 2>&1
print "Remote checks passed. Receipts: $receipt"
# Set this only when an iPhone simulator is available for native UI acceptance.
if [[ -n "${POCKETDESK_UI_SIMULATOR:-}" ]]; then
  xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote \
    -destination "id=$POCKETDESK_UI_SIMULATOR" -derivedDataPath outputs/RemoteBuild \
    -only-testing:RemotePhoneTests -only-testing:RemotePhoneUITests -collect-test-diagnostics never test \
    > "$receipt/phone-ui-tests.log" 2>&1
  print "Native phone UI acceptance passed."
fi
