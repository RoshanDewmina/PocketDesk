# Background return / PiP check — 4 October 2026

## Observed failures

Owner reports build20261004.1 requires Reconnect after Home/return, and manual Picture in Picture stops after a few seconds. The autonomous mirrored automatic-PiP path remained live and returned to the session, so the failure is path-dependent. The early start-deadline explanation was disproven: correlated manual confirmation already clears that deadline in the baseline. The manual PiP-stop cause remains open.

## Reviewed correction

Source421f2d1 (worker19a21d5) preserves a return intent bounded from the original background transition and correlated to the exact selected trusted host. Involuntary background PiP loss retires the route but can retain this intent. Only active foreground consumes it, via existing fresh authentication. Explicit End, manual new connection, host replacement, lock and permission block invalidate it. No background retry or reused presentation/input authority.

Preparation1255694 adds the explicitly opt-in FarsidePhysicalLifecycleUITests scheme and sets all phone/widget/share/host versions20261004.2. The scheme contains only the small hardware smoke file and the real app dependency; default UI targets are unchanged. It sends no remote clicks or typing, uses the existing pairing, and skips without FARSIDE_PHYSICAL_LIFECYCLE_SMOKE=1 or on Simulator.

## Validation

- Independent Sol source review: APPROVE correction and separate physical test/config package; no must-fix findings.
- RemoteCoreTests/SessionContinuityTests:7 passed, zero failures.
- RemotePhoneTests/SessionLifecycleTests:31 passed, zero failures; compatible27.1Duo Simulator was used for model verification, not physical acceptance. Simulator is shutdown.
- Signed phone physical-test build and host build:PASS.
- Phone and /Applications/PocketDesk Host.app installed and version-verified20261004.2 around20:00ET. Host install used integrated primary and script/build_and_run.sh; identity guards passed. UI Ready with Screen Recording/Accessibility grants. Existing owner Off choices for Privacy curtain and Big Text permission retained.
- Initial combined physical runner attempts ran zero tests: first signing was disabled by project default; corrected command signs with the existing Apple Development identity. The combined runner then hit an AppIntentsTesting/current-iOS symbol mismatch before loading tests.
- After Mirroring was closed and the owner unlocked the phone, both native physical cases executed on20261004.2. Manual PiP retained its active Stop Picture in Picture state after12seconds:PASS for active-state persistence only. Home-return failed because the test expected a collapsed dock (Show controls) while the valid expanded dock says Hide controls; product recovery is INCONCLUSIVE from that assertion. The independently reviewed correction accepts either dock state and then still requires fresh control admission. Corrected Home-return rerun remains PENDING.
- Continued PiP state is only one gate; it does not prove continuous frame delivery. Source-approved recovery does not establish the cause of manual PiP stops.
- No App Store upload/submission, publication, Mac permission reset or codec-quality default change.

Receipts are local in the Oct4 Codex chat work/lifecycle-checks and work/manual-test-2026-10-04 directories. Raw diagnostics are not uploaded.

## Renderer / native batch checkpoint

Candidate20261004.3 integrated at281f6e3 preserves normal/Release two-drawable defaults; DEBUG-only alternate pool3 keeps at most two frame flights. Source review approved renderer and observation harness. Integrated OwnedVideoLifecycleTests plus VideoRefreshPolicyTests:39 passed, zero failures. Signed phone physical runner and host builds passed; phone and Mac installs are version-verified20261004.3 and host Ready shows both grants. No permission resets.

Native batch includes corrected default Home10seconds, no-automatic-PiP Home50seconds (beyond phone25second hold), manual PiP12seconds, and opt-in2→3→2 renderer60second observation sessions. The fixture is local native scrolling code/text; existing owner apps stay running. Marker reads are disabled consistently for this non-marker fixture. Draw submissions are not actual displayedFPS; actual presentation callbacks/timing must be used. Physical batch is staged but blocked by the current OS passcode requirement; owner unlock requested. No performance acceptance inferred from39 unit tests or installs.

User requires60fps under realistic multitasking at the same sharpness and latency. A quiet comparison is diagnostic only; acceptance must include representative load. No default30fps target is accepted as the outcome, and forcing60/lowering resolution/inventing frames would not satisfy this gate.
