# Simulator claims receipts — fresh phone selection completed, failed

The finalized fresh phone receipt **completed all 113 selected cases: 93 passed, 20 failed, zero skipped**. The 89 selected unit methods passed. Of 24 UI methods, four passed; all 18 accessibility audits failed, the aggregate five-lesson coach stopped on unsupported pointer events, and session pinch left accessible zoom at **1.0 → 1.0**. This is complete execution of this exact selection, with failed acceptance; it is neither a clean accessibility pass nor proof of all five lessons or pinch. No new iPad result is established here.

The receipt is `logs/20261002T171227.844702Z/phone-check.xcresult`, with finalized summary/tree and text exports alongside it. Its iPhone 17 / iOS 27.0 simulator was `8DF0EC6C-A302-4156-81A4-60D527FF69F2`, arm64, OS build `24A434`. Runtime ran **17:12:30.123–18:32:29.360 UTC**, 4799.237 seconds. The test environment reports macOS 27.0.1. Xcode also recorded the warning “Publishing changes from within view updates is not allowed, this will cause undefined behavior.” This warning is retained separately from test assertions.

## Frozen source and cleanup identity

`tested-build-manifest.json` captures 966 compiler-input files and 49 complete artifact files. The tested UI source SHA256 is `fdd7d14ffe826b79430da714f7208bfdd2d28fe9b457b838b376bbf57364b0f1`; it matches the file at checkpoint `67adf8d7dfe9d80c6761ac6a4ba16edd18ceb18d`. This is the 20aded1 product base with verification harness additions, not proof of a later integrated/uploaded batch-7 build. The current revised UI source has SHA256 `c8d833da440437b5c44bf35139815ffb40c50f6ab767b6a2746a13cca3691cbb`; those later fixture corrections need a fresh compile and runtime receipt.

`PHONE-FINALIZATION-RECOVERY.json` records source and complete artifacts matching before the parent signaled its own Xcode process. All 113 tests had completed and the xcresult had finalized by 18:32:29 UTC. Xcode then stalled during exit-time simulator shutdown; the parent sent SIGTERM only to its own Xcode PID 79547 at 18:39:45 UTC. It later stopped only its own simulator shutdown waiter after more than two minutes. **The recorded native stage exit is 241**, retained independently of the completed, failed XCTest result. A clean native exit and final simulator Shutdown state are not established by this receipt. The cleanup event does not turn completed cases into canceled cases, nor make a failed selection pass. Summary, tree and text export commands returned zero; exact selection acceptance returned **1 / accepted false**.

The fresh scope is **89 unit + 18 bounded audit + 4 claim feature + 2 historical UI methods = 113**. The current runner's revised 117-method phone selection uses five separate coach methods; that future selection did not execute in this receipt. The original eight-method monolithic claims class is still not accepted. Historical interrupted/canceled receipts remain below and in JSON under `historical_finalized_platform_receipts`.

## Fresh accessibility coverage

All nine groups ran at default and AX-XXXL: entry 7, session 11, help 6, coach 6, display 1, settings 9, errors1 8, errors2 7, Home utilities 9. All 18 methods finished their final assertions and failed. There were no exported `audit-error` exception receipts. Reached means the initial hierarchy contains the expected semantic marker and actual navigation-bar title where specified; it does not establish visible/hittable layout or VoiceOver usability.

| Size | Original attempted / reached | Home attempted / reached | Total attempted / reached | Initial audit hierarchies | Audit slices | Callback occurrences |
|---|---:|---:|---:|---:|---:|---:|
| AX-XXXL | 55 / 54 | 9 / 5 | 64 / 59 | 60 | 109 | 372 |
| Default | 55 / 54 | 9 / 9 | 64 / 63 | 64 | 124 | 579 |
| Total | 110 / 108 | 18 / 14 | 128 / 122 | 124 | 233 | 951 |

Both LAN wake attempts captured underlying Settings rather than the intended sheet. Each recorded three fixture/navigation errors: missing LAN wake row, missing owner target field and missing LAN wake navigation title. Their underlying audits are retained in callback/slice counts, but are not promoted to LAN wake coverage. AX-XXXL Home could not reach four menu actions: **Connection Details, Third-Party Notices, Server Data, Settings**. Missing-menu-item hierarchies describe the menu, not the destination. Default Home reached all nine intended contexts; successful reachability did not yield clean audits.

The 18 inventory collectors total **961 entries = 951 callback occurrences + 10 fixture/navigation errors**. Individual callback issue files exactly match the raw issue attachment events; copied descriptions in inventory files are not counted again. The explicit text export contains **1175 files** across 22 test groups, including 951 issue receipts, 124 initial audit hierarchies and 18 completed audit inventories. The remaining files are planned inventories, diagnostic/query text, feature hierarchies and boundary/value receipts. Audit screenshots for 233 visible slices remain in xcresult; text export does not export screenshot images. The JSON preserves each attempted context, the expected marker/title, hierarchy filenames, per-group collectors, per-size counts and exact method outcomes.

| Callback type / raw value | AX-XXXL | Default | Total |
|---|---:|---:|---:|
| Dynamic Type partly/fully unsupported / 65536 | 169 | 252 | 421 |
| Contrast failed/nearly passed / 1 | 125 | 167 | 292 |
| Text clipped / 131072 | 55 | 93 | 148 |
| Potentially inaccessible text / 2 | 20 | 63 | 83 |
| Label not human-readable / 8 | 2 | 2 | 4 |
| Missing disabled trait / 262144 | 1 | 1 | 2 |
| Hit area too small / 4 | 0 | 1 | 1 |

Dynamic Type consists of 373 partly unsupported and 48 unsupported observations; contrast consists of 262 failed and 30 nearly passed observations. There are 217 unique surface/type pairs preserving size and 419 unique visible-slice/type pairs. These are repeated, unfiltered SDK `.all` observations, **not adjudicated unique product defects**. Broad C8/accessibility support and Accessibility Nutrition Label claims remain unproven; physical VoiceOver/navigation and usable Dynamic Type remain separate gates.

## Fresh feature outcomes

| Selected method | Result / scope |
|---|---|
| `testCoachLessonsUseSynthesizedGesturesAllFive` | Failed: **“Pointer events are not supported for this device.”** Move and Click advanced in the raw trace; lesson 3's public pointer-scroll synthesis raised the framework failure. Drag and Zoom did not execute. No five-lesson completion claim. |
| `testSessionPinchChangesAccessibleZoom` | Failed strict numeric comparison: **before 1.0, after 1.0**. The frozen fixture did not admit offline input; the revised quiet input probe needs a fresh run. This receipt establishes a failing fixture, not the cause of physical product behavior. |
| `testKeyboardAndNonRecordingDictationRemainReachable` | Passed default/AX-XXXL keyboard and nonrecording preview entry points at the selected sensitivity settings. No microphone recognition or remote key delivery. |
| `testOfflineConcealmentFixtureAndHomeBackgroundForeground` | Passed offline concealed fixture and actual simulator Home background/foreground lifecycle. No physical live-session app-switcher thumbnail acceptance. |
| `testKeyboardBarPutsCommandFirstAndInReachInPortrait` | Passed selected portrait keyboard bar layout. |
| `testLongVoicePreviewKeepsDoneReachableInLandscapeWithoutRecording` | Passed selected portrait/landscape nonrecording preview layout. |

The full 89-unit result is source/artifact scoped automated evidence. Haptic feel, real dictation, live Stop Sharing, live remote-key delivery, long-session behavior, physical pinch and actual iPad/Duo usability remain separate tests. No native/simulator/process/gate action was issued by this analysis; it read already-finalized receipts and edited only these two evidence files.

---

# Historical simulator claims receipts — finalized incomplete runs

The dedicated phone result is finalized after the parent stopped its own Xcode run. **89 selected unit tests passed; only 2 of 8 claims methods started, both recorded Failed**: AX snapshot query timeout and default-size cancellation. The iPad runner failed before any claims method. Neither platform has full claims-class acceptance.

The shared-simulator phone run was interrupted by a concurrent lane targeting the same `C643B2C2-3248-4AE4-B234-8F54414F3A41` device. `SIM-COLLISION.json` records the other `b8-vdisplay` Xcode PID `89441`, starting at 11:20:27 ET. The parent canceled only its own run/processes and suppressed its simulator shutdown; no other lane or device was touched. The analysis issued no native/session/process/gate command.

## Interrupted raw evidence

The old phone session `41999`, `logs/20261002T132757Z`, has raw progress but **no accepted completed runtime export**. Its partial `phone.xcresult` exists without `Info.plist`; no summary/test-tree/text-attachment exports were accepted. No `xcresulttool` query was attempted by this analysis.

- Before the collision, the selected phone unit suite reported **89 tests, 0 failures** in the raw log. This is scoped raw evidence, not a completed overall/class receipt.
- The original AX-XXXL audit terminated as **failed**, with **305 combined audit issues or fixture errors**, in **1628.997 seconds**. Its original 55-fixture enumeration completed before the collision. This does **not** establish that 55 surfaces were actually reached or that 305 means unique accessibility defects; marker/navigation failures and repeated findings remain unreconciled without completed exports.
- The default original audit lost the app at approximately **1132.42 seconds** and failed at **1155.177 seconds**. This run was affected by the collision; its partial enumeration is not promoted to default-size coverage or acceptance.
- The supplemental AX-XXXL launch stalled. Remaining methods and the overall stage are not accepted.

The old iPad session `44530`, `logs/20261002T132808.947212Z`, was canceled before execution: raw log 0 bytes, no `.xcresult`. It is not an executed XCTest failure or skip. Earlier sessions `60927`/`49184` were also canceled before Xcode execution (`DEFAULT-ALLOWANCE-REQUEUE.json`, runner exit `-15`, logs 0 bytes); their missing-result selection-guard exit `1` is not a test execution result.

## Finalized dedicated receipts

| Platform | Session / run | Result | Claims methods | Measured intended surfaces |
|---|---|---|---|---|
| Phone | `86127` / `logs/20261002T152929.742920Z` | 91 framework cases: 89 passed, 2 failed, 0 skipped | 2 executed: 0 passed, 2 failed; 6 absent | AX 30 reached / 31 attempted; default 42 / 44 |
| iPad | `72739` / `logs/20261002T163430.898388Z` | 1 synthetic runner infrastructure failure | 0 executed; all 8 absent | 0 attempted/reached at either size |

The phone used dedicated iPhone 17 / iOS 27 simulator `B2CED284-1C7E-4FB2-9582-8E740D36E8F4`. Its finalized summary/tree establish the 89 selected unit passes independently of claims coverage. Historical UI methods did not execute. The AX audit failed after **3130.056 seconds** at source line 555 while matching `remote.controls.page` in `settings-display`: “Failed to get matching snapshots: Timed out while evaluating UI query.” The default audit entry records “Testing was canceled”; its tree has no terminal duration. The last activity began at raw method time 1707.00 seconds (`default-error-locked`). The parent reports SIGINT to its own Xcode PID 20716 at 17:03:31; the log ends `TEST EXECUTE INTERRUPTED`. Cancellation is not a product assertion failure.

`phone.xcresult/Info.plist` exists and summary/tree exports are readable. The parent’s `post-stop-identity.json` independently records source and complete artifact identity matching at 17:04:25 UTC. Both runs used frozen UI source SHA `99fb0550b9e207721df7ff5cffa9c9fc3b55548f785b41513f92a5307939adf2`. Identity does not turn an incomplete run into acceptance.

The iPad used dedicated mini A17 Pro / iOS 27 simulator `6D27467D-762C-408E-A18A-B884C2B87CC9`. Xcode exited 65; its runner PID 52775 crashed during preparation at `-[XCTWaiter(StallHandling) handleStalledWait:]`, with no restart. The test tree puts its single failed case under **System Failures**, outside ClaimsVerificationUITests. The empty attachment manifest and selection-guard array establish **zero claim methods, zero attempted/reached surfaces, zero audits**. Its zero callbacks mean no audits ran, not a defect-free product.

## Phone coverage and audit findings

The original inventory planned 55 surfaces per size; the Home supplement planned nine more. Runtime coverage is counted from activity starts and exported initial hierarchies, requiring the expected marker and any actual navigation-bar title. “Reached” establishes semantic presence only; it does not establish visibility, hit testing or usable layout.

| Size | Original attempted / 55 | Intended reached | Captured audit slices | Callback occurrences | Unique surface/type pairs | Unique slice/type pairs |
|---|---:|---:|---:|---:|---:|
| AX-XXXL | 31 | 30 | 52 | 250 | 51 | 82 |
| Default | 44 | 42 | 67 | 275 | 76 | 115 |
| Total | 75 | 72 | 119 | 525 | 127 | 197 |

The Home supplement has **0 of 9 attempted/reached surfaces at both sizes**. The AX query stopped before capturing `settings-display`; the remaining 24 original AX contexts were not attempted. Default reached all original settings-page fixtures except LAN wake, then napping/unreachable/busy errors. It began `error-locked` without a capture before cancellation; the final 11 original default contexts were not attempted. JSON lists every attempted context, its expected marker/title, hierarchy filename and every unattempted original/supplemental surface.

Default `settings-lan-wake` captured underlying session controls, with neither `Owner-registered wake target ID` nor a `LAN wake` navigation bar. This is a navigation/marker discrepancy, not confirmed LAN wake sheet coverage; its audit of underlying controls is retained separately from intended reachability. No AX-display or default-locked hierarchy exists. The unfinished methods did not emit final inventory receipts, so the accumulated fixture-error collector total remains **unknown**, rather than being combined with callback findings.

The explicit text export has **783 files**: 525 individual callback issue receipts, 119 hierarchies, 119 separate-control inventories and 20 diagnostic query/debug descriptions. The 525 issue files exactly match raw issue-attachment events; inventory copies are not counted. The sequential trace shows 119 captured/control-inventoried audit slices followed by subsequent progression; none produced an `audit-error` receipt. Screenshot attachment events are retained in xcresult; text export does not export screenshot images. Findings are unfiltered SDK `.all` callback observations, not adjudicated unique product defects.

| Callback type raw value / description | Occurrences |
|---|---:|
| 65536 — Dynamic Type font sizes partially unsupported / unsupported | 257 |
| 1 — Contrast failed / nearly passed | 163 |
| 131072 — Text clipped | 77 |
| 2 — Potentially inaccessible text | 21 |
| 8 — Label not human-readable | 4 |
| 262144 — Missing disabled trait | 2 |
| 4 — Hit area too small | 1 |

Dynamic Type consists of 209 partially unsupported and 48 unsupported observations; contrast consists of 142 failed and 21 nearly passed observations. The 127 unique surface/type pairs preserve size and merge scrolled slices; 197 pairs preserve each visible slice. These counts still do not deduplicate elements into unique defects. Per-size type breakdowns and compact descriptions are in JSON.

## Unexecuted proof and recovery scope

Six phone claims methods are absent, not skipped: both supplemental Home inventories, five-lesson gestures, keyboard/dictation feature reachability, real Home concealment lifecycle and session pinch. Seeded coach lesson/done audit fixtures do not establish completion gates. Keyboard/transcript and concealed semantic markers appeared in audit fixtures, but no feature interaction or Home background/foreground test ran. There is no numeric pinch before/after receipt and no app-switcher thumbnail evidence. The iPad establishes none of these behaviors. Public mouse-scroll synthesis still cannot establish physical two-finger scrolling; accessibility trees and `.all` scans remain separate from actual VoiceOver navigation and physical usability.

Earlier iPad sessions 1449 and 83689 are archived as canceled-before-execution / superseded queue evidence, not current queued runs. The parent plans a separate bounded fresh recovery for all 89 units, 18 audit fixtures and six feature methods. That future scope is not runtime acceptance and does not erase these failures or missing contexts.

Only `SIM-RESULTS.md` and `SIM-AUDIT-COUNTS.json` were updated. This analysis read finalized exports and source; it issued no native/session/process/gate commands. The parent controls recovery execution, exports and final integration.
