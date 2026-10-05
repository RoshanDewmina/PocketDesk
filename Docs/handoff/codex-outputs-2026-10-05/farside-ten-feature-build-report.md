# Farside ten-feature implementation checkpoint

Nine feature implementations and the glass lenses are integrated on `codex/ten-features`. Feature 9, production virtual workspace, remains blocked by the supported-provider prerequisite. Local implementation, automated checks and independent source review are separate from physical acceptance and deployment.

| # | Feature | Implemented behavior | Remaining acceptance |
|---|---|---|---|
|1|Apps and windows|Explicit owner catalog, retained host-only targets, app/window activation with truthful result|Physical AX behavior and accessibility revocation|
|2|Focus current window|Fits a viewport to current authorized window geometry; keeps the full Mac capture|Physical pointer alignment while geometry changes|
|3|Personal shortcuts|Pin, hide, reorder, reset, and named single chords scoped to the fresh frontmost app|Physical keyboard/app switch/secure focus|
|4|Mac file browser|Explicit Mac-granted folders, paginated catalog, descriptor-bound download to existing file flow|Physical folder grant/revoke and large-file transfer|
|5|Image clipboard|Explicit image send/get, bounded PNG normalization, separate bulk namespace and commit receipt, causal ordering against automatic text|Physical image paste and replacement/cancellation|
|6|Saved task views|Owner-bound named viewport presets; explicit selection of a current display on every restore|Physical multi-monitor resize/unplug and Big Text|
|7|Job notifications|Separate completion/failure opt-ins, explicit run/exit-status hook, generic local/push events, per-run dedupe|Backend migration/deployment, APNs and real device notifications|
|8|Select text|Frozen actual presented frame, owned bounded pixels, local Vision, reviewed explicit Copy|Physical presented-frame/OCR behavior|
|9|Virtual workspace|Support investigation and Release exclusion guard; working production virtual display is NOT implemented|Documented supported creation API or licensed distributable provider|
|10|Guest viewing|Existing video-only consent path gains fingerprint/lifetime presentation and countdown|Hosted guest end-to-end flow and expiry on devices|

The reading magnifier and precision glass lens are included in the integration baseline.

## Boundaries

Workspace tools require current paired-owner, full-display control authority. Narrowed scopes, guests, view-only sessions, concealment, screen lock and retired sessions do not obtain access. Catalog titles/file labels stay transient. Stored views/shortcuts contain no screenshots, content, stable window handles or replayable input grants.

Image clipboard initially supports a single normalized raster image plus existing plain text. Styled attributed text, HTML/RTFD and arbitrary attachments are deferred. Saved views restore viewport/display placement while retaining current streaming preferences. A physical-desktop crop is not counted as the virtual workspace. Image processing is limited to one callback lifetime across cancel/reopen; a hung OS provider may still retain its queued image until it returns. OS provider materialization is outside Farside's own buffer bounds, so this checkpoint does not claim total memory purging on cancellation.

## Build and review evidence

Production source and phone tests: `c9dc6cefe54568acdc2c511664a1a173811a13fc`. Core checks passed at `f964c45`; subsequent changes affect only phone image-preparation UI, its regression fixture, generated test membership and notification test expectations. No host/shared/backend production source changed after that core run.

Independent source review accepted the integrated source through `c9dc6ce`, with no remaining actionable findings. The reviewer did not run native or device checks. Findings corrected during integration included old-peer capability negotiation, browser transfer retirement during Away concealment, OCR placement drift, queued notification cancellation, and image preparation surviving cancellation/reopen.

Selected native checks passed: **215 core + 113 phone = 328**, zero failures. Core source checkpoint: `f964c45`; final phone checkpoint: `c9dc6ce`. Earlier glass baseline also passed 51 selected native checks and 2 UI checks; those are historical evidence, not added to the 328 count.

The phone run compiled the integrated simulator app. Mac **Debug and Release builds passed**, unsigned, using Xcode27.0/27A266a with unchanged OS26 deployment targets. The Release executable guard passed: none of its checked private virtual-display class names were present. This is a narrow exclusion check, not proof of a supported provider or App Store eligibility.

Two focused glass UI tests also passed on the final source: reading-lens movement/zoom/close and opening from Settings with precision-loupe visibility. Their actual test attachments supply the glass screenshots below. A checked headless snapshot supplies the shortcut page. Early blank or dismissed preview frames were rejected; the saved-view launch preview did not yield an accepted page screenshot. Source review found no actionable product issue in that fixture behavior, and its exact runtime trigger remains unproven.

The dedicated test simulator is shut down. The final branch's later edits are documentation only; production source is unchanged from the reviewed/tested checkpoint.

Backend at the integrated notification/guest checkpoint: type checking passed; 21 selected guest/push tests passed; explicit-hook fixtures passed. No server deployment or migration ran.

## Virtual workspace gate

The checked SDK headers and current Apple documentation did not establish a supported virtual-display creation route for Farside. This is a bounded investigation, not a proof that no route can exist. [DriverKit](https://developer.apple.com/documentation/driverkit), [Driver creation guide](https://developer.apple.com/documentation/driverkit/creating-a-driver-using-the-driverkit-sdk), and [ScreenCaptureKit capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) support infrastructure/capture; they do not supply the missing verified provider contract. Existing private prototypes stay Debug-only.

## Physical and external acceptance still required

- Apps/windows/shortcuts: real Accessibility grants and revocation, process relaunch, app/window switching, secure focus, chord targeting and pointer alignment.
- Files/images: folder grant/revoke, symlink/dataless behavior on real volumes, large transfer cancellation and pasteboard replacement across session/lock changes.
- Saved views/glass/OCR: display unplug/resize, Big Text settlement, reading/precision alignment and actual presented-frame OCR on physical hardware.
- Notifications/guest: deploy the authored backend migration and services, validate real APNs opt-ins/dedupe/cancellation, then verify consent, expiry and owner-session loss in a hosted guest flow.
- Virtual workspace: establish a documented supported creation route or licensed distributable provider, then implement and validate the display lifecycle. Existing Debug private prototypes are not a production substitute.

No physical-device installation, installed Mac-host update, backend deployment, database migration, live guest invitation, purchase or App Store submission occurred. The existing main checkout and unrelated changes remain preserved; integration is isolated.

## Reviewable source

[Private draft PR #1](https://github.com/RoshanDewmina/PocketDesk/pull/1), base `pocketdesk-remote-chat`, head `codex/ten-features`. The branch is backed up privately; no main merge occurred.

## Native simulator screenshots

These are actual native UI captures of the offline preview fixture, not a live Mac or physical-device acceptance.

Shortcut customization:

![Shortcut customization — native simulator](/Users/roshansilva/Documents/Codex/2026-10-05/he/outputs/farside-shortcuts-simulator.png)

Reading glass at 3×, after the UI test moved and zoomed it:

![Reading glass — native simulator](/Users/roshansilva/Documents/Codex/2026-10-05/he/outputs/farside-glass-simulator.png)

Precision tap:

![Precision tap — native simulator](/Users/roshansilva/Documents/Codex/2026-10-05/he/outputs/farside-precision-simulator.png)
