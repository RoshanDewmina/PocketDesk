#!/bin/zsh
# Run only after explicit approval of this exact artifact's Apple notarization submission.
set -euo pipefail
: ${FARSIDE_NOTARIZATION_APPROVED:?Set YES only after owner approval for this exact submission}
: ${FARSIDE_DISTRIBUTION_APP:?Set the absolute archived Developer ID app path}
: ${FARSIDE_NOTARY_PROFILE:?Set an existing notarytool Keychain profile name}
: ${FARSIDE_NOTARY_OUTPUT:?Set a fresh absolute receipt directory}
[[ "$FARSIDE_NOTARIZATION_APPROVED" == YES ]] || exit 2
[[ "$FARSIDE_DISTRIBUTION_APP" == /* && -d "$FARSIDE_DISTRIBUTION_APP" ]] || exit 2
[[ "$FARSIDE_NOTARY_OUTPUT" == /* && ! -e "$FARSIDE_NOTARY_OUTPUT" ]] || exit 2
codesign --verify --deep --strict "$FARSIDE_DISTRIBUTION_APP"
identity="$(codesign -dv "$FARSIDE_DISTRIBUTION_APP" 2>&1)"
[[ "$identity" == *'Authority=Developer ID Application:'* && "$identity" == *'runtime'* ]] || { print -u2 'A hardened Developer ID application is required'; exit 2; }
mkdir -p "$FARSIDE_NOTARY_OUTPUT"
ditto -c -k --keepParent "$FARSIDE_DISTRIBUTION_APP" "$FARSIDE_NOTARY_OUTPUT/Farside.zip"
xcrun notarytool submit "$FARSIDE_NOTARY_OUTPUT/Farside.zip" --keychain-profile "$FARSIDE_NOTARY_PROFILE" --wait --output-format json > "$FARSIDE_NOTARY_OUTPUT/submission.json"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status") == "Accepted" else 1)' "$FARSIDE_NOTARY_OUTPUT/submission.json"
xcrun stapler staple "$FARSIDE_DISTRIBUTION_APP" > "$FARSIDE_NOTARY_OUTPUT/staple.log" 2>&1
xcrun stapler validate "$FARSIDE_DISTRIBUTION_APP" >> "$FARSIDE_NOTARY_OUTPUT/staple.log" 2>&1
spctl --assess --type execute --verbose=2 "$FARSIDE_DISTRIBUTION_APP" > "$FARSIDE_NOTARY_OUTPUT/gatekeeper.log" 2>&1
print 'Notarization accepted and staple validated. Publishing and installed identity migration remain separate gates.'
