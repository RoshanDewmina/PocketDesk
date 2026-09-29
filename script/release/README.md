# Local launch artifact preparation

These scripts prepare local artifacts. They do not deploy the service, create paid resources, upload to App Store Connect, or publish downloads. `notarize-mac.sh` submits the exact archive to Apple only after the owner explicitly approves that submission.

## Current gates (29 September 2026)

- Staging health responds and its D1 database exists in the authenticated Cloudflare account. No production entitlement database appeared in the account inventory. The production database ID and numeric App Store app ID remain missing.
- The Mac has an Apple Development signing identity; no Developer ID Application identity was found. Distribution archives, Developer ID transition, notarization and stapling are not yet verified.
- New purchases remain disabled by `FARSIDE_SERVICE_READY=NO`, independently of the configured verification URL. Set readiness only after the intended service has passed acceptance.
- Associated-domain/AASA artifacts use `getfarside.com`; `Docs/launch/apple-app-site-association` must be served at `https://getfarside.com/.well-known/apple-app-site-association` without redirects with JSON content type. Deployment and Apple association caching have not been verified.
- Debug APNs uses development, Release uses production. The registry reads the corresponding Info value; validate the exact signed entitlement against it. Provider keys, topic capabilities and real suspended delivery need live receipts.

## Prepare

1. Copy `config.example.json` to an ignored local path and enter the confirmed public configuration and existing signing-profile names. Do not place private keys in this file.
2. Run `python3 script/release/preflight.py --config /absolute/path/config.json`. Missing inputs produce a nonzero exit and a JSON list. A passing config check is not a deployment or live-service receipt.
3. Generate the Xcode project with `xcodegen generate` from integrated main. Archive with `archive-phone.sh` and `archive-mac.sh` using fresh absolute output directories. Both use the shared Xcode lock. Existing certificates/profiles are required; scripts do not request provisioning changes.
4. Inspect the archive, generated privacy report, bundled dependency notices, architectures and signed entitlements. `validate_archive.py` checks the platform-specific bundle ID, the phone's exact production verification URL, readiness, and the embedded widget's ID, matching version/build and parseable privacy manifest. Its default `--service-ready no` accepts only plist Boolean `false` or the current build-substituted string `NO`; `--service-ready yes` accepts only Boolean `true` or string `YES`. The flag checks an existing archive; it does not change its readiness or authorize purchases. `archive-phone.sh` uses the default disabled-purchase check. Only validate a ready-mode artifact with `--service-ready yes` after the intended production service and purchase flow have separate acceptance receipts. A metadata pass never proves purchase availability, live service behavior, signing identity, or submission acceptance. Test iPhone and iPad from the exact archive. The Mac must retain hardened runtime with no library-validation exception.
5. Compare the archived Developer ID app to the installed development app with `script/verify_host_identity.sh`. A certificate/requirement transition is expected to need explicit migration review. Do not replace the installed host or reset TCC to make the comparison pass. Record clean-install and upgrade permission behavior separately on a disposable acceptance account/Mac.
6. After approval of the exact Developer ID archive, set the required notarization script variables and run `notarize-mac.sh`. It requires Apple’s Accepted response, validates the staple and Gatekeeper assessment. Make the final DMG from that stapled app, sign the update with the separately held Sparkle private key, and review its appcast before publication. No private update key is generated or stored by these scripts.

Use the existing `Docs/launch/` review, privacy, support and store-listing drafts. Update claims only from exact-build measurements; there is no verified 120 fps, production purchase, APNs suspended delivery or public download receipt yet. Run the installation and removal checklist before submission. All provider/store submissions and publication remain explicit final owner gates.
