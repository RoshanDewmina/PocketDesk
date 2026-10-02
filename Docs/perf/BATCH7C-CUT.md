# Batch 7c cut receipt — build 20261002.5

All requested automated suites/builds and the golden gate passed on clean source revision `129d4b35cda31100f688e016f36c8ba4381b9933` (base `0249019`). Source packages and version were frozen before 17:40 ET. The comprehensive fresh review found one host First60 blocker; the surgical correction passed a separate fresh read-only review with no remaining actionable findings. The signed candidate is ready for owner testing. No installation, main merge, ASC/upload, deployment or physical acceptance is performed here.

## Candidate artifacts and owner install commands

Phone: `/Volumes/Studio/Development/Caches/batch7c-DD/Build/Products/Debug-iphoneos/PocketDeskRemote.app`

Host: `/Volumes/Studio/Development/Caches/batch7c-DD/Build/Products/Debug/PocketDeskRemoteHost.app`

Owner-only phone command (not executed):

```sh
xcrun devicectl device install app --device 00008150-0001653C26F8401C /Volumes/Studio/Development/Caches/batch7c-DD/Build/Products/Debug-iphoneos/PocketDeskRemote.app
```

Host command only after this candidate is integrated into the main checkout; do not install from the worktree. It preserves the existing certificate identity/path and permission guard. Not executed:

```sh
cd /Users/roshansilva/Developer/PocketDesk
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer POCKETDESK_DERIVED_DATA=/Volumes/Studio/Development/Caches/batch7c-DD ~/bin/farside-lock script/build_and_run.sh
```

These are certificate-signed Debug test artifacts. TestFlight requires a Release distribution archive and the owner's manual validation/upload; the ported archive/Developer ID/DMG fixes have not been executed as Release distribution checks.

## Cut scope

Included: security-small `74526ee` (integrated `efd26ad`); release port `09d831f`/`cd57e99` and encryption metadata correction; first60 `c0c838b`; ux-phone `be54ec8`; P03 connection recovery `11e70e1`; design-polish `615da86` including action-only dock and Control/View + Fit/Fill segments; ux-host `8dc05a0`. Each lane passed focused checks before the next merge.

Deferred: engineering-health/P34 (saved `claude/batch-7c-eh-attempt` at `aff1b9b`); input-parity; audio; host-capture. The 7PM order explicitly put these in the next batch. P04–P06 remain unimplemented pending backend/negotiated contracts. Phone-render, diagnostics, b9*, b7-duo/unlock/codec and backend-only lanes are outside this cut. No selected cut lane was dropped.

## New default-OFF physical A/B checks

| Key | Baseline | Experiment | Owner check |
|---|---|---|---|
| `PocketDeskAccessibleKeyList` | absent/NO | YES | At largest accessibility size, portrait/landscape/iPad Controls is an uncapped scrollable two-column key list; Settings, End and all keys remain reachable. Compare original capped grid. VoiceOver and physical acceptance remain pending. |
| `farsideBoundedPopoverDisabled` | absent/YES | NO | On smallest/scaled display, warnings, scoped guest state, Big Text/Away and long title fit; scroll details; Keep Sharing/Stop and footer stay reachable. Long-scope confirmation gives only 3 pt to details in a 480 pt fixture. Real AX/FKA and owner keyboard focus remain pending. |

Other new behavior is default ON. Rollback probes (fresh process): `PocketDeskFirst60Disabled YES`; `PocketDeskRouteAwareTroubleshooting NO`; `PocketDeskPairingAnnouncements NO`; `PocketDeskSessionTouchTargets NO`; `farsideTransientTimeoutRecoveryDisabled YES` (fresh coordinator); `farsideScopedPopoverControlsDisabled YES`; `farsidePopoverGuestAudienceDisabled YES`; `farsideAgentHookCopyFailureDisabled YES`; `PocketDeskShareProtectionDisabled YES` in both phone and Share extension domains, restarting both. Keep inherited `PocketDeskScrollFixes` and `PocketDeskViewportCapture` OFF for baseline acceptance. No audio/capture experiment from excluded lanes is added.

## Owner smoke and residual risks

Fresh pairing: exact six-digit comparison, explicit Mac Allow, Local Network denial/retry, replacement Cancel and confirmed replacement. First picture: quiet Home/Get Mac link, options return only after picture, controls and Control/View Fit/Fill, keyboard opening/reopening, held-input release, Files/Clipboard, landscape Couch/Settings. Saved-pair timeout: automatic bounded retry, Stop prevents retry, fresh enrollment/trust failures remain terminal. Confirm privacy curtain, background/return, Listen/PiP and Big Text restoration.

Source/UI tests establish admission and layout proxies, not remote-control performance or physical picture/audio quality. The bounded host fixture renders correctly but exposes only a root AXGroup to its harness; FKA was off, so keyboard/AX acceptance is open. Clipboard copy still ignores the return value from NSPasteboard.setString after clearContents (inherited nonblocking P2; an ownership-change write failure could report success); missing-script/install failure paths preserve prior clipboard and show an error. G04 is an explicit keepBand=true opt-in proxy; it does not establish default-OFF runtime churn acceptance or change defaults.

External command/review/image receipts: `/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/batch-7c/`. Original failed runs remain alongside corrected reruns.

## Final automated verification

| Check | Total | Passed | Skipped | Failed | Receipt |
|---|---:|---:|---:|---:|---|
| Full RemoteCoreTests | 1990 | 1977 | 13 | 0 | `logs/core-tests-20261002T173757.log` |
| Full RemotePhoneTests | 775 | 773 | 2 | 0 | `logs/phone-tests-20261002T171740.xcresult` |
| Batch7b UI selection | 32 | 21 | 11 | 0 | `logs/phone-ui-20261002T171911.xcresult` |
| Release fixtures | 23 | 23 | 0 | 0 | `release-final-all-fixtures.log` |

Phone/UI counts were checked against xcresult test-results summaries. Full UI includes every SessionLayout test and both automatic-keyboard portrait/initial-landscape PhoneParity checks. The 11 UI skips require paired-device or regular-width/iPad fixtures. Host focused tests 47/47 and source-matched bounded/unbounded render fixture passed before source freeze; true AX/FKA acceptance remains open.

Build receipts: core `173754`; phone simulator `171653`; host Debug `173739`; signed iphoneos Debug `172806`, with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates`. Required release fixtures 23/23 PASS; gate self-test PASS. First full phone attempt `170939` failed one StoreKit 120 s timeout and two stale First60 fixtures. Cold unchanged billing test `171555` passed 1/1; four-line fixture correction `97e800b` passed 13/13 then full 775-test run. No purchase code, assertion, deadline or allowance was weakened.

Strict deep signature audit confirms Apple Development certificate-backed team `39HM2X8GS6` on both apps, arm64 executables, all four production bundle versions `20261002.5`, Share+Widgets extension versions, both known-device provisioning coverage and signed App Groups, universal phone/iPad families, four emitted iPad orientations, no hardcoded encryptionYES, and built ProductInteraction linked/no-tracking manifest. Receipt `final-artifacts.json`; these are Debug certificates, not Release distribution acceptance.

## Golden gate rows

Exact invocation:

```sh
python3 script/regression_gate.py --derived-data /Volumes/Studio/Development/Caches/batch7c-DD --logs /Users/roshansilva/Documents/Codex/2026-10-01/perf-push/batch-7c/gate-run2 --expected-build 20261002.5
```

Gate PASS in 349.5 s; every stage exited 0; clean source at invocation; 538 source hashes still match. All seven replay checks passed. Temporary simulator cleanup passed. Source receipt: `gate-run2/source-manifest.json`; result: `gate-run2/summary.json`.

| Row | Behavior | Gate | Physical |
|---|---|---|---|
| G01 | Same-Wi-Fi Connect survives host session construction | PASS | PENDING |
| G02 | Control movement reaches the Mac after local authorization | PASS | PENDING |
| G03 | Connected picture appears instead of black screen | PASS | PENDING |
| G04 | Pinch/zoom remains smooth; covered pinch/pan does not churn crop/encoder size | PASS | PENDING |
| G05 | No flicker/blanking across region echoes and ladder size changes | PASS | PENDING |
| G06 | Whole canvas tap clicks without overlay or landing-roll pointer jump | PASS | PENDING |
| G07 | Controls panel opens and exposes its actions | PASS | PENDING |
| G08 | Spaces action switches desktop | PASS | PENDING |
| G09 | Mission Control action opens Mission Control | PASS | PENDING |
| G10 | Right-click action opens Mac context menu | PASS | PENDING |
| G11 | Double-click action emits a double click | PASS | PENDING |
| G12 | Hold click/Drop action holds and releases without stuck input | PASS | PENDING |
| G13 | Text-field keyboard opens in Notes and Safari | PASS | PENDING |
| G14 | Text-field keyboard opens in Chrome and Claude | PASS | PENDING |
| G15 | Files transfer successfully phone to Mac and Mac to phone | PASS | PENDING |
| G16 | Scroll feel stays fine and scroll does not accidentally become pinch | PASS | PENDING |
| G17 | Healthy idle session has no false busy/slow pill | PASS | PENDING |
| G18 | Healthy session avoids Waiting-for-screen and controls-paused notices | PASS | PENDING |
| G19 | Big Text makes the Mac text larger when selected | PASS | PENDING |
| G20 | Big Text restores the Mac size after ending the session | PASS | PENDING |
| G21 | Session check opens from Home without connecting | RETIRED | — |
| G22 | Couch controls the Mac without picture | PASS | PENDING |
| G23 | Manual PiP can show a window on Home | PASS | PENDING |
| G24 | Live PiP can render moving stream frames | PASS | PENDING |
| G25 | Phone and Mac remain awake/connected during untouched video | PASS | PENDING |
| G26 | QR/pasted invitation pairing with Mac approval and no account | PASS | PENDING |
| G27 | Stream statistics and Copy Diagnostics are usable | PASS | PENDING |
| G28 | One short staging Anywhere session can connect directly | DEVICE | PENDING |
| G29 | Portrait keyboard keeps draft and Done/Hide controls reachable | PASS | PENDING |

Overall automated PASS is 27 automated row PASS plus G21 deliberately RETIRED and G28 DEVICE-only pending. Every row marked DEVICE still needs owner smoke, even where its automated proxy passed. Gate does not set experiment defaults.

## Fresh source review and cleanup

Separate fresh-context `codex exec` GPT-6.1-Sol/high read-only review was started only after gate PASS and artifact audit. No build/edit/device/installed-host/provider operation is authorized in that review. Comprehensive review `cross-lane-review.md` found one P1; one-line correction `129d4b3` passed independent source review, host build, focused 106/106, full core and a second gate/audit. Fresh closure `cross-lane-review2.md` approves the correction with no actionable P0/P1/P2 findings; exact commands/logs are external. Own integration simulator `DB7419BD-1DF0-4919-B04B-065784E74514` is Shutdown; gate-owned temporary simulator was deleted. Foreign simulators, locks/worktrees and installed host remain untouched.

The comprehensive fresh review found a ready First60 listener state transition blocker. Correction `129d4b3` invokes the existing `reconcileSharing()` after listener startup; existing Screen Recording, display readiness, explicit pairing approval, capture preflight and causal-input authority remain enforced. Independent correction review approved; rebuilt host and 106 focused setup/host tests passed, followed by a full core rerun (1,990 total, 13 skipped, zero failures). Only HostModel.swift changed after the earlier full phone/UI passes; manifest comparison verifies their source remains byte-identical. Second source-matched gate `gate-run2` passed all stages/rows/replays in 349.5 s; strict artifact audit passed again. Fresh correction closure `cross-lane-review2.md` APPROVES the correction with no actionable findings. Original gate-run1/review/failure receipts remain preserved.

P03 retries are bounded by count rather than elapsed time. Repeated 20-second timeouts can exceed the historical “about 90 seconds” comment; this is a source inference, not a measured duration. Stop cancellation remains required in owner smoke.

Final bookkeeping found a generated PBX rewrite after verification. Its two object identifiers and group/source-list ordering were normalized for comparison; parsed build membership/settings were equivalent. The unknown rewrite is preserved externally and the exact tested project was restored. All 538 gate2 hashes match. Receipt: `generated-project-restoration.json`.
