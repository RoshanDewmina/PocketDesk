# Production editor candidate9 — 5 October 2026

Production shared the inherited native editor/secure-focus defects with the separate beta. Only the editor, secure-focus owner extension, necessary existing call-site owner argument and regression tests are ported; no Workspace/private display API, zoom or beta chrome is imported. Current native IME finalization is retained locally without synchronous teardown publication; old editor/privacy/session callbacks are rejected. Authoritative privacy retirement clears stale composition without depending on a surviving view; duplicate same-state replies preserve current IME. Explicit Send/ACK, pending-edit, secure classification, manual keyboard and default-off automatic keyboard remain unchanged.

Fresh independent production source review approves the exact four-file port. Production60 native checks pass:22 editor,3 secure-focus,31 lifecycle and4 voice. Both signed9 builds pass; actual production IDs, matching20261004.9 and extension versions, team39HM2X8GS6, deep/strict signatures and installed Mac identity continuity verify. Shared exact-source isolated negative/restoration receipts prove the introduced lifetime and owner-boundary tests can detect regressions. This is source/native/signed evidence, not a production runtime warning reproduction or physical secure-IME acceptance.

Candidate8 is integrated and privately backed up; primary41 setup/onboarding checks pass. Both production devices remain20261004.6 because the paired iPhone is currently unavailable. Matching main-checkout9 rebuild/install and physical acceptance are pending. No physical60FPS/sharpness/latency/M1, matched competitor win or App Store readiness follows from these checks.

# Production setup candidate8 — 5 October 2026

The deferred first-minute setup page now distinguishes “Finish setup later” from “Your Mac is ready.” Readiness requires an approved pairing, no pending new request, and the existing permission/view-only choices. Pair now, Close for now and menu-bar resume use the existing actions. The three-file source is independently approved; 30 presentation and 11 onboarding tests pass. Actual window rendering is pending while the Mac is locked. Both signed candidate8 builds pass. Actual production IDs, build20261004.8, team39HM2X8GS6, deep/strict signatures, both extension versions and installed Mac identity continuity verify (`work/overnight/signatures8/verification.json`). No installation or physical acceptance is claimed.

Candidate7 (`199b5dc`) is integrated into primary and pushed to the private backup. Corrected157 core and93 phone tests, meaningful duplicate/discontinuity negatives and exact-source restoration pass. Both signed7 builds and Mac installed-identity continuity pass; primary's11 feedback-window tests pass. Production devices remain20261004.6 because the phone is unavailable. These source corrections do not establish a physical60fps, sharpness or latency improvement. The Workspace/private-display beta stays separate.

# Candidate7 feedback and actual6 installation —5October2026

Production00b2b9d/20261004.6 was rebuilt from integrated primary, guardedMacidentitycontinuitypassed, phoneinstallation/inventorypassed, privateprimarypushcompleted. Physical6acceptance deferred afterMaclock. Candidate7 feedback correctness is independently sourceapproved;157core/93phonePASS, duplicate8assertionRED/exactrestore1PASS, stickyboundary18assertionRED/twoPASScontrols/exactrestore10PASS. Sourcecontract and frozenhashes retained. Signed7builds are queued; no7installationyet. Currentphoneunavailable. No sustainedphysical60FPS/sharpness/latency/M1 claim.

# Overnight quality candidate — 4 October 2026

Candidate **20261004.6**, isolated quality branch from production005fc78. User authorized autonomous reliability/performance fixes and strong GPT review while asleep. This checkpoint contains no Workspace/private display code or new quality default.

- Input4936986 synchronously cancels queued display-tick pointer movement at cancellation, including no active hold. Existing hold cleanup remains. Independent Astra source review approved.
- Recovery9202911 retains capture retirement ownership and requires confirmed cleanup before reserving a replacement producer; missing callbacks stay quarantined. Regular phone load survives auxiliary heartbeat traffic without changing epoch/authentication/age gates. Independent Astra source review approved.
- Metadata542bdd6 retains up to2048 retired wire identities for the existing5s/240FPS protocol budget; pending/weak decode buffers remain128 and overflow fails closed. Sustained60/120/240 association/replay/TTL tests and independent source review pass. This is correctness evidence, not measured FPS/latency/CPU improvement.

## Verification

Selected core **150/150 PASS**, receipt `work/overnight/core-capability-ready/`. Existing cold refinement ACK fixture reproduced its failure on unchanged005fc78; it now awaits actual native capability readiness before creating the PeerMedia factory, matching production's existing preflight. Assertions were preserved.

Selected phone **60/60 PASS**, receipt `work/overnight/phone-input-fixture-ready/`. Cancellation fixture clears prior geometry/setup traffic and ACKs the actual leading motion checkpoint, so late queued movement is observable rather than hidden by reliable-lane backpressure. Negativecontrol removes only493's pump cancellation: the real-model test fails on missing synchronous retirement and late6/7 motion. Exact source bytes restored by finally and verified with cmp. Receipt `work/overnight/input-negative-control/`.

Signed Mac and generic physical-iOS Debug builds PASS; strict/deep certificate-backed verification, team39HM2X8GS6, correct production IDs/version and both embedded extension versions pass. Receipts `work/overnight/signed-host6/`, `signed-phone6/`, `signatures6/verification.json`. Builds/tests use the shared lock and external SSD DerivedData. Tests are targeted, not a full repository acceptance suite.

## Separate remaining gates

Primary integration, guarded stable-identity Mac installation and phone inventory must be recorded separately. Physical startup/reconnect, Home/continuously moving PiP, five cycles, M1/8GB realistic workload, matched sharpness/latency and60 unique original positive presentations/s remain unaccepted. Beta/private-SPI trial remains a separate identity/branch. No public App Store upload/submission or release-ready claim.
