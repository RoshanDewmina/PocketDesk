# Golden regression evidence — 2 October 2026

This is a historical preservation ledger, not a declaration that the candidate works. The current requested gate target is **batch-7a build 20261002.3**, superseding the original brief’s `20aded1` baseline run request. The parent owns the gate run and receipt; this evidence-only pass ran no Xcode, installed nothing and performed no physical smoke.

**29 historical rows; 28 active rows; 27 active rows with automated proxies; 1 active DEVICE-only row (G28); 28 active rows still require physical evidence.** G21 is retained as RETIRED BY OWNER. There are 24 rows backed by a primary user message and 5 backed only by secondary ledger/state receipts (G02/G06/G26/G27/G28). Primary does not mean full success: grouped prompts, transient results and partial failures are qualified below. Historical build numbers refer to receipt context, not current installation.

The executable row/test contract is [`script/regression-golden.json`](../../script/regression-golden.json). `AUTO` means core/phone deterministic tests; `SIM` means offline simulator UI assertions; `REPLAY` means deterministic policy/reporter traces; `DEVICE` means real capture/input/OS/feel acceptance. An automated proxy PASS never clears DEVICE. Source selector existence was checked, not execution. Current candidate outcomes/runtime belong in the parent’s gate `summary.json` and [`REGRESSION-GATE.md`](REGRESSION-GATE.md).

## Exact source keys and verification scope

| Key | Local source |
|---|---|
| B | [b9a43976-bd4f-4ae9-a920-572f679267a1.jsonl](/Users/roshansilva/.claude/projects/-Users-roshansilva/b9a43976-bd4f-4ae9-a920-572f679267a1.jsonl) — session `b9a43976-bd4f-4ae9-a920-572f679267a1` |
| H | [346864f5-9f1a-4720-aafc-8047f5606b0c.jsonl](/Users/roshansilva/.claude/projects/-Users-roshansilva/346864f5-9f1a-4720-aafc-8047f5606b0c.jsonl) — session `346864f5-9f1a-4720-aafc-8047f5606b0c` |
| J | [c0c606e2-b73b-4df8-821f-e746f100515d.jsonl](/Users/roshansilva/.claude/projects/-Users-roshansilva/c0c606e2-b73b-4df8-821f-e746f100515d.jsonl) — session `c0c606e2-b73b-4df8-821f-e746f100515d` |
| D | [rollout-2026-09-29T15-19-49-01a0ee9b-e581-7941-b18d-542800f41b58.jsonl](/Users/roshansilva/.codex/sessions/2026/09/29/rollout-2026-09-29T15-19-49-01a0ee9b-e581-7941-b18d-542800f41b58.jsonl) — Codex `01a0ee9b-e581-7941-b18d-542800f41b58` |
| L | [feature ledger](/Users/roshansilva/Documents/Codex/2026-10-01/farside-feature-ledger-FINAL.md) — dated 1 October, about 10:05 ET |
| M | [Claude project state](/Users/roshansilva/.claude/projects/-Users-roshansilva/memory/pocketdesk-project.md) — secondary state notes, lines 19/28/33/36/39/41 |

`Key:line` is the physical JSONL/Markdown line, counting from 1. Primary messages at every named manifest anchor and the preceding grouped prompts were parsed directly from the original JSONL. Builds .3/.4 are supported by H:1536 (testing on .3), H:2403 (.4 installed on phone and Mac); phone .2 by B:5595; .7 pinch context by L:360/M:28; .11 by D:5345. The nearest primary message need not independently state its build, so those context mappings are distinguished from user wording.

The prior global inventory is [`b7-regress/claude-inventory-2026-10-01.txt`](/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/b7-regress/claude-inventory-2026-10-01.txt): 195 Cowork metadata records, 0 matching Cowork sessions, 6 Claude parents + 149 subagents, 0 unresolved, `COMPLETE_FOR_LOCAL_ON_DISK_SCOPE`. The inventory has no parent record for B or H despite their existing JSONL files; the H date-index omission is also documented at M:43. Its completeness marker cannot certify the named confirmation corpus, so direct named-path resolution is necessary. This pass resolved B/H/J/D directly and checked the CONFIRMED ledger rows. It did not reread every conversation or certify exhaustive local/cloud history; cloud-only/deleted/unmounted records remain out of scope. Recovered generated extracts are search aids, not primary evidence.

## Historical receipt ledger

Quote cells preserve Roshan’s exact selected words only for primary rows; **secondary cells are explicitly labeled** and must not be repeated as verbatim user speech. See the following per-row limits before claiming success.

| ID | Behavior to preserve | Historical build/context | Selected wording and evidence |
|---|---|---|---|
| G01 | Same-Wi-Fi Connect survives host session construction | 20260930.8 host / phone .7 at 06:49; also 20261001.2 touch receipt | **Primary:** “Yea connection works” — B:3417; host build B:3310; L:345,472 |
| G02 | Control movement reaches the Mac after local authorization | 30 September; exact phone build not recovered | **Secondary ledger/state wording:** “control works now” — L:346 (CR02) |
| G03 | Connected picture appears instead of black screen | 20260929.11 | **Primary:** “yes all works move on to the next part” — D:5345,5355; L:386 (PV09) |
| G04 | Pinch/zoom remains smooth; covered pinch/pan does not churn crop/encoder size | 20260930.7 | **Primary:** “Pinch is smooth now i checked” — B:227; L:360; M:28 |
| G05 | No flicker/blanking across region echoes and ladder size changes | 20261001.2 phone / host .1 | **Primary:** “No flicker” — B:5595,5599; L:378; M:36 |
| G06 | Whole canvas tap clicks without overlay or landing-roll pointer jump | 20261001.2 (secondary touch receipt); earlier daily use | **Secondary ledger/state wording:** “Touch confirmed on .10, and again on 20261001.2” — L:352,370,378; M:36 |
| G07 | Controls panel opens and exposes its actions | 20260930.8 (partial); actions reconfirmed 20261001.3 | **Primary:** “Controls work” — B:3889; H:1772,1794; L:362 |
| G08 | Spaces action switches desktop | 20261001.3 | **Primary:** “2 yes they work” — H:1772,1794 |
| G09 | Mission Control action opens Mission Control | 20261001.3 | **Primary:** “2 yes they work” — H:1772,1794 |
| G10 | Right-click action opens Mac context menu | 20261001.3 | **Primary:** “2 yes they work” — H:1772,1794 |
| G11 | Double-click action emits a double click | 20261001.3 | **Primary:** “2 yes they work” — H:1772,1794 |
| G12 | Hold click/Drop action holds and releases without stuck input | 20261001.3 | **Primary:** “2 yes they work” — H:1772,1794 |
| G13 | Text-field keyboard opens in Notes and Safari | 20261001.3 | **Primary:** “yea keyboard works, little finicky but its ok” — H:1772,1794 |
| G14 | Text-field keyboard opens in Chrome and Claude | 20261001.4 | **Primary:** “yes keyboard appears” — H:2582 item 8,2641 |
| G15 | Files transfer successfully phone to Mac and Mac to phone | 20261001.4 | **Primary:** “FIle transfer works its awesome” — H:2554,2558 |
| G16 | Scroll feel stays fine and scroll does not accidentally become pinch | 20261001.4 | **Primary:** “scroll feel is fine” — H:2554,2558 |
| G17 | Healthy idle session has no false busy/slow pill | 20261001.3 early idle round; .4 reiterated in state note | **Primary:** “no theres no busy or slow pill” — H:1670,1729,1750; M:39,41 |
| G18 | Healthy session avoids Waiting-for-screen and controls-paused notices | 20261001.3 | **Primary:** “Did the picture ever say "Waiting for your Mac's screen" or "controls paused"?, nope” — H:1670 |
| G19 | Big Text makes the Mac text larger when selected | 20261001.4 | **Primary:** “5, works perfectly, would love it if this happens automatically” — H:2582 item 5,2641 |
| G20 | Big Text restores the Mac size after ending the session | 20261001.4 | **Primary:** “5, works perfectly” — H:2582 item 5,2641; J:2017 |
| G21 | Session check opens from Home without connecting — RETIRED BY OWNER | 20261001.4 | **Primary:** “7. yea session check works, it opens” — H:2582 item 7,2641; current BATCH-7-BRIEF item 5 |
| G22 | Couch controls the Mac without picture | 20261001.4 | **Primary:** “couch mode works but the mouse on the lap is so jittery and laggy, but usable” — H:2582 item 4,2641; J:163 |
| G23 | Manual PiP can show a window on Home | 20261001.3 | **Primary:** “manually hitting picture in picture works i see it when i go home” — H:1902 |
| G24 | Live PiP can render moving stream frames | 20261001.4 | **Primary:** “Live pip does seem to work but it is so unbelivable laggy and jittery” — H:2558 |
| G25 | Phone and Mac remain awake/connected during untouched video | 20261001.4 | **Primary:** “9, stable , quality can improve a lot” — H:2582 item 9,2641 |
| G26 | QR/pasted invitation pairing with Mac approval and no account | Earlier builds; exact confirmation build absent | **Secondary ledger/state wording:** “Daily use” — L:368 (CR24) |
| G27 | Stream statistics and Copy Diagnostics are usable | Earlier perf sessions; exact build absent | **Secondary ledger/state wording:** “Used in perf sessions” — L:371 (CR27) |
| G28 | One short staging Anywhere session can connect directly | 30 September 11:24; exact build absent | **Secondary ledger/state wording:** “One ~35 s Anywhere session over direct IPv6” — L:432 (NW15); M:19 |
| G29 | Portrait keyboard keeps draft and Done/Hide controls reachable | 20260929.11 | **Primary:** “yes all works move on to the next part” — D:5345,5355 |

## Row limits and exact executable mapping

Each named method exists in the checked source. These are coverage mappings, not pass receipts. Repeated methods legitimately support several behaviors; rows are not unique-test counts.

### G01 — Same-Wi-Fi Connect survives host session construction

Primary connection-only receipt. B:3467 immediately says movement/zoom fail. The host .8 mapping is a delegated install result at B:3310; phone .7 mapping is secondary M:33. This is not input acceptance.

**Modes:** AUTO, DEVICE. **Physical check:** Connect on same Wi-Fi; picture and input must arrive without host exit.

- `core: SessionIntegrationTests.testRealEnrollmentControlReconnectAndRevocation` — [RemoteTests/SessionIntegrationTests.swift:69](../../RemoteTests/SessionIntegrationTests.swift#L69)

### G02 — Control movement reaches the Mac after local authorization

Secondary ledger preserves a user quote; this pass did not recover its original utterance/build. Movement proxy does not exercise real local authorization.

**Modes:** AUTO, DEVICE. **Physical check:** Move one finger over the canvas; cursor must move.

- `core: NativeGestureEngineTests.testQuickFlickStillMovesFromTheFirstFrames` — [RemoteTests/NativeGestureEngineTests.swift:623](../../RemoteTests/NativeGestureEngineTests.swift#L623)

### G03 — Connected picture appears instead of black screen

Primary grouped portrait receipt; visible moving picture was explicitly asked. UsefulSessionEvidence covers positive visibility after a presented receipt, rejects repeated-source freshness, and invalidates admission; it does not run the renderer or real display. L:386 is earlier black-screen-fix corroboration.

**Modes:** AUTO, DEVICE. **Physical check:** Connect portrait; require newly presented moving picture.

- `phone: UsefulSessionEvidenceTests.testDecodedOrRepeatedSourceAloneNeverSuppliesVisiblePicture` — [RemotePhoneTests/UsefulSessionEvidenceTests.swift:36](../../RemotePhoneTests/UsefulSessionEvidenceTests.swift#L36)

### G04 — Pinch/zoom remains smooth; covered pinch/pan does not churn crop/encoder size

Primary smooth pinch on .7. Covered-region/encoder-size limits are new engineering requirements, not words Roshan approved. H:1794 reports large-zoom jitter on .3; J:163,2017 reports .2 regression. Sim/replay passes do not prove physical smoothness.

**Modes:** AUTO, REPLAY, DEVICE. **Physical check:** Pinch in/out 6 times and pan a zoomed page; no picture jitter or jumps.

- `core: NativeGestureEngineTests.testAsymmetricPinchKeepsOriginalSourceUnderMovingMidpointInControlAndView` — [RemoteTests/NativeGestureEngineTests.swift:61](../../RemoteTests/NativeGestureEngineTests.swift#L61)
- `core: ViewportCaptureTests.testSmallPinchAndPanReplayKeepsCoveredRegionAndEncoderSizeStable` — [RemoteTests/ViewportCaptureTests.swift:502](../../RemoteTests/ViewportCaptureTests.swift#L502)
- `core: ViewportCaptureTests.testReplayConfigurationMatchesEveryEchoedRegion` — [RemoteTests/ViewportCaptureTests.swift:529](../../RemoteTests/ViewportCaptureTests.swift#L529)
- `phone: ViewportCaptureTests.testPinchPanReplayEmitsAtMostOneEscapeAndOneSettledRegion` — [RemotePhoneTests/ViewportCaptureTests.swift:207](../../RemotePhoneTests/ViewportCaptureTests.swift#L207)

### G05 — No flicker/blanking across region echoes and ladder size changes

Primary no-flicker answer follows phone .2 install notice B:5595. The underlying region/ladder causes are source analysis. Exact independent .2 touch wording is secondary M:36/L:378.

**Modes:** AUTO, DEVICE. **Physical check:** Scroll and pinch; displayed content must never blank.

- `phone: ViewportCaptureTests.testRegionEchoAndLadderStepKeepThePresentation` — [RemotePhoneTests/ViewportCaptureTests.swift:532](../../RemotePhoneTests/ViewportCaptureTests.swift#L532)

### G06 — Whole canvas tap clicks without overlay or landing-roll pointer jump

Secondary historical touch acceptance. Landing-roll pointer stability is a focused engineering proxy; no separate Roshan acceptance of every gesture edge case.

**Modes:** AUTO, DEVICE. **Physical check:** Tap a disposable button in a test page; click once at current pointer.

- `core: NativeGestureEngineTests.testLandingRollDoesNotMoveThePointerAndStillClicks` — [RemoteTests/NativeGestureEngineTests.swift:596](../../RemoteTests/NativeGestureEngineTests.swift#L596)

### G07 — Controls panel opens and exposes its actions

Primary panel/action receipt. Reachability and semantic layout are automated; real action execution stays DEVICE. Earlier panel receipt was partial.

**Modes:** SIM, DEVICE. **Physical check:** Reveal dock; open Controls; every action remains reachable.

- `ui: SessionLayoutTests.testOfflineControlsPortraitLandscapeAndKeyboard` — [RemotePhoneUITests/SessionLayoutTests.swift:197](../../RemotePhoneUITests/SessionLayoutTests.swift#L197)

### G08 — Spaces action switches desktop

Primary grouped yes to all five named actions; not five separate spoken results. This is the Controls button, not unverified three-finger gesture parity.

**Modes:** AUTO, DEVICE. **Physical check:** Tap Spaces left/right; require exactly one desktop switch.

- `core: HardwareKeyMapTests.testControlArrowsCarryFnSoMissionControlAndSpacesHotkeysMatch` — [RemoteTests/HardwareInputTests.swift:84](../../RemoteTests/HardwareInputTests.swift#L84)

### G09 — Mission Control action opens Mission Control

Primary grouped yes to all five named actions; not three-finger Mission Control acceptance.

**Modes:** AUTO, DEVICE. **Physical check:** Tap Mission Control; overview opens once, then return.

- `core: HardwareKeyMapTests.testControlArrowsCarryFnSoMissionControlAndSpacesHotkeysMatch` — [RemoteTests/HardwareInputTests.swift:84](../../RemoteTests/HardwareInputTests.swift#L84)

### G10 — Right-click action opens Mac context menu

Primary grouped action approval; hardware-pointer routing is a proxy for the panel-to-Mac path.

**Modes:** AUTO, DEVICE. **Physical check:** Right-click a disposable file/page; context menu opens once.

- `core: HardwarePointerRouterTests.testSecondaryClickAndMiddleClick` — [RemoteTests/HardwareInputTests.swift:239](../../RemoteTests/HardwareInputTests.swift#L239)

### G11 — Double-click action emits a double click

Primary grouped action approval; pointer click count is a proxy for the panel-to-Mac path.

**Modes:** AUTO, DEVICE. **Physical check:** Double-click a test folder; it opens once.

- `core: HardwarePointerRouterTests.testDoubleAndTripleClicksKeepUIKitsCount` — [RemoteTests/HardwareInputTests.swift:197](../../RemoteTests/HardwareInputTests.swift#L197)

### G12 — Hold click/Drop action holds and releases without stuck input

Primary grouped hold/Drop approval. No physical 10-second auto-drop timing choice/acceptance; cleanup correctness remains required.

**Modes:** AUTO, DEVICE. **Physical check:** Hold a disposable window title bar, move, then Drop; pointer no longer drags.

- `core: HardwarePointerRouterTests.testStillPressBecomesAHoldAndDoubleClickDragKeepsCountTwo` — [RemoteTests/HardwareInputTests.swift:223](../../RemoteTests/HardwareInputTests.swift#L223)
- `core: NativeInputSafetyTests.testReleaseBoundaryCannotDropNewerHoldOrEpochAndAcceptsExpiredTokenForExactHold` — [RemoteTests/NativeInputSafetyTests.swift:28](../../RemoteTests/NativeInputSafetyTests.swift#L28)

### G13 — Text-field keyboard opens in Notes and Safari

Primary functional keyboard receipt qualified by “little finicky.” Prompt names Notes/Safari and asks typing; no independent text-content receipt. Probe and preview tests do not run real app AX recognition.

**Modes:** AUTO, SIM, DEVICE. **Physical check:** Double-tap Notes then Safari text fields; keyboard appears and a word reaches Mac.

- `phone: SessionLifecycleTests.testEditableFocusReplyOpensOnlyForNewestFreshClickOnce` — [RemotePhoneTests/SessionLifecycleTests.swift:391](../../RemotePhoneTests/SessionLifecycleTests.swift#L391)
- `ui: SessionLayoutTests.testEditableFocusPreviewOpensExistingKeyboardWithoutSending` — [RemotePhoneUITests/SessionLayoutTests.swift:40](../../RemotePhoneUITests/SessionLayoutTests.swift#L40)

### G14 — Text-field keyboard opens in Chrome and Claude

Primary keyboard-open answer to Chrome/Claude prompt. Cursor editor/terminal is not confirmed. Tests cover a positive reply and stale-reply refusal, not universal app recognition.

**Modes:** AUTO, DEVICE. **Physical check:** Double-tap Chrome and Claude text fields; keyboard opens.

- `phone: SessionLifecycleTests.testEditableFocusReplyOpensOnlyForNewestFreshClickOnce` — [RemotePhoneTests/SessionLifecycleTests.swift:391](../../RemotePhoneTests/SessionLifecycleTests.swift#L391)
- `phone: SessionLifecycleTests.testEditableFocusReplyRejectsLateWrongEpochNoneditableAndDismissed` — [RemotePhoneTests/SessionLifecycleTests.swift:406](../../RemotePhoneTests/SessionLifecycleTests.swift#L406)

### G15 — Files transfer successfully phone to Mac and Mac to phone

Primary GROUPED file-round praise after File, Photo, From Mac and Share were suggested. Each direction/entry point was not separately acknowledged. Both directions are required regressions and have deterministic transport tests; do not label four distinct physical flows proven.

**Modes:** AUTO, DEVICE. **Physical check:** Send a tiny disposable file in each direction; open contents and compare SHA-256.

- `core: FileTransferEngineTests.testPhoneToMacTransferArrivesIntactInChunks` — [RemoteTests/FileTransferTests.swift:350](../../RemoteTests/FileTransferTests.swift#L350)
- `core: FileTransferEngineTests.testMacToPhoneRequestDeliversThePickedFile` — [RemoteTests/FileTransferTests.swift:458](../../RemoteTests/FileTransferTests.swift#L458)
- `phone: SendToMacTests.testImmediateFileSendsAndReportsProgress` — [RemotePhoneTests/PhoneFileTransferTests.swift:248](../../RemotePhoneTests/PhoneFileTransferTests.swift#L248)

### G16 — Scroll feel stays fine and scroll does not accidentally become pinch

Primary scroll-feel receipt. Accidental-pinch prevention is an engineering invariant covered by gesture tests; physical cadence still needs hands.

**Modes:** AUTO, DEVICE. **Physical check:** Flick a long page up/down at 1x and zoom; smooth continuing scroll, no unintended scale.

- `core: NativeGestureEngineTests.testRecognizedScrollCannotTurnIntoZoomAndEndsOnceAcrossInterruptions` — [RemoteTests/NativeGestureEngineTests.swift:526](../../RemoteTests/NativeGestureEngineTests.swift#L526)
- `core: NativeGestureEngineTests.testUnequalParallelFingerMotionScrollsAtCloseSkewedAndThumbSpacings` — [RemoteTests/NativeGestureEngineTests.swift:407](../../RemoteTests/NativeGestureEngineTests.swift#L407)

### G17 — Healthy idle session has no false busy/slow pill

Primary transient absence only: H:1729 then says “now im seeing a busy pill.” M:39/41 reports .4 busy pill gone, secondary only. Candidate needs fresh check; no claim .3 was always healthy.

**Modes:** AUTO, REPLAY, DEVICE. **Physical check:** Leave still page visible for 60 s; no false busy/slow pill.

- `core: LadderPolicyTests.testAnIdleSourceWithAHealthyPhoneAndNetworkNeverStepsDownAndClimbsBackToTheTop` — [RemoteTests/LadderPolicyTests.swift:772](../../RemoteTests/LadderPolicyTests.swift#L772)
- `core: LadderPolicyTests.testBusyStaysOkWhileTheLadderHoldsTheTop` — [RemoteTests/LadderPolicyTests.swift:588](../../RemoteTests/LadderPolicyTests.swift#L588)

### G18 — Healthy session avoids Waiting-for-screen and controls-paused notices

Primary healthy-session answer “nope”; not an approval to hide legitimate paused/waiting states. Region echo is one causal proxy.

**Modes:** AUTO, DEVICE. **Physical check:** During healthy picture/input, no waiting/paused banner or loss of input.

- `phone: ViewportCaptureTests.testRegionEchoAndLadderStepKeepThePresentation` — [RemotePhoneTests/ViewportCaptureTests.swift:532](../../RemotePhoneTests/ViewportCaptureTests.swift#L532)

### G19 — Big Text makes the Mac text larger when selected

Primary grouped Big Text on/end receipt. Automatic first-use behavior was requested, not accepted as working. J:163 later reports phone/Mac mismatch and false failure pill on .2.

**Modes:** AUTO, SIM, DEVICE. **Physical check:** Select Big Text; real Mac display mode changes and phone text matches; no misleading failure pill.

- `phone: BigTextPhoneTests.testSavedLevelAppliesOnceWhenTheMacSupportsIt` — [RemotePhoneTests/BigTextPhoneTests.swift:217](../../RemotePhoneTests/BigTextPhoneTests.swift#L217)
- `ui: BigTextUITests.testChoosingAStepShowsProgressThenSelection` — [RemotePhoneUITests/BigTextUITests.swift:13](../../RemotePhoneUITests/BigTextUITests.swift#L13)

### G20 — Big Text restores the Mac size after ending the session

Primary grouped prompt explicitly asks switch back at end. Timing not accepted as instant: J:2017 asks why it takes so long; “at least ~10 s” is the batch brief’s secondary wording. Measure candidate duration, do not invent an approved deadline.

**Modes:** AUTO, DEVICE. **Physical check:** End session; original Mac display mode returns; measure restore delay.

- `core: BigTextControllerTests.testSessionEndRestoresModeAndWindowsWithoutResuming` — [RemoteTests/BigTextControllerTests.swift:396](../../RemoteTests/BigTextControllerTests.swift#L396)

### G21 — Session check opens from Home without connecting

RETIRED BY OWNER for current batch-7a .3: historical Home Session check opened, but owner requested its pill removed. No active gate selector/device smoke; absence is intentional, not failure. Diagnostics elsewhere is a separate behavior.

**Current status: RETIRED BY OWNER.** No active selector or smoke obligation. Historical controller test was `PhoneDiagnosticsTests.testActualControllerCancelsQueuedProbeAndRetainsDeletableReportWithoutSend`, which tested cancellation/report lifecycle rather than Home navigation.

### G22 — Couch controls the Mac without picture

Primary PARTIAL: controls work/usable, while pointer jitter/lag is explicitly rejected. No smoothness acceptance; J:163 repeats smoother but jittery/laggy.

**Modes:** AUTO, DEVICE. **Physical check:** Enter Couch; move pointer and type one key with no picture.

- `phone: CouchPhoneModelTests.testCouchControlsWithoutAPicture` — [RemotePhoneTests/CouchPhoneModelTests.swift:34](../../RemotePhoneTests/CouchPhoneModelTests.swift#L34)

### G23 — Manual PiP can show a window on Home

Primary PARTIAL: window appears, but full same utterance says stream stuck and tapping it back crashes. Automated prepared/start/ownership tests are proxies. Full PiP lifecycle has never been accepted by this receipt.

**Modes:** AUTO, DEVICE. **Physical check:** Start manual PiP, go Home; window appears.

- `phone: PhoneMediaSessionIntegrationTests.testInjectedControllersMacMuteDoesNotDeactivatePreparedPiPAndTerminalStopReleasesLastOwner` — [RemotePhoneTests/PhoneMediaSessionIntegrationTests.swift:35](../../RemotePhoneTests/PhoneMediaSessionIntegrationTests.swift#L35)
- `phone: PhoneMediaSessionIntegrationTests.testInjectedPiPPreparesCategoryBeforePossibleAndReleasesRefusedStart` — [RemotePhoneTests/PhoneMediaSessionIntegrationTests.swift:48](../../RemotePhoneTests/PhoneMediaSessionIntegrationTests.swift#L48)

### G24 — Live PiP can render moving stream frames

Primary PARTIAL: live frames appear; lag/jitter rejected and automatic trigger still fails. Frame handoff unit test is not OS PiP delivery or lifecycle proof.

**Modes:** AUTO, DEVICE. **Physical check:** Animate clock/page on Mac; manual PiP receives new frames.

- `phone: PhonePresentationLifecycleTests.testPiPSinkHandsDecodedFramesStraightToTheLayer` — [RemotePhoneTests/PhonePresentationLifecycleTests.swift:152](../../RemotePhoneTests/PhonePresentationLifecycleTests.swift#L152)

### G25 — Phone and Mac remain awake/connected during untouched video

Primary grouped “9, stable” follows 10-minute hands-off prompt. Actual measured duration is not independently timestamped; image quality rejected. 60-second smoke is only a symptom check and cannot renew ten-minute acceptance.

**Modes:** AUTO, DEVICE. **Physical check:** 10 minutes no phone/Mac interaction; neither screen sleeps, stream continues.

- `core: PhoneIdleTimerTests.testTransferCompletionCannotReleaseLiveViewOnlySession` — [RemoteTests/PhoneIdleTimerTests.swift:5](../../RemoteTests/PhoneIdleTimerTests.swift#L5)
- `core: HostAvailabilityTests.testIdleConnectedSessionKeepsAssertionsWithoutInputOrAudioActivityAndPauseReleasesDisplay` — [RemoteTests/HostKeepAwakeTests.swift:192](../../RemoteTests/HostKeepAwakeTests.swift#L192)

### G26 — QR/pasted invitation pairing with Mac approval and no account

Secondary “Daily use,” not verbatim Roshan. Exact build and separate QR/paste receipts absent. Test fresh pairing only in an isolated disposable setup; do not replace the owner’s current phone trust.

**Modes:** AUTO, DEVICE. **Physical check:** On disposable pair only: scan/paste invitation, Approve on Mac, Connect without account.

- `core: SessionIntegrationTests.testRealEnrollmentControlReconnectAndRevocation` — [RemoteTests/SessionIntegrationTests.swift:69](../../RemoteTests/SessionIntegrationTests.swift#L69)

### G27 — Stream statistics and Copy Diagnostics are usable

Secondary grouped perf-use receipt; exact Copy Diagnostics UI completion not directly acknowledged. Tests certify serialization/sanitization, not pasteboard UI completion. Clipboard content feature is explicitly rejected separately.

**Modes:** AUTO, DEVICE. **Physical check:** Open stats, observe PDSTATS; Copy Diagnostics produces sanitized nonempty report.

- `core: StreamStatisticsTests.testLogLineIsSingleLineMachineReadableJSON` — [RemoteTests/StreamStatisticsTests.swift:257](../../RemoteTests/StreamStatisticsTests.swift#L257)
- `core: HostDiagnosticsReportTests.testReportCoversSupportFactsAndNothingPrivate` — [RemoteTests/HostDiagnosticsTests.swift:45](../../RemoteTests/HostDiagnosticsTests.swift#L45)

### G28 — One short staging Anywhere session can connect directly

Secondary ~35-second direct IPv6 staging session only. No TURN, cellular or long-session acceptance. Existing entitlement and route must be available; otherwise BLOCKED. Never create/deploy a pass merely for smoke.

**Modes:** DEVICE. **Physical check:** With orchestrator-approved existing staging developer entitlement, phone off home Wi-Fi; connect 35 s and confirm direct internet route.

**No deterministic check mapped:** route/provider entitlement is a DEVICE precondition.

### G29 — Portrait keyboard keeps draft and Done/Hide controls reachable

Primary grouped portrait moving-video/keyboard/draft/Done-Hide receipt on .11. D:5358 plans to independently verify text on Mac, so exact “Farside check 11” delivery remains unverified.

**Modes:** SIM, DEVICE. **Physical check:** Open keyboard portrait; draft/Done/Hide visible, type then Hide.

- `ui: SessionLayoutTests.testKeyboardKeepsDeliberatelyTypedMultilineDraft` — [RemotePhoneUITests/SessionLayoutTests.swift:347](../../RemotePhoneUITests/SessionLayoutTests.swift#L347)
- `ui: SessionLayoutTests.testOfflineControlsPortraitLandscapeAndKeyboard` — [RemotePhoneUITests/SessionLayoutTests.swift:197](../../RemotePhoneUITests/SessionLayoutTests.swift#L197)

## Small behaviors that must not become invented confirmations

| Requested item | Evidence and regression treatment |
|---|---|
| Busy/slow and waiting/paused pill text | G17/G18 preserve transient absence; H:1729 explicitly contradicts the earlier no-busy result. Legitimate failure notices remain required. Exact typography/copy was not independently approved. |
| Session check pill | G21 opened historically, then the owner requested removal in the current brief. Do not require its presence. |
| Buttons/positions the owner liked | L:362 preserves “A is good” (Controls option A design approval, 29 September), not proof of every button position. G07/G29 cover Controls reachability and portrait keyboard Done/Hide. No separate exact coordinate/landscape/iPad preference receipt was found in the named messages. |
| Copy Diagnostics | G27 is secondary grouped perf-use evidence; serialization/report tests are mapped. This is separate from content clipboard copy/paste. |
| Clipboard content, phone↔Mac | **NOT CONFIRMED.** H:2641: “copy paste doesnt work i think,” despite a success message; janky workflow rejected. Check both directions separately in later acceptance; never count diagnostic-copy tests as clipboard proof. |
| Mic/dictation | **NOT CONFIRMED.** H:2586: “Cant get out of this screen and app doesnt bring up the permission thingy for me to use mic.” Priming/permission fixes and tests do not become physical acceptance. |
| Mac audio | **NOT CONFIRMED.** H:2641: “Audo is not working.” The later explanation about switches is not a user success receipt. |
| PiP | G23/G24 preserve narrow window/frame function only. Automatic Home triggering, smoothness and safe return were rejected/unverified. |
| Files | G15 preserves grouped praise. Individual File/Photo/Share/from-Mac paths need distinct smoke receipts when exercised. |
| Pairing | G26 is secondary daily-use support. New pairing must use an isolated setup; one-device replacement can unpair the owner’s phone. |
| Keyboard text delivery | D:704 contains “All four work” to a grouped click/double-click/text/scroll question, alongside a simultaneous clarification asking for computer-use assistance. Treat as qualified corroboration; exact .11 string delivery remained independently unverified at D:5358. |
| Auto-drop, haptics, three-finger gestures | L:362 auto-drop timing unanswered; L:353 haptic strength unchecked; L:358 three-finger stutter never retested. No new golden success claim. |
| iPad/new shell | Current universal support requirement does not imply acceptance of the new iPad layout. No mirrored iPhone/simulator result certifies iPad hands/feel. |

## Candidate decision

Run the parent’s gate against the exact batch-7a `.3` source revision, record all terminal XCTest/replay receipts, then execute [`DEVICE-SMOKE.md`](DEVICE-SMOKE.md). Record PASS/FAIL/BLOCKED/PENDING per row, with installed build numbers and source revision. Retired G21 is RETIRED, never synthetic PASS. Missing real-device prerequisites remain BLOCKED or PENDING; short symptom checks and automated proxies cannot renew the historical ten-minute keep-awake or establish full PiP/Anywhere/clipboard/mic/audio acceptance.
