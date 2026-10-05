# Workspace beta host lane — 4 October 2026

Source implementation for the explicitly authorized experimental iPhone Workspace beta in the isolated `codex/workspace-phone-beta-20261004` checkout. No candidate has been installed, and no physical Workspace acceptance, performance comparison, distribution approval, or private-SPI shipping claim is made here.

## Combined host behavior

- Resolved host conflicts by combining First60 persistence/status with cold journal recovery and the connection start veto; combined thermal admission and bounded startup retry with Workspace transition admission; retained producer reservation/token ownership in `RemoteCapture`; retained Shortcut Chips and Low Data feature priority.
- `SessionVirtualDisplayPolicy.permitsWorkspace(viewport:experimentalPhoneEnabled:)` defaults to false for the new experimental phone path. A phone must supply `experimentalPhoneWorkspace == true`, and the host must explicitly pass beta admission. Existing validated `iPadWorkspace == true` requests remain supported under their prior gate.
- Host offers both `display.virtual.1` and `display.phone.beta.1` only to an explicitly requesting modern beta phone with Accessibility. A beta connect alone starts ordinary capture. The iPad negotiation deadline remains; beta phone entry has no automatic missing-viewport timer. Big Text remains available on the ordinary screen; an engaged or unresolved Big Text change refuses Workspace with guidance.
- Entry synchronously releases held input and marks capture unhealthy. Health callbacks cannot re-enable input during preparation/restoration. The actual usable viewport supplies exact backing dimensions; codec budget, exact 2× virtual source geometry, ownership, current session, generation, permission, thermal and privacy fences remain required.
- Coarse capture phase is `idle`, `preparing`, `active`, `restoring`, or `blocked`. `active` describes the owned capture route, not phone presentation/readiness. The phone must independently match and actually present an original fitted source before revealing or enabling its control entry.
- Current-epoch unavailable viewport cancels the owned attempt. Before preparation, it invalidates generation and blocks a late request. During preparation/active use, it revokes the window operation authority, waits for admitted work, and restores before ordinary capture resumes. Reconnect offers a fresh attempt after a blocked path.
- A bounded capture stop is not producer retirement. Private display/window mutation and retirement wait until the retained producer reservation is gone; unresolved cleanup leaves the display/journal and retry guidance intact. Existing bounded 32-window enrollment, complete inventories, journal-before-write, surviving-window readback, topology protection and restoration-before-removal are retained.

## Beta isolation and visible identity

The shared helper gates the lane at compilation. Host setup, Settings and menu popover show `FarsideBeta.label`; coarse Workspace text includes BETA. Pairing/Mac display name adds BETA. The window journal uses `Application Support/FarsideWorkspaceBeta/virtual-display-window-restore.json`. The parent owns separate bundle IDs/defaults, Keychain service, Bonjour identity, signing and installation tooling.

Beta background services are inert; login/recovery choices are unavailable. The beta creates no watchdog reporter or hang watchdog and never registers/removes production background services. Sparkle is disabled in the beta. No permission reset, hardware test, app launch/UI manipulation, virtual-display harness or live window reflow was run.

## Checks

Source-only checks: `git diff --cached --check -- RemoteHost RemoteShared/SessionVirtualDisplayPolicy.swift RemoteTests/SessionVirtualDisplayPolicyTests.swift RemoteTests/BigTextHostWiringTests.swift` passed (exit 0). `xcrun swiftc -frontend -parse` across the changed host/policy/test Swift files passed (exit 0). These do not typecheck or build the assembled app.

New focused cases cover explicit phone marker plus experimental admission, invalid geometry and Codable provenance, separate beta feature capability/prerequisites/32-item bound, and preservation of ordinary-screen Big Text. Existing iPad, exact raster, codec budget, rotation, window ownership/restoration and capture-start tests remain required.

Integrated focused core PASS: **267 passed, 0 failures, 0 skips**, `xcodebuild` exit 0, 42.216 seconds. Receipt: `work/beta/host-core-20261005T024615Z/` (`xcodebuild.log`, `host-core.xcresult`, `exit-code.txt`, `result.json`). The command used `lockf -k /tmp/farside-xcodebuild.lock xcodebuild test -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsideWorkspaceBeta-20261004`, `-collect-test-diagnostics never`, `-parallel-testing-enabled NO`, and `-only-testing:RemoteCoreTests/<class>` for each class below. The result bundle is in that receipt directory. This beta test target compiled with DEBUG, FARSIDE_WORKSPACE_BETA and AUDIO_LIFETIME_TESTS.

| Selected class | Passed |
|---|---:|
| SessionVirtualDisplayPolicyTests | 14 |
| VirtualDisplayWindowTests | 68 |
| VirtualDisplayRotationPolicyTests | 8 |
| VirtualDisplayCaptureWiringTests | 4 |
| BigTextHostWiringTests / BigTextRefreshTests / BigTextScreenSnapshotTests | 3 / 4 / 1 |
| CaptureStartupTicketTests / HostLifecycleTests | 17 / 24 |
| SharedCaptureScopeTests / SystemAudioPCMTests | 7 / 11 |
| CaptureRatePolicyTests / CaptureRateTuningTests / CaptureRateSenderTests | 12 / 2 / 2 |
| SenderRateParametersTests / SenderOutputFormatTests | 3 / 4 |
| ViewportTransformTests / NativeGestureEngineTests | 31 / 52 |

The initial run at `work/beta/host-core-20261005T024459Z/` failed compilation with exit 65 and **0 tests executed**: Swift DEBUG was absent, hiding existing test-only interfaces. The parent corrected global Debug compilation conditions and regenerated the project before the successful rerun; the failed receipt is retained. 363 Host/Shared/Core Swift source hashes observed during the successful compile remained unchanged through completion. This observation is not a pre-start full-source seal. Final changed-source syntax and diff checks passed again.

Signed beta Mac/iPhone builds and sensitive independent source review remain parent-owned and pending at this host-lane handoff. No app build, signing, installation or physical acceptance is claimed by this lane. Do not launch a hardware/harness or install from this worktree.

## Reviewed exit correction — source prepared after the 267-test checkpoint

Independent review found that a confirmed normal-screen return retained the request fence `virtualDisplayBlocked`, leaving the coarse phase blocked and the phone's exit/control gate waiting forever. The host now wires the tested `SessionVirtualDisplayPolicy.phase` decision: recovery/retirement remains restoring, unresolved owned Workspace remains blocked, and a completed blocked attempt reports idle only after a healthy current ordinary capture matches the selected physical display under a nonzero route epoch. Existing retirement drives `beginCapture`/new epoch; cleanup alone or the old virtual source cannot report idle. The request fence stays closed until reconnect, with explicit normal-screen guidance.

A second wiring requirement is addressed together: an experimental peer receives explicit `virtualDisplayActive == false` after capability withdrawal. Legacy unsupported peers still omit that field. The phone worker confirms that exit still requires idle, active false, measured/applied geometry and a fresh admitted original ordinary presentation with current privacy/control/scope authority; blocked frames do not acquire input permission.

Two new regression cases cover delayed ordinary readiness, wrong/missing source identity, zero epoch, retained ownership, unresolved journal/producer retirement, and encoded idle/active-false status after feature withdrawal. Changed-source parse/diff checks passed. **These new changes have not yet run integrated tests**; the 267-test receipt above is explicitly the earlier checkpoint. The parent coordinates the next affected-check rerun after source freeze.

Physical acceptance remains parent/owner work: same beta identity on Mac/iPhone, explicit entry, real fitted presentation, aligned input, software keyboard/rotation, normal-screen escape, End/drop/restore and journal recovery. M1/8 GB is the performance baseline; development M4 build/source evidence is not that acceptance. Spaces/fullscreen/minimized/unusual exit and private `CGVirtualDisplay` compatibility remain limits.
