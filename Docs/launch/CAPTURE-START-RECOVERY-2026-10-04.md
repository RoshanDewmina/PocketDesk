# Capture startup recovery — 4 October 2026

## Observed failure

Installed20261004.3 passed native Home10second return, Home50second return without automatic PiP, and manual PiP active state after12seconds. A later first-picture repeat failed before quality acquisition: Mac capture/encode and phone decode were zero, with the phone waiting. The underlying OS cause is unknown. A later tool report that the Mac was locked does not establish the earlier failure's cause.

Source inspection found unbounded startCapture and stopCapture awaits. Health monitoring began only after startup returned. The capture wrapper dropped its session reference before asynchronous stop completed, so a replacement could miss unresolved cleanup.

## Reviewed candidate

Worker745a266 is integrated as c8613c4. Metadata724463d prepares candidate20261004.4. Signed phone installation and inventory confirm20261004.4; Mac installation is queued, with20261004.3 still confirmed installed. Physical acceptance of20261004.4 remains pending.

- One callback ticket is created eagerly before a session is published. Successful start and a real valid complete frame are both required for readiness, in either callback order.
- A nominal five-second startup deadline or cancellation synchronously fences pixels/PCM before resolving the caller. Scheduled deadlines can run later under OS pressure; no exact wall-clock guarantee is claimed.
- A retained process-wide reservation holds at most one producer, including an unresolved retired producer. Replacement requires original startup settlement and a subsequent confirmed stop. A pre-settlement stop or-3808 does not prove retirement.
- Caller failure never awaits unbounded cleanup. One automatic retry may wait up to three nominal seconds for retirement, recheck exact admission, selection, scope, route, permission, lock and mode, and rerun ordinary capture admission with a fresh input epoch/preflight. Retry budget is not reset by its new capture attempt.
- Queued health/region callbacks recheck readiness, current scope and stopping before publication. No fake frames, overlapping producer or reused input authority.
- Missing callbacks leave one fenced quarantine and end the peer session. The Mac explains that Farside must be quit/reopened; phone-specific restart guidance remains a limitation because the existing wire protocol has no such reason. This is bounded safe failure, not proof of automatic recovery from an unresponsive OS callback.

## Verification state

Independent sensitive source review: APPROVE745a266; no remaining must-fix finding. Parsing/diff checks passed. Seventeen focused callback/recovery tests were added, including actual deadline dispatch, both callback orders, missing/late/duplicate callbacks, cancellation, stop classification, reservation ownership and admission denials. Native execution passed59 checks with zero failures:17CaptureStartupTicketTests,24HostLifecycleTests,7SharedCaptureScopeTests and11SystemAudioPCMTests. Host Debug build and signed physical build-for-testing passed. Phone deep/strict signature verification, installation and filtered app inventory confirm20261004.4. Mac installation through the stable-identity script remains queued under the shared build lock; installation and permission readiness remain unverified for the Mac candidate. Existing unrelated work and permission identity are preserved.

The DEBUG-only process argument--farside-capture-start-recovery-check drops complete-frame admission for the first producer once. It uses real SCK startup and cleanup; after confirmed cleanup, the second producer runs normally. Ordinary/Release paths omit the fault adapter. Physical injection would prove recovery from successful SCK startup with withheld complete frames, not recovery from missing OS callbacks.

Physical gates (not yet executed for20261004.4): signed Mac candidate inventory and permissions, injected one-time no-first-frame recovery without phone Reconnect, five consecutive fresh picture/End cycles, Home/return and PiP regressions. Source/compile results remain separate from actual device acceptance. Then resume marked source comparisons and realistic multitasking60fps, sharpness and latency checks. No App Store upload, submission or publication.

Raw local receipts belong to the Oct4 Codex chat work/capture-start-checks and work/renderer-checks. No private desktop captures are published.

Current execution blocker: the Mac UI tool reports a locked Mac with automatic unlock paused after physical input. The owner has been asked to unlock it. Phone lock-state reports passcodeRequired:false; no new phone unlock is requested. Earlier physical results belong to20261004.3.
