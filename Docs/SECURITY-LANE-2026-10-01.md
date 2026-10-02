# Security lane validation — 1 October 2026

Scope: `claude/codex-security`, implementation checkpoint `490e779`. This receipt covers P1 #2/#3 and P2 #5/#6/#7 from the security brief. P1 #1 is design only; P1 #4 belongs to the privacy lane. No installation, deployment, version change or integration into main is part of this lane.

## Findings

| Finding | Confirmed cause and change | Regression coverage |
| --- | --- | --- |
| P1 #2: file/link effects without control consent | Host file admission omitted owner control consent and current epoch. Require both, preserve the view-only-scope gate, and revoke transfers/link effects on control loss or epoch changes. Fence old peer file callbacks before replacement sessions can admit bytes. The removed file-transfer setting stays removed. | `HostFileLinkRevocationTests`, `FileTransferRevocationTests`, `PeerFileAuthorityTests`, existing file lifecycle and engine tests. |
| P1 #3: backend policy outages fail open | New-room block lookup continued after failure; room creation and TURN issuance used permissive quota checks. Return retryable close 1013 for unavailable room status; use strict checks for creation and both TURN quotas. | `Backend/test/admission-security.test.ts`: throwing/timed-out D1 lookup, missing/throwing/denied quota bindings, healthy retry, and zero provider calls or credentials on denial. |
| P2 #5: public address logging | Selected pair and local-proof mismatch interpolated raw addresses as public. Public diagnostics now whitelist candidate and interface types only; private in-memory route checks retain their addresses. | `LocalLinkProofDiagnosticsTests.testPublicPairDiagnosticsContainOnlyKnownTypes`, including address/token-shaped unknown labels. |
| P2 #6: developer relay pass in unknown environments | The guard rejected production alone. Allow only staging and explicitly named local `dev`; reject test, missing and unknown environments. Preserve staging quiet-peer replacement at zero. | `Backend/test/route.test.ts` environment matrix and existing duplicate-admission tests. |
| P2 #7: pending LAN connection monopolizes admission | A pre-auth socket held the only slot for 20 seconds and its failure closed the listener. Use a 3-second host deadline, replace unauthenticated attempts, preserve the listener, and fence retired callbacks. Authenticated ownership cannot be replaced by an unauthenticated arrival. | `LocalSignalingLifecycleTests`: deadline, malformed/wrong-key recovery, replacement/stale callback fencing, authenticated-owner preservation and legacy-deadline switch. Real loopback TCP uses DEBUG-only fixture parameters. |

Internal rollback keys only reduce authority or restore the old deadline: `farsideDisableFileEffects` and `FarsideLocalSignalingLegacyAuthenticationTimeout`. No new settings or wire messages were added.

## Automated evidence

Logs: `/Volumes/Studio/Development/Caches/codex-security/logs/`.

- `bun run typecheck`: passed, exit 0; `backend-typecheck-resume.log`.
- `node node_modules/vitest/vitest.mjs run --maxWorkers=1`: passed, 166/166 in 16 files, exit 0; `backend-serial-final.log`.
- The first resumed full backend run passed 164/166 and failed two existing signal fixtures with message timeouts; `backend-serial-resume.log`. The unchanged isolated rerun passed both in 397 ms; `backend-signal-isolated.log`. The final unchanged full rerun passed. A fresh read-only GPT-6.1 Sol diagnosis found timing assumptions, without establishing a production bug; no quota/assertion was relaxed.
- `RemoteCoreTests` build-for-testing: passed, exit 0; `core-build-resume.log`.
- `PocketDeskRemoteHost` macOS build: passed, exit 0; `host-build.log`.
- `PocketDeskRemote` arm64 iOS Simulator build-for-testing: passed, exit 0; `phone-build.log`. The app and phone test targets compiled; phone tests were not executed.
- Final full native core run: passed, exit 0; 1,769 tests, 12 skipped, zero failures in 126.974 seconds; `core-tests-final.log`. The skips cover opt-in benchmarks and disabled packet-repair fixtures; their reasons are retained in the log. All lane consent, revocation, public-diagnostic, peer-ingress and local signaling lifecycle cases passed.
- The first full core run exited 1 with three failed cases / nine assertions in the same 1,769-test suite; `core-tests.log`. These were the existing 4 MiB loopback down-rate floor, existing video frame-timing counts, and the new LAN replacement fixture's authentication wait. The unchanged isolated three-class retry passed 28 tests (one optional benchmark skip) with zero failures; `core-isolated-retry.log`. The subsequent unchanged full retry passed. Source diagnosis did not establish a production defect or the exact cause of the transient failures; no assertion, quota or timeout was relaxed.

Every native command uses `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and `/usr/bin/lockf -k /tmp/farside-xcodebuild.lock`. Builds use lane DerivedData `/Volumes/Studio/Development/Caches/codex-security/DD`, two compiler jobs, and the existing pinned package cache; xctest uses that lane's built bundle. Pause, priority and quiet-granted flags are checked before queuing and again after lock acquisition. No lock file is removed.

Environment rechecked: Xcode 27.0 (27A266a), macOS 27.0.1 (26A434), macOS/iOS Simulator SDK 27.0, Node 26.10.0, Bun 1.3.14. Existing pins remain WebRTC 153.0.0 and Sparkle 2.10.0. These are compile/test environment facts, not compatibility proof for the OS 26 deployment targets.

Apple's live [release-note index](https://developer.apple.com/documentation/macos-release-notes) and [listener connection-handler documentation](https://developer.apple.com/documentation/network/nwlistener/newconnectionhandler) were refreshed. Their Markdown responses are retained with the logs. No new platform API was introduced during this continuation.

The earlier implementation handoff records an independent GPT-6.1 Sol review with no P0/P1 findings and two accepted minor corrections: immutable peer file-ingress lifetime and DEBUG-only LAN fixture injection. GPT review substitutes for the brief's requested Opus because the available project workflow uses GPT only.

The resumed independent GPT-6.1 Sol/high review approved those two corrections and their callback/IO dependents with no major or blocking finding. It checked lease retirement, production callback lock ordering, same-ID replacement coverage and Release initializer restrictions. This is source review; the reviewer did not run builds or tests.

## Pairing comparison-code design

The protocol, compatibility and UX design is already recorded in the complete lane notes at `/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/codex/security-NOTES.md`, under “Pairing comparison-code design — P1 #1”. It proposes ephemeral key agreement, transcript-bound comparison codes, separately derived saved trust, exact-candidate Mac approval, and safe old-peer refusal without QR-only fallback. It remains unimplemented. Roshan must decide code format/length and mandatory versus staged enrollment policy after protocol review.

## Needs orchestrator / physical checks

Use a later integrated build installed by the orchestrator. These checks have not been performed by this lane:

1. Connect a trusted phone with control enabled. Verify a harmless file and URL work. Disable Allow control, then attempt another file and URL: no file is published, the Mac pasteboard does not change, and no browser opens. Start a large transfer, disable control midway, then re-enable: the old transfer must stay cancelled and a fresh transfer may succeed. Repeat across a sharing-scope/epoch change and with a view-only scope.
2. Attempt local signaling with stalled, malformed and wrong-key peers, then connect the trusted phone: the host must keep listening, legitimate authentication should finish within five seconds after the bounded bad attempts, and unauthorized media/control must remain zero. An unauthenticated arrival must not evict an established owner. Continuous hostile flooding is not proven by loopback fixtures.
3. Capture representative successful and failed-route native logs: selected-pair and mismatch messages must contain only known candidate/interface labels, with no raw IP, pairing key, token, clipboard text or filename. Automated formatting tests do not prove the contents of actual device logs.
4. Live provider outage behavior and OS 26 runtime compatibility remain unverified. Backend fixtures establish fail-closed decisions with fabricated state and mocked TURN, not a deployed service outage receipt. These builds are Debug; Release/distribution validation and phone test execution remain outside this receipt.

## Handoff

Scoped source review and automated validation are complete. The security implementation is unchanged from `490e779`; this continuation adds the validation receipt. The lane is ready for orchestrator integration and later installation/device acceptance. Preserve `Backend/node_modules` as an untracked local symlink and never stage it. Do not install from this worktree or treat the automated receipts as physical/provider acceptance.
