# Keep Mac permissions stable across builds

Use `script/build_and_run.sh` to update the real host at `/Applications/PocketDesk Host.app`. Keep its bundle identifier `com.roshan.PocketDesk.RemoteHost`, Apple Development signing identity, and installed location stable. Do not replace this app with an ad hoc or unsigned build. Synthetic test apps must keep their separate identity.

For updates, the installer checks valid signatures and the signing team, then requires the installed and candidate apps to have exactly the same designated code requirement. It also asks macOS to verify the candidate against the installed requirement. Missing, ad hoc, build-specific, or changed identities stop the update **before the running host is stopped or replaced**. The receipt includes `identity-continuity.log`. Build-only mode does not install and does not establish permission continuity.

On a first install there is no prior identity to compare. The installer checks bundle identity and a valid non-ad-hoc team signature, but those checks alone do not prove Apple Development trust. The project config supplies the Apple Development identity; inspect that first installed signature as the baseline before approving permissions. This guard is a continuity check for local development, not a distribution or Gatekeeper assessment.

This deliberately conservative check may reject a legitimate certificate or requirement change. Review that as an intentional identity migration; do not weaken or bypass the check just to finish a build. It cannot transfer grants to a different identity, inspect the stored macOS grant, or guarantee that macOS never requests approval again.

Regression check: `python3 script/test_host_identity.py` uses the current development certificate to sign tiny temporary fixtures without launching them. It checks a changed binary with the same identity, a same-team requirement change, ad hoc signing, tampering, an unrelated identifier, a missing bundle, and the current installed/build pair. It requires the local signing certificate/private key and existing host build; it never changes installed apps or permission grants. Both the built app and the staged installation copy pass the guard before host interruption.

## What happened on 13 September 2026

Both PocketDesk switches were enabled in System Settings, but the installed host's public Screen Recording and Accessibility checks returned false. Focused macOS privacy logs explicitly rejected the existing code requirements for both services. Those saved grants referred to an older ad hoc binary hash; the current app has a valid Apple Development signature. The problem was stale build identity, not missing user setup or a reason to bypass permission checks.

Apple Developer Technical Support confirms that ad hoc identities change with the binary; see [Apple's signing-identity explanation](https://developer.apple.com/forums/thread/819406). A stable certificate-backed identity allows normal updates to remain recognizable. Our new preflight prevents silent identity changes during installation, but cannot repair the already stale records.

## One-time repair of existing stale grants

Perform this only as an explicit local permission repair, outside the build script. Quit PocketDesk Host. Reset only its affected records:

```sh
tccutil reset ScreenCapture com.roshan.PocketDesk.RemoteHost
tccutil reset Accessibility com.roshan.PocketDesk.RemoteHost
```

Open the installed `/Applications/PocketDesk Host.app`. In System Settings, approve that installed app for Screen & System Audio Recording and Accessibility (called Device Control and Data Access on the tested macOS 27 build). Add the installed app if the entry is absent. Relaunch when prompted.

Confirm the running installed app reports both permissions granted and can enumerate capture displays. Then verify real capture and a harmless, explicitly authorized input action. Enabled switches, a successful signature check, and automated offline phone tests are not substitutes for these runtime checks.

Do not reset all applications, edit the privacy database, add private Apple entitlements, or grant permissions automatically. A future certificate/team/bundle-identifier migration may need the same deliberate repair and fresh acceptance evidence.
