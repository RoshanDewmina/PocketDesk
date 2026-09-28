# PocketDesk native interaction build — 28 September 2026

This is an implemented local development checkpoint, subordinate to PRODUCT.md. It includes the requested appearance overhaul of both native apps. It is not a completed S0–S3 physical acceptance result.

Implemented:
- Shared warm-paper and warm-charcoal appearance, restrained serif headings, native controls and readable state colors. The phone connection screen centers pairing or the saved Mac. The Mac companion brings status and Pair/Enable/Stop to the top, groups permission/setup controls, and puts service/browser settings behind disclosures.
- Full desktop canvas as a relative touch trackpad, compact native controls, explicit local pan and midpoint-anchored pinch/fit zoom. Viewport preserves source focus on size changes and releases held input before remapping.
- Prompt semantic clicks, secondary click, double-click and second-touch drag arbitration. Local velocity-dependent gain uses elapsed time, preserves fractional movement and freezes sensitivity/scale for each stroke.
- Authenticated native interaction envelope with expiring host-issued admission tokens, explicit hold/scroll identities and client click counts. Scoped releases, stationary-hold renewal, no upgraded-peer downgrade, and bounded retired-identity history protect interruption/late-packet handling.
- Fractional host scrolling with phases and bounded stream expiry. Custom momentum remains deferred.
- Accepted-click haptics with an Off setting and a brief local visual acknowledgment. This feedback means queued locally, not completion by the Mac app.
- Native multiline text draft with IME marked-text isolation and acknowledged delivery; pending text becomes read-only until resolved. Portrait/landscape keyboard controls remain reachable.

The captured Mac cursor remains enabled. No separate overlay or globally altered Mac pointer was added: supported cross-app visibility/shape telemetry has not been established. S2's requested larger pointer is incomplete. Edge-follow, prediction, hardware pointer specialization, momentum tuning, iPad/Duo optimization, cellular/relay acceptance and release distribution remain pending.

Verification:
- Baseline service suite: 120 passed (unchanged service/browser source).
- Native core suite: 77 passed. One preceding run timed out on the existing encoded-video fixture and reported a teardown socket error; unchanged retry passed, including actual local WebRTC media/control/reconnect/revocation. This is a reliability caveat, not a latency result.
- iOS composition unit tests: 3 passed.
- Phone UI suite: 3 passed (home/pairing, privacy recovery, portrait/landscape keyboard and zoom). The final compact keyboard and contrast refinements also passed focused home and landscape checks in dark appearance (2/2).
- Independent GPT-6 Sol source review approved after corrections to hold release scoping, geometry downgrade prevention, retired identities, and text acknowledgment races. Final visual click status and test synchronization were parent-reviewed afterward.
- Unrelated pre-existing browser/server/MCP files matched the pre-build SHA-256 snapshot.

Final installation: updated `/Applications/PocketDesk Host.app` via the repository installer; signature continuity passed and runtime permissions remained granted. Signed physical iPhone17 build, install and launch of `com.roshan.PocketDesk.Remote` passed. The installed apps include both appearance overhauls and the interaction changes.

Observed runtime: updated Mac companion retains Screen Recording and Accessibility grants, and its live status showed the paired phone connected with native control enabled. This does not establish a completed remote editing task. Simulator captures show the native draft panels and keyboard controls; they do not establish software-keyboard occlusion behavior on the physical iPhone. Mirroring rendered the phone but its click automation returned noWindowsAvailable. The Xcode interaction API could not select the physical device; its simulator workflow required an unavailable device-interaction skill, and that session was closed.

No public endpoint, deployment, provider purchase, App Store submission or release claim was added. Existing iOS/macOS 26 deployment targets and SDK27.0 were retained.

Next acceptance: on the physical phone, connect to the awake Mac, use a disposable text file to select/edit/save, exercise pinch versus scroll, a stationary hold beyond two seconds and Release, then interruption/reconnect. Judge haptics and sensitivity on the phone. Cellular and forced-relay evidence remains separate.

## Receipt index

All logs are retained in this chat’s `work/native-build/`.

| Check | Receipt |
| --- | --- |
| Unchanged service baseline, 120 pass | `baseline/service-tests.log` |
| Native core, 77 pass after documented retry | `core-tests-retry.log` |
| Composition3 and phone UI3 pass | `visual-phone-tests.log` |
| Final affected home/landscape2 pass | `appearance-final.log` |
| Final Mac signing and installation | `visual-installed-host/` |
| Final physical phone build/install/launch | `final-device-build.log`, `final-phone-install.log`, `final-phone-launch.log` |

The complete current source fingerprints are in `native-source-manifest.json`. No commit or PR was created.
