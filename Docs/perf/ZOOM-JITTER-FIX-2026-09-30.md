# Farside zoom jitter and phone-busy investigation

30 September 2026. Source base `a567310`; isolated branch `codex/zoom-jitter-fix`.

## What the screenshot means

“Your iPhone is busy” is Farside’s phone-pressure diagnosis sent by the Mac’s adaptive quality ladder. The detail is the **configured target**, not measured display performance: 30 frames/s and a nominal 1,280-pixel longest edge. It does not describe the phone’s screen resolution or mean another app is occupying the phone. The banner alone cannot tell which metric triggered the reduction. The remembered base dimension can also precede a later crop change.

Triggers include slow decoding, serious thermal pressure, or excessive frame replacement accompanied by low presentation throughput. Idle or missing presentation FPS alone is not a trigger. Recovery deliberately requires sustained headroom, so it is gradual.

## Corrections

- Control-mode pinches now preserve the original content beneath the moving two-finger midpoint, including movement before pinch recognition. View mode already used this mapping. Pinch never sends Mac pointer or scroll input.
- Continuous viewport updates explicitly suppress inherited SwiftUI animations. Queued end-of-pinch settling cannot supersede a newer pinch, cancellation, discrete zoom, display change, interruption, privacy change or disappearance.
- Replacement counts are normalized by the actual statistics window before phone feedback. Ten replacements over two seconds are five per second; the raw count remains available in diagnostics. Missing/invalid rates remain unknown. Existing heartbeat fields and pressure thresholds are unchanged.

These correct verified source defects. They do not establish that every visible jump in the recording has been eliminated.

## Verification

Final independently reviewed isolated-source core build passed in 2.591 seconds; phone SDK build passed in 3.509 seconds. Actual direct native XCTest selection ran **152 methods with zero failures**: gesture36, viewport26, direct-touch13, hardware-pointer9, middle-click5, ladder46, instrumentation10 and busy presentation7. Tests check both modes/contact order/asymmetric pinches/source pinning/no remote input, irregular statistics windows and actual pressure thresholds, invalid inputs and legacy reports. Earlier obsolete DirectTouch assertion was corrected and its real class rerun; an earlier selection omitted that class and is not counted as evidence.

Independent review approved all seven final file hashes. Isolated commit `3cafa64` was integrated onto main as `07eebca`, with other agents’ committed worktrees and existing main documents preserved. Both source checkpoints were pushed to the private backup. The signed main phone build passed in 17.250 seconds, with strict signature/bundle/team verification. Normal development update succeeded; device inventory confirms **Farside 1.0 build 20260930.7**, and the normal app launch command succeeded. The existing Mac host was not replaced. Physical pinch acceptance remains pending. No current latency benchmark or multi-simulator overlap is claimed.

## Remaining evidence and limitations

The Mac’s crop status and separately delivered encoded video can still arrive out of step. This patch does not change that protocol. Freezing crop during a pinch was rejected because zooming outward can reveal missing desktop edges. The old renderer can attribute replaced-frame backlog to a later window, and host evaluations can reuse a recent phone sample. A live metric trace is needed to establish whether these contributed to this screenshot.

Mirroring connected earlier, then disconnected when the phone was used. After the verified update, a reconnect attempt returned “iPhone in Use — Lock your iPhone to connect.” Its available automation has a single pointer, so a real two-finger comfort check still requires the phone. Installed inventory before this fix was Farside 1.0 build 20260930.4; the verified post-install inventory is 20260930.7. The updated app launched normally, but its live Mac connection was not observed because Mirroring is waiting for the phone to be locked. No physical pinch or latency acceptance follows from installed inventory. Roshan was asked to check the updated two-finger behavior on the phone.

Physical check: pinch inward/outward in Control and View with one finger stationary and with both moving; try source edges, a second pinch immediately after ending the first, interruption and Fit/Fill settling. Report any remaining jumps with a new recording and stream statistics.
