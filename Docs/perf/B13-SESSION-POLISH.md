# b13 session polish — 3 October 2026

Base: `2c84d18` on `claude/b11-all-features`; branch `claude/b13-session-polish`. Versions unchanged. The orchestrator integrates and installs. No host production code, registration policy, protocol message or capability count changes.

## Confirmed source defects and fixes

- Big Text: capture restart advances the host epoch before asynchronous geometry preflight, while the scale receipt may be sent first. The phone previously discarded a correlated future-epoch catalog. It now retains that bounded catalog, accepts only the latest correlated applied-size evidence, and suspends old input readiness until fresh geometry/capture/frame. Old epochs and unrelated/superseded IDs cannot complete a new request. Background/PiP entry and fresh authentication retire the old pending request and debounce task; background ticks cannot create a new scaling request. Actual unanswered/failed requests retain their notice.
- Lock recovery: the Mac sends an authenticated `capture.hostState` and then stops signaling registration when unavailable. A fresh unreachable attempt cannot prove a lock. The phone promotes a received lock report, describes a disconnected report as historical, scopes it to the exact paired invitation, and displays plain awake/unlocked guidance during unexplained retries. The reconnect veil shows the guidance without blocking End. Concrete final errors retain precedence.
- Preferences: First60 and Big Text status getters previously repeatedly read internal flags, as did Duo representable updates and coalesced-touch events. First60 samples at phone-model construction; Big Text policy samples on first use and resets when its memory store is replaced; Duo and coalesced touch switches sample once per process. No user preference or setting is added.

## Rollback

`FarsideSessionPolish`: absent/YES enables visible Big Text lifecycle/order and recovery corrections; NO before constructing the phone model restores prior behavior. Existing `PocketDeskFirst60Disabled`, `disableBigTextStatusReliability`, `disableDuoSessionLayout`, and `couchCoalescedFingerMotionDisabled` remain available at their sampling boundaries above. Restart Farside for a process/model switch comparison.

## Evidence and limits

Supplied phone log begins14:04:48 and ends14:12:18 despite its filename1404–1420. All CFPrefs keys are redacted. The14:04:48–14:05:28 inclusive second buckets contain20,171 read/search events over41seconds (19,165 missing-value and1,006 found-value), plus457 already-present write skips. This cannot attribute each event to a key or prove causality for later Big Text incidents. The reported later host successes are outside the phone receipt. The source-order/lifecycle defects are independently reproduced by tests; no exact historical request trace is claimed.

Injected counting defaults before implementation observed6,000 First60 and2,000 Big Text method invocations above initial counts across1,000presentation cycles. These count overridden bool/object methods, not physical CFPrefs I/O. The test requires zero added reads after caching. Remaining event-driven policy reads retain their original semantics. A real-phone capture is needed to measure total reduction.

Verification logs, review receipts, coordination state and exact commands: `/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/b13-session-polish/`. RED baseline:69tests/20failed assertions across six new regression cases. Final phone suite:851total,849passed,2expected skips,0failures. No installation or physical acceptance claimed.

## Combined iPhone check

1. Connect, open Controls → Big Text, choose a larger size, then immediately swipe Home. Leave the app/PiP for at least10seconds and return. Repeat with a reconnect (brief Wi-Fi off/on). Pass: saved text size reapplies as needed; no false “Couldn't confirm text size”; controls resume only with fresh picture. Genuine request failure still explains itself.
2. While connected, lock the Mac in person. Pass: if its authenticated lock status arrives, the phone names the reported lock and says to unlock in person; after disconnect it says last reported, without claiming current state. Start again while the Mac is already locked: awake/unlocked guidance appears, without an invented lock diagnosis. Unlock and reconnect: the old explanation disappears. Repeat with a truly offline Mac and, if paired, another Mac: neither inherits a lock claim.
3. Run the same40second active phone session and content-free syslog capture. Compare aggregate CFPrefs read/search events to the prior window; check that swiping/scrolling, Big Text, First60 hints and PiP still work. A numeric device reduction is unverified until this capture.

## Verification

- Phone: full RemotePhoneTests passed, 851 total / 849 passed / 2 skipped / 0 failures; command exit0. Affected BigText, ConnectionHealth, First60, SessionPreferencesRead, lifecycle, Couch and Duo classes are included. `logs/final-phone.log`, `.xcresult`, and `final-phone-summary.json`; final build `green-phone-bft-final.log`.
- Counting: 1,000 presentation cycles added zero First60 and zero BigText policy method calls, versus6,000 and2,000 on baseline. Paywall snapshot opt-in and device-only hardware decoder are the two phone skips.
- Core: build passed (`final-core-bft-2.log`); full2113tests /14skips / one failed case with three assertions (`final-core.log`, exit1). `FileTransferEngineTests.testPhoneToMacTransferArrivesIntactInChunks` is unchanged, as are all Core target source/test/project inputs. A clean archive of exact base2c84d18 compiled (`base-core-bft.log`) and reproduced all three assertions on focused repeat2 (`base-file-transfer-repeat-2.log`). The isolated test can also pass.
- Core root-cause probe: the fixture advertises zero buffered bytes and bursts3MiB into a receiver capped at2MiB. Thirty isolated traced runs and the15-case class passed. A diagnostic-only1ms per-write sink delay in the owned base snapshot then reproduced the failure and logged only `receiveOverflow`:2097152bytes reserved plus65536incoming,32chunks,2097152byte limit (`base-file-transfer-slow-trace.log`). That proves the budget/burst failure under delayed draining; the exact branch in the untraced original full suite remains inferred. Probe patch is external `base-filetransfer-diagnostic.patch`; no file-transfer change ships in this branch. Original-worktree Core bundle restored (`final-core-restore-bft.log`).
- Host and generic iOS device compilation passed, exit0 (`final-host.log`, `final-device.log`). SDK stale-output warnings referenced another DD; no outside artifacts were removed.
- Fresh GPT source/receipt review approved with no new findings (`review.json`). No simulator UI rendering suite, install, host launch, deployment, or main merge.

Physical feel/performance, aggregate preference I/O reduction, mixed-version devices, actual lock-message delivery, normal reconnect rendering, PiP/background behavior and OS26 remain device gates. Historical Big Text incident correlation remains limited by the supplied phone log ending before the reported successes and no retained host BigText info entries in a fresh archive query.
