# Phone load: independent sample windows

Prepared from `00b2b9d` on 5 October 2026. This is the bounded follow-up to the overnight source audit, not a measured explanation of earlier 30 FPS behavior. Source and regression fixtures are prepared; native verification, fresh independent sensitive review, integration, signing and installation are owned by the orchestrator and remain required. No frame-rate thresholds, codec/default selection, input/capture authority, or platform API changed.

## Defect and correction

The phone publishes statistics about once a second and repeats its latest load report on 0.25-second heartbeats. The host evaluates its ladder on its own statistics callbacks. Previously, two host callbacks could count one phone report as two bad windows, and every repeated heartbeat reset the host's receipt TTL. Equal metric values are not a reliable deduplication key because genuinely distinct measurements can be equal.

`PhoneLoadSamplePublisher` now assigns a strictly increasing sequence once in `PeerMedia.publishStreamStatistics`, alongside the actual counter drain. The local completion timestamp survives the phone model's MainActor hop. `PhoneLoadFeedbackCache`, used by the model and core regression fixture, holds that identity and emits only its changing relative age. The wire envelope contains sequence, geometry epoch and age in seconds. Local start/completion clocks never become host authority or cross-device timestamps.

`HostPhoneLoadInbox` keeps one cache, a nonrenewable remaining-age deadline, and one sequence high-water mark. Equal/lower IDs cannot replace or renew a sample, even in newer control packets. Nil, expiry and capture/presentation invalidation preserve the high-water mark. Only the owner's new authenticated `presentationSessionID` resets that lifetime. Production constructs a peer publisher after session reset; a publisher never wraps its sequence and stops producing identified windows at exhaustion. A newly constructed publisher's sequence can be reused only with a verified new session lifetime at the inbox.

The inbox also keeps one sticky continuity bit. A regular nil/unqualified report, explicit invalidation, stored-epoch mismatch or deadline expiry retires the earlier phone episode even if a newer valid report arrives before the next host callback. The callback consumes the bit with the newest payload once. Before evaluating that payload, the monitor clears phone-dependent pending load/recovery and phone busy-floor duration; independent host-only overload, replay high-water and the existing bounded busy display hold remain. Expiry uses the same inclusive deadline as reads: equality is still current. Auxiliary probe heartbeats and rejected old-epoch heartbeats neither clear the cache nor create a continuity boundary.

The host monitor classifies dynamic phone observations as fresh, held or unknown. Legacy/unqualified rates are unknown; thermal and low-power fields remain bounded held state. A duplicate cannot increment or clear a pending phone bad streak. New host pressure still participates in the existing mixed-cause consecutive bad-window rule and retains trigger priority. A held bad phone report cannot turn into phone recovery evidence merely because the host just changed its rung's frame budget. When it expires/becomes unknown, the old phone streak ends and host-only recovery restarts at that boundary. Missing phone observations remain compatible with host-driven adaptation; there is no invented phone headroom vote or additional recovery threshold. Busy-state updates likewise do not renew a phone dynamic cause from a held window.

Under current false-load rules, measured decode time is needed to qualify a dynamic phone window (the superseded trigger also needs decode pressure). The legacy false-load rollback retains its alternative superseded/presented evidence. A report with only thermal/power or unmeasured dynamic fields cannot masquerade as a fresh healthy phone window.

## Compatibility and provenance

The phone requests `phoneLoadWindows: true` as a separate optional handshake Boolean. The host echoes support with a separate optional `capture.phoneLoadWindows` Boolean only after that request. The phone includes the envelope only after its own request and a current-geometry host echo. Missing/false echo uses the legacy wire shape. Neither the eight-feature/four-option request bounds nor the host feature list grows, and the protocol version is unchanged.

Geometry change clears both the cached measurement and the host echo. A fresh publication for the new geometry still uses the legacy shape until a matching capture echo arrives; an older-geometry echo cannot enroll it.

The Boolean is stripped from v2 enrollment's committed request before hashing/key derivation and carried on the optional proof path, following existing setup/shortcut capabilities. Ordinary saved-pair requests read it directly. Enrollment hosts enable it only after real proof confirmation. No crypto canonicalization or pairing authority changes. Tests include the actual new phone request decoded/re-encoded by old typed request shapes and real old-host key derivation; a typed old-phone request/proof also derives the same new-host session, trust and comparison keys.

New host + old phone intentionally treats unidentified dynamic rates as unknown for independent votes. It retains host adaptation and thermal/power handling. New phone + old host retains the old-host payload and old-host behavior; the update cannot repair an old host's policy. This is wire compatibility, not a claim of identical legacy adaptation behavior.

The cache is invalidated on the model's known presentation retirement, session start/end, background pause, geometry, shared-scope and observed host-rung changes. A changed observed route neutralizes the spanning report. A report whose local counter window started before the invalidation cannot obtain a qualified envelope; its state fields can remain bounded. The cached epoch is checked again at serialization, and the host checks both receipt and stored epochs. This prevents heartbeat-time relabeling of old evidence.

Limits deliberately left explicit: WebRTC decode deltas and local presentation counters cover different intervals; a composite publication ID does not align them. Local model retirement is not proof of every internal GPU/decoder transition. Last-known host rung/status is not a correlated acknowledgement that every measured frame used the newly applied capture configuration. Exact RTP/local-window alignment, host-rung attribution and physical rendering behavior are unmeasured. This correction introduces no new capture ACK protocol or wider measurement redesign. Relative age bounds sender-reported cache age plus host residence; unknown network delivery time and age of every frame in an aggregate are not proven.

## Author checks and required verification

Author syntax parsing with `swiftc -frontend -parse` and whitespace checks are this worker's only executed checks. Parsing does not establish type checking or runtime correctness. Root reported 153 core tests passing and an isolated duplicate-classification negative control compiling then failing eight assertions on the initial frozen bytes. Independent source review then found the inter-callback continuity loss and retained geometry echo; the correction and new regressions below require fresh native verification and review. Earlier runtime receipts do not verify these changed bytes. Root's disjoint loopback/harness files are outside this package. No version/project edits, commit, heavy build, native test, simulator/UI use or installation was performed by this worker.

Required native selectors on the root's serialized existing build infrastructure:

```text
RemoteCoreTests/PhoneLoadWindowAttributionTests
RemoteCoreTests/PhoneLoadWindowNegotiationTests
RemoteCoreTests/LadderPolicyTests
RemoteCoreTests/PairEnrollmentCryptoTests
RemoteCoreTests/ComparisonEnrollmentCoordinatorTests
RemoteCoreTests/MacShareBlockerTests
RemoteCoreTests/ShortcutChipsProtocolTests
RemoteCoreTests/VideoRefinementTests
RemoteCoreTests/CaptureRateTests
RemotePhoneTests/ViewportCaptureTests
RemotePhoneTests/SessionLifecycleTests
RemotePhoneTests/PhoneDisplayTickInputPumpTests
```

Use the existing locked `xcodebuild test` commands for `RemoteCoreTests` (macOS arm64) and `PocketDeskRemote` (root's known iOS simulator), preserving pinned packages, derived-data paths and unique result bundles. The core fixture calls the same publication/cache helpers as production, encodes and decodes the actual heartbeat, and then runs the real inbox and monitor. New cases deliver nil, unqualified, expired and explicit-invalidation boundaries followed by a valid replacement before any host tick, require two post-boundary bad reports, preserve host-only overload, and restart the existing recovery interval. Probe/old-epoch receipts and replacement exactly at the deadline must not fabricate a boundary. The separate phone fixture verifies the actual model's heartbeat, both opt-ins, echo downgrade, unchanged ID/equal-value new ID and fresh post-geometry publication before/after the matching echo. These do not replace a real paired-device quality measurement.

Required red/green negative control: run `PhoneLoadWindowAttributionTests/testPublishedWindowAcrossEncodedHeartbeatReceiptsVotesOnlyOnceAndEqualNewWindowVotesAgain` on the frozen patch; then in an isolated/restorable copy change only the monitor's identified-window classification from the sequence comparison to unconditional `.fresh`. The repeated report's second tick must fail the no-downstep/rung-zero assertions for both decode and superseded cases. Restore the exact file and hash, then rerun the relevant core suite. A second optional control restoring receipt renewal for equal IDs must fail the deadline/replay test. For the corrected inter-callback regression, an isolated mutation suppressing `sample.phoneLoadInterrupted` handling in the monitor must compile and fail `testInterveningNilUnqualifiedAndExpiredReportsRetirePhoneStreakBeforeReplacementIsConsumed` and `testInterveningPhoneGapCannotBorrowEarlierRecoveryTime`; restore exact bytes before the final run. Do not call a compile failure a meaningful red result. New runtime results remain pending.

Additional required checks cover host overload during held phone pressure; recovery after expiry without borrowing prior elapsed clean time; old/new crypto shapes; absence/false echo; sequence gaps, lower IDs, same-session invalidation and new lifetime; exact age boundary, negative/nonfinite age, backward/nonfinite local clocks; sequence exhaustion; and neutralized geometry/route/presentation-spanning windows. The new focused regressions include these seams, but native results and fresh independent review are pending.
