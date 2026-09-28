# Apple Developer portal setup - 2026-09-28

Status after the second run (signed in): BOTH TASKS STILL OPEN. Nothing was submitted, registered, created, or changed on the Apple Developer portal.

## Run history

1. First run: the portal redirected to sign-in. The agent stopped and did not sign in.
2. Second run, after you signed in: the entitlement form and the Identifiers page both loaded. Task 1 hit required form fields the agent has no values for. Task 2 was stopped by a permission guard. Details below.

## Task 1 - Persistent Content Capture entitlement request

Status: NOT submitted. The agent stopped on missing required fields.

Form: `https://developer.apple.com/contact/request/persistent-content-capture/` (linked from Apple's entitlement documentation page). It is signed in as Roshan Silva Pulle, organization "Roshan Dewmina Imalsha Silva Pulle - 39HM2X8GS6". The name, email and organization fields prefill and are read-only.

Every field below is required. The only edit made in the form was selecting "Yes" in the first dropdown, and that was never saved or submitted.

| Field | Value to enter | Status |
|---|---|---|
| Website | none | MISSING. No Farside domain exists yet (docs say `[TO FILL domain]`). |
| App Name | Farside | ready |
| App Store URL | none | MISSING. The iOS app has no live App Store listing. |
| App Apple ID | none | MISSING. No App Store Connect app record ID was found in the project docs. |
| Bundle ID | com.roshan.PocketDesk.RemoteHost | ready |
| Primary functionality is remote control of authorized devices? | Yes | ready |
| How does the app support remote device content capturing? | Screen sharing and remote control | ready |
| Does the app support initiating interaction with authorized remote devices that may be inaccessible? | Yes | ready (a third dropdown, full wording truncated in the page read) |
| Explain usage and functionality (textarea, 2000 char max) | text below | ready, 1301 chars |
| Agreement checkbox (`chk_agree`, required) | tick | not touched |

The three missing values were not invented or replaced with placeholders. Apple's form asks for an App Store URL and App Apple ID, so an app with no listing yet may not fit the form well. Decide whether to submit later, once there is a website and an App Store Connect record.

### Justification text (ready to paste, NOT submitted)

Coordinator corrections applied: revocation is verified in code (RemoteCoordinator.revoke(), BrowserPeerController), and the storage claim uses the precise DTLS-SRTP / TURN wording.

```
Farside (formerly PocketDesk) lets a person view and control their own Mac from their own iPhone or iPad. The macOS companion (bundle ID com.roshan.PocketDesk.RemoteHost, Developer ID, distributed outside the Mac App Store) captures the display with ScreenCaptureKit and receives input through Accessibility. The iOS/iPadOS app is com.roshan.PocketDesk.Remote.

The primary use is unattended access: the owner is away from the Mac and connects from their phone. Nobody is at the Mac to answer the periodic screen-capture re-approval prompt, so without persistent capture the remote session fails. Capture is requested from the remote device, not by a user at the host Mac.

Consent and control: a device can connect only after the owner pairs it by scanning a QR code and explicitly approving the pairing on the Mac. The owner can revoke a paired device at any time on the Mac. While the screen is shared, the Mac shows an always-visible menu-bar indicator, and a Stop Sharing control ends the session immediately.

Data handling: Screen content is never recorded or stored. Video is end-to-end encrypted (DTLS-SRTP) between the user's Mac and their own iPhone/iPad; when a direct connection is not possible it passes through a TURN relay that forwards encrypted packets only and cannot decrypt them.
```

## Task 2 - Push Notifications + Associated Domains, APNs key

Status: NOT done. A permission guard blocked the action, and the agent stopped without working around it.

- App ID lookup: DONE (read-only). The Identifiers list for team 39HM2X8GS6 has 15 App IDs, and none is `com.roshan.PocketDesk.Remote` or anything PocketDesk/Farside. The existing entries are Lancer, Recall, Momentum, Conduit and a wildcard. So the App ID does not exist yet and has to be created.
- Steps reached: Identifiers > (+) > App IDs > App > "Register an App ID" form (Platform: iOS, iPadOS, macOS, tvOS, watchOS, visionOS; App ID Prefix 39HM2X8GS6, Explicit selected).
- Blocked step: typing Description "Farside" and Bundle ID `com.roshan.PocketDesk.Remote` into the form, then ticking Push Notifications and Associated Domains. The Claude Code auto-mode classifier denied that batch with the reason "[Permission Grant]". Continue and Register were never clicked, so no App ID was created and no capability was changed.
- After the denial the browser tab group no longer existed. No tab was left open.
- APNs key "Farside APNs": not started, because Task 2 stopped at step (a). No `.p8` was downloaded.
  - `~/.farside-secrets/` does not exist.
  - There is no `AuthKey_*.p8` in `~/Downloads`.
- Team ID: 39HM2X8GS6 (confirmed on the portal header).
- APNs Key ID: none yet.
- App ID capabilities enabled: none yet.

## Left for you

1. Allow the App ID registration and key creation. The classifier denied a form-fill step, so either add a permission rule or do these two portal steps by hand:
   - Identifiers > (+) > App IDs > App > Description `Farside`, Explicit Bundle ID `com.roshan.PocketDesk.Remote`, enable Push Notifications and Associated Domains, Continue, Register.
   - Keys > (+) > name `Farside APNs`, enable Apple Push Notifications service (APNs), Continue, Register, then Download. The `.p8` can only be downloaded once.
2. After the `.p8` downloads, run:
   `mkdir -p ~/.farside-secrets && chmod 700 ~/.farside-secrets && mv ~/Downloads/AuthKey_*.p8 ~/.farside-secrets/ && chmod 600 ~/.farside-secrets/AuthKey_*.p8`
   The agent will not open or read the file. Record the Key ID from the portal (it also appears in the filename).
3. For the entitlement request, supply the Website, App Store URL and App Apple ID (or tell the agent to wait until they exist), then re-run. Everything else on the form is ready.
