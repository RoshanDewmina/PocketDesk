# Farside — bulk test batch 1

Candidate build: **20260930.8** on phone and Mac host. Installed code: `a8854ee` (Claude cut-8 on top of `35372ac`: reliable input checkpoint resend). Automated results, install receipts and known issues: `~/Documents/Codex/2026-09-30/re/BULK-TEST-1-READY.md`. All13 source review findings have a mapped fix or explicit legacy re-pair path; runtime results remain pending.

Roshan chose everything close to done. Claude reviews and drives the bulk round; run all MIRROR checks together, then all HANDS checks in the grouped pass below. Record PASS / FAIL / BLOCKED and a short receipt next to each line. Automated fixtures, simulator/UI results, installed identity and physical behavior are separate evidence. Do not count a simulated success as a device success.

Boundary: no backend deployment, production changes, App Store Connect changes, publication, purchases or messages. Cloudflare operational commands only on the PC. Guest backend is integrated and locally tested; no new endpoint has been deployed. Away defaults off and Release excludes both the Away preview and private portrait experiment. Timing/camera, network tuning, true120fps, lifetime/founder sales, store listing and website work are outside this batch.

## Automated checks before the cut

- [ ] [AUTO] Full core suite passes; record actual executed/skipped/failure counts and source/binary pin, including native encode/decode, route/transfer retirement, scope, Big Text, Awake, expired/disabled/driver/lease input recovery,256KiB bounded motion queues, geometry negotiation races,240Hz pressure order and temporary interruption fixtures.
- [ ] [AUTO] Phone unit suite passes; record exact executed/skipped/excluded counts, StoreKit test-only cases, terminal admission replay, PiP lifecycle, idle-timer/transfer ownership, keyboard/draft, trust and resume results.
- [ ] [AUTO] Host snapshots execute and pass; inspect the actual exported setup, settings, sharing and permission states; Away warnings and Vitals acceptance are checked in the device groups below.
- [ ] [AUTO] Targeted simulator UI passes Big Text progress/Off, Couch caption/card, dock gesture/commands, keyboard first position, background concealment/draft preservation and Mac Vitals.
- [ ] [AUTO] Local backend full suite (including21-minute remote renewal/Couch refusal fixtures) and typecheck pass; no deploy or live provider assertion follows.
- [ ] [AUTO] Exact owned Metal shader compiles both actual public runtime pipelines; missing offline component uses the verified runtime compiler and the safe stock fallback, with unavailable fallback timing.
- [ ] [AUTO] Debug host/phone signatures and bundle versions match20260930.8; Release host binary excludes portrait SPI/test entry, while DEBUG includes it.
- [ ] [AUTO] Signed Mac update passes the existing designated-requirement continuity guard; signed iPhone17 update succeeds and normal launch succeeds; preserve pairing/TCC, no resets.

## Claude's MIRROR pass — harmless test apps and disposable files

### Start, identity and diagnostics

- [ ] [MIRROR] Confirm installed phone/host build20260930.8 and ordinary host readiness, pairing and owner Keep awake preference; connected, unpaused display hold is automatic even with Keep awake off; do not regrant/reset permissions automatically.
- [ ] [MIRROR] For a labelled older pairing, re-pair FIRST from a fresh owner-approved QR on the intended Mac; confirm the new pairing connects, then deliberately select and forget only its older labelled record; no name-based identity inference.
- [ ] [MIRROR] Turn on Share Mac audio on the Mac AFTER installation and after each host relaunch; this consent resets on launch.
- [ ] [MIRROR] Run preflight and Test connection to my Mac from the current session; distinguish permission/unreachable/unknown routes from a successful connection and keep the resulting diagnostic receipt.
- [ ] [MIRROR] Open the saved-Mac picker, select each available Mac and verify its identity; switching retires the old picture/input/files, and the next Mac never receives the previous draft automatically; forget the selected Mac and confirm the other saved Macs and Choose a Mac picker remain reachable.
- [ ] [MIRROR] Enable Local-only on both clients and connect on LAN with a locally unreachable test configuration or verify no cloud transport is used (do not change any production service); after restoring the user's original mode, verify normal reconnect and no inferred WAN authorization.

### Keyboard — Cmd+Tab FIRST

- [ ] [MIRROR] In two harmless Mac apps, tap toolbar Command then Tab FIRST, then plain `a` and click; confirm one app switch and no stuck Command/Shift/Option/Control; the current implementation sends complete atomic chords.
- [ ] [MIRROR] Test Exact Text with multiline, accents/emoji/IME and a long disposable draft; ACK/refusal/uncertain status is truthful, no duplicate resend, cancelling keeps the local draft, secure fields use the intended private delivery path.
- [ ] [MIRROR] Open/close the keyboard and Controls in portrait/landscape; modifiers/draft/Hide remain reachable, draft-local keys arrive once, returning to remote control routes keys correctly.
- [ ] [MIRROR] Tap/release/cancel chords, close the keyboard, change view/scope, background/return and End; immediately type plain text afterward and verify no held modifier survives.

### Picture, navigation and readable text

- [ ] [MIRROR] Fit/Fill and View/Control switch correctly; Focus/Precision loupe and mini-map show only current authorized pixels and clear on End/scope/privacy changes without resurrecting cached admissions.
- [ ] [MIRROR] Verify owned H.264 and basic HEVC on the negotiated route; record codec/decoded dimensions and actual fallback, not a configured target interpreted as measured performance; leave full-color HEVC and120fps experiments outside this round.
- [ ] [MIRROR] Smooth motion Off/Auto/High changes behave, the dock opens/closes without stealing the intended gesture, and redraw/interpolation is not reported as unique source FPS.
- [ ] [MIRROR] Big Text changes one saved step, acknowledges its exact request, turns Off/restores and respects a newer manual Mac mode/window placement; verify Peirce P1/P2 ownership fixes on a disposable window.
- [ ] [MIRROR] Couch shows its trackpad/key row and truthful caption, accepts harmless pointer/keyboard actions, and exposes no picture-fit or privacy-curtain controls.
- [ ] [MIRROR] Share one disposable app/window; other apps/desktop remain excluded, control/audio/file restrictions are shown, target close or scope change clears old output and queued actions.

### Audio, clipboard and files

- [ ] [MIRROR] Explicit Listen delivers Mac system audio with no phone/microphone audio sent to the Mac; mute/end/scope change restores silence; video/input remain responsive while listening.
- [ ] [MIRROR] Explicit text/URL clipboard both ways works after consent; decline/cancel/background/revoke discards pending writes; proposed clipboard images are not implemented (use file sharing).
- [ ] [MIRROR] File drop both ways accepts/declines/cancels correctly for a512KiB checksum fixture and a disposable50MB file with measured elapsed time/checksum; observe simultaneous video/audio/control responsiveness; old transfer completion cannot write to a newer session or dim a live phone session.
- [ ] [MIRROR] Send to My Mac share extension stages and sends one item/link to the selected current Mac; expired/declined/stale items require a new action and never target a different Mac.

- [ ] [MIRROR] During harmless relative motion/typing, briefly disrupt the test LAN for300ms/1s; no stale text auto-replay, no stuck hold, Mac Sharing remains on, current input rebases or phone reconnects normally; do not change production networking.

### Resume, quality and summaries

- [ ] [MIRROR] App-switch returns at5/20/40s restore the capsule/display/viewport/draft appropriately; a longer interruption reconnects deliberately, background is concealed and End never auto-resumes.
- [ ] [MIRROR] After idle reading, burst scroll repeatedly on clean LAN and confirm no false Wi-Fi stall banner; a clean moving LAN session has no false quality warning; dismiss/reconnect/display changes reset the intended evidence; Wi-Fi stall advice is an optional phone/Mac AirDrop hint only when the selected LAN interface evidence supports that target and never claims measured AWDL causation.
- [ ] [MIRROR] Mac Vitals unknown/stale/battery/thermal states are honest; end a session and inspect its post-session report, consent-controlled useful-session feedback and copied diagnostic data for unintended private content.
- [ ] [MIRROR] Guest-view preparation and owner approval/revocation controls preserve view-only limits; without an approved available test endpoint mark live links BLOCKED, use existing local/injected receipts, and do not deploy.

## Roshan's HANDS pass — do these together once

### iPhone and Mac

- [ ] [HANDS] Two-finger pinch in Control and View: one stationary finger/both moving/edges/repeated pinch/rotation/interruption then Fit; Roshan already confirmed the earlier82fd927 zoom fix smooth, now check the combined build for regressions.
- [ ] [HANDS] Enter foreground View-only + Listen, leave both devices untouched for10+minutes and past their normal auto-lock/dim/screensaver thresholds and confirm the phone stays lit, the Mac display assertion remains held even with idle Keep awake OFF and the session/audio continues; then End/background and confirm normal idle behavior returns.
- [ ] [HANDS] With headphones, mute/unplug/replug/interruption/dictation/End: brief Control Center/Siri/alert interruptions resume only the same live opted-in audio after OS allows resume; route change, unplug/replug, dictation, End, background and revoked consent do not auto-resume; no recording or residual sound after retirement.
- [ ] [HANDS] Explicitly start live view-only PiP, hold Control Center open>0.25s, Home/app-switch and PiP Return to App/OS close/pause/End/lock/revoke; video survives authorized background where supported, controls/files/audio retire, failed start is honest, exit ACK is bounded and resumed audio requires a fresh Listen.
- [ ] [HANDS] If a second owned Mac is available, select/reconnect/remove it and first-time offline-LAN enrollment; otherwise record the multi-machine acceptance BLOCKED rather than pretend picker fixtures prove it.

- [ ] [HANDS] On a disposable pairing/spare test Mac, use Mac-side Remove Phone, relaunch the host and confirm the removed credential stays absent and cannot reconnect; if Keychain refuses both deletion and verified tombstone, report failure and retain sharing-off state. Keep the desk pairing intact unless Roshan deliberately chooses to re-pair.

### iPad peripherals

- [ ] [HANDS] On a physical iPad in fullscreen (not Stage Manager), mouse lock gives relative motion within its gate; escape/unlock/keyboard disconnect/background/End release pointer and modifiers; spot-check ordinary indirect clicks across the app; system-reserved Cmd+Tab is distinguished from the Control+Option+Tab alternative.
- [ ] [HANDS] On disposable text, hold arrows/Delete then release/change modifier/disconnect; repeat stops, no sticky key survives; held multi-Tab switcher/native Mac repeat timing and toolbar parity from the recovered D43 proposal remain unimplemented.
- [ ] [HANDS] Physical Pencil pressure/hover/palm/cancel/rotation/End maps safely in a disposable drawing app; unsupported combinations fail honestly, no post-End stroke.

### Away, wake, portrait and Watch — controlled physical checks last

- [ ] [HANDS] Keep Away off for ordinary tests; for S1/S2 only enable the DEBUG preview gate explicitly, use the documented local escape/injection separation and positive Lock Screen verification, test End & Lock and unexpected disconnect, then disable the gate; a cover is not a verified OS lock.
- [ ] [HANDS] Check display sleep/wake, Mac lock and owner availability/login/Keep awake choices; wake packet transmission is not wake proof, and unsupported powered-off/closed-lid/provider cases remain BLOCKED.
- [ ] [HANDS] Run the separate DEBUG portrait check/interactive test entry, Start/Stop one synthetic portrait display and verify exact owned disappearance; do not use Release or call this full authenticated phone workspace; leave the test open if cleanup is pending.
- [ ] [HANDS] Check Watch's supported small Live Activity/glance freshness and End state; there is no standalone Watch app/control, and actual remote APNs/notification delivery remains BLOCKED when provider configuration is unavailable.

## Known limits and record

Lifetime and founder sales remain disabled by default. The historical D43 plan includes held Command multi-Tab switching, native repeat timings/leases, toolbar parity and clipboard images; those are not present in this batch's atomic keyboard path. Advanced network tuning, exact timing/camera, true120fps and offer sales are deferred. Experimental portrait is an isolated synthetic-window test, not a production virtual desktop. Away's physical security acceptance and release gate remain open. Real background PiP, audio/route privacy, input peripherals and provider delivery need the above device receipts.

Failures are retained from earlier checkpoints; final automated results and installed artifact receipts belong here before the READY notice. Record the integration commit and main installation commit separately if the preserved main checkout has a merge commit. No performance claim is made while build/simulator load is running.
