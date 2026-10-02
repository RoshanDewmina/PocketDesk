# Batch 7 release preparation — 2 October 2026

This lane prepares version 1.0 / build 20261002.2 from `20aded1` in
`~/Developer/farside-b7-release`. Universal iPhone/iPad and Apple silicon Mac
support are the explicit current decisions. No version bump, installation,
App Store Connect interaction, app upload, Beta App Review submission or download
publication is authorized. Mac notarization is expressly approved.

The exact commands, logs, hashes, tester copy and acceptance status belong in
`~/Documents/Codex/2026-10-01/release/20261002.2/RELEASE-NOTES.md`; lane continuity is
`~/Documents/Codex/2026-10-01/perf-push/b7-release/NOTES.md`. These artifacts use
`/Volumes/Studio/Development/Caches/b7-release/DD`, the shared `lockf -k` lock,
quiet/build gates, and the 10 GiB internal free-space floor. The gate is checked
again after acquiring the lock. The installed host and real devices are untouched.

`RemotePhone/Info.plist` now declares `ITSAppUsesNonExemptEncryption = YES`.
Bundled WebRTC implements DTLS/SRTP outside Apple's OS. France has not been
excluded; [Apple's documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
requires a French declaration for this combination if distributing in France.
No declaration, Apple clearance or compliance code is available. The owner must
resolve the France scope/documentation before beta distribution; this is an
additional gate beyond upload approval. Detailed source inventory and current
primary-source links are in the release directory's `EXPORT-COMPLIANCE.md`.

Release defaults retain production service origins and disabled purchases.
DEBUG harnesses and derived development entitlement-service origins are excluded;
authenticated pairing still supports custom service origins by design. Source
checks do not replace inspection of the signed exported IPA. Signing/provisioning
updates are authorized for local export, which uses `app-store-connect` with
`destination=export` and preserves the version/build.

`script/release/package-mac-dmg.sh` makes a local, signed drag-to-Applications DMG
from an already signed app. It performs no installation or publication. The
approved workflow reuses `notarize-mac.sh` for the app, packages its staple, then
separately notarizes and staples the final DMG. Both exact artifacts must pass
signature, staple and Gatekeeper checks. Automatic updates remain disabled;
Sparkle update-feed publication/signing is outside this private beta preparation.

Fresh Apple Xcode 27 release notes and notarization documentation were fetched
via their HTTPS Markdown endpoints. Local SDKs are iOS/macOS 27.0; deployment
targets stay 26.0. Dependencies remain WebRTC 153.0.0 and Sparkle 2.10.0. This
packaging change introduces no new OS API or SDK-27-only runtime requirement.
