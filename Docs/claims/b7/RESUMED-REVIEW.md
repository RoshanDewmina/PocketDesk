# Resumed independent claims/source review — 2 October 2026

**Source approved, no unresolved P0/P1. No new materially inflated nomination claim or missing consequential atomic clause was found. The documented `all --skip-duo` rerun preserves the exhausted Duo attempt. Native acceptance is pending and is not supplied by this review.**

Reviewed baseline `20aded1554888a949943a837169a8e6de30144ea`, checkpoint `462543ce4afd76742d32036640daab8f4129bbd8`, and the parent's in-progress runner-only repair. The scoped diff from baseline is empty for `RemoteHost`, `RemoteShared`, `RemoteTests`, `RemotePhone`, `Backend`, `project.yml` and `PocketDesktop.xcodeproj/project.pbxproj`. This is production-source identity, not uploaded Release identity. Only this report was written by the reviewer. No build, test, process inventory/control, simulator command, gate operation, app launch/install, real device, provider or store operation was performed.

## Findings

| ID | Severity / confidence | Evidence and consequence | Required correction / disposition |
|---|---|---|---|
| RR1 | Original P1 / certain — RESOLVED IN SOURCE | Original `run.py` called Duo from every `all` run and performed boot/status/unconditional shutdown outside the lock. The parent repair delegates to `duo_probe.py` under the locked cleanup wrapper; README's first command supplies `--skip-duo`. Under-lock Shutdown-state refusal occurs before cleanup's try/finally (`locked.py:24–31`), with an atomic one-attempt marker and bounded probe commands. A further two-slot race was found: both probes could see Shutdown before boot, and the marker loser could clean up the winner. | Final `run.py` Duo call now has `primary=True`, serializing all probe invocations on the canonical primary lock. The recorded six fabricated safety tests pass (`DUO-RUNNER-SAFETY.log`); this reviewer read that receipt, did not rerun it or boot Duo. No repeat of this lane's exhausted attempt is authorized. |
| RR2 | Original P2 / certain — RESOLVED IN SOURCE | `identity.py:7` deliberately excludes `script/claims/`; compiler/bundle manifests do not bind Python verification semantics. During review the parent added an invocation-time `runner-source-manifest.json` (`run.py:33–36`), end hashes/match flag and aggregate failure after a change (`232–238`). The under-lock wrapper separately logs all claims-script hashes before/after native execution and returns78 on mismatch (`locked.py:35–51`). | Source approved as separate verifier evidence without entering compiler identity. Do not edit running verification scripts; endpoint hashes cannot prove the absence of an edit-and-restore between snapshots. Earlier active iPad/phone113 receipts whose runner/wrapper loaded before this delta have no retrospective script guard; source/bundle receipts remain their distinct evidence. This reviewer did not rerun native or synthetic checks. |
| RR3 | P2 / certain | `run.py:92–94, 157–172` records effective settings and `lipo`/`vtool` output. A successful native command is not an assertion that those outputs still say arm64/macOS26 after integration. The documents correctly distinguish these receipts from runtime acceptance, but future setting regressions require a human comparison. | For the integrated/uploaded build, either assert expected values in a semantic platform receipt or explicitly read and record host + watchdog effective Debug/Release ARCHS/minimum, actual Release slices/LC_BUILD_VERSION/Info.plist, and the preserved legacy-target mapping. Do not interpret aggregate command exit zero as C12 semantic acceptance. |

RR1's original unguarded operation, preboot-state edge and serialization edge are superseded by the parent repair observed during this review. The parent also rejects `duo --skip-duo` rather than ignoring the flag. The probe marks its attempt before boot, checks semantic migration failure even at process exit zero, bounds boot/status/state to30/180/10seconds, and uses the existing45second owned shutdown. The recorded failed migration result must stay historical; skipping it is neither a pass nor a new attempt. The fabricated probe tests were read, not rerun by this reviewer. Exclusive lane ownership still depends on cooperative agents; no guard can authorize an unrelated manual simulator user to share that UUID.

## Claim completeness and accuracy

- The matrix covers the submitted Block A as atomic clauses, including separate pinch versus all-edge reachability, distinct iPad/Duo positioning/layout/launch claims, and the tiny-MacBook analogy. Block B covers all thirteen clauses, including owner-supplied founder facts, approval/no-account scope, actual SwiftUI/UIKit and ScreenCaptureKit/VideoToolbox use, accessibility work and English. C1–C13 include split keyboard/speech, four release gates, both reported listing claims and C12's misleading configuration count. No missing consequential atomic claim was found.
- Unsupported tall-iPad and half-folded-Duo trackpad layouts are loudly marked NOT TRUE on baseline. C2's timing guarantee and A13's literal connection wording are also rejected. Settings evidence correctly distinguishes two legacy targets × Debug/Release from four Release configurations. These corrections should remain after integration until their own behavior/source changes receive fresh evidence.
- C1 does not confuse locally accepted transmission/haptic generation with a Mac-applied receipt. C3's on-device recognizer policy is source evidence; seeded voice-preview text is not live speech. C4's teardown wiring and C5's renewable leases are not live host-button or elapsed-session acceptance. Browser's ten-minute cap is explicitly excluded from the native no-limit candidate.
- The verdict's “safe” copy remains qualified by scope. Neither proposed A draft is represented as uploaded-build physical acceptance, and the conditional C1–C5 draft is withheld. C8's original complete-app audit wording and Supports labels remain withheld. A narrower completed-simulator-audit statement can become factual only after both platform inventories finish; failing audits must remain disclosed internally.
- The physical checklist separates its roughly twenty-minute active sitting from the at least thirty-five-minute session tail, complete accessibility assessment, minimum-OS runtime and provider/release gates. Its pointer/click, haptic, actual dictation, live thumbnail, Stop Sharing and fold checks are genuine device gates. An unpaired-client approval check remains pending rather than deleting trusted devices just to manufacture a fresh enrollment.

## Native receipt interpretation

Read-only inspection of finalized `logs/20261002T171227.844702Z/phone-check-report-summary.log` confirms the first bounded phone selection **113 executed / 93 passed / 20 failed / 0 skipped**. All eighteen audit methods failed; Coach failed on unsupported pointer events, and the session pinch comparison failed at 1.0→1.0. This is historical execution evidence for that frozen selection. It is not a fresh result for the corrected ten-feature harness.

The revised selector inventory is **phone117 = 89 units + 18 audits + 10 features**, **iPad28 = 18 audits + 10 features** (`recovery.py:17–28, 160–163`). The corrected Coach tests start behind each real completion gate and require real gesture/Next advancement; unsupported pointer scrolling remains failed and cannot block the independently selected Drag/Zoom methods (`FarsideRedesignUITests.swift:303–401`). Pinch now enables the existing quiet offline input probe while retaining the strict numeric change assertion (`405–429`). Privacy explicitly tests an offline Home lifecycle, not a physical live app-switcher snapshot (`479–497`). All `.all` callbacks and audit exceptions are retained in failure accounting (`754–774`); returning true is not silent acceptance of findings.

At review time another agent is updating finalized113 documentation while corrected iPad28 is active and phone117 compilation is queued. The stale pending113/24 paragraphs observed in matrix/verdict/labels are **concurrent reconciliation work, not an additional finding**. Before handoff, reconcile those paragraphs with the finalized113 result and label the new117/28 attempt separately. Do not overwrite its earlier failures or promote a planned64-surface inventory to reached/usable coverage.

## Future uploaded-build receipt

The documented one-command rerun supplies fresh Debug source/artifact-bound automated evidence. It cannot itself test the uploaded iOS Release binary or notarized Mac distribution. Before public claim use, bind the final matrix to the integrated commit, actual ASC build/version/processing receipt, matching phone/iPad TestFlight or release build identifiers, and released host binary identity/version/signature. Preserve platform receipts, finalized raw results/attachments and physical pass/fail records beside that identity. Physical checks on a development build remain a separate evidence level even when the version number matches.

No new claim is unlocked by this source review. No speed, security, paid-service, complete accessibility, fold-layout or shipping-readiness promise was added.

```json
{
  "verdict": "approve",
  "scope": "Source-only claims completeness, baseline identity and final verification-runner repairs",
  "baseline": "20aded1554888a949943a837169a8e6de30144ea",
  "checkpoint": "462543ce4afd76742d32036640daab8f4129bbd8",
  "unresolvedP0P1": [],
  "resolvedDuringReview": ["RR1 Duo attempt ownership/serialization", "RR2 verifier-script receipt identity"],
  "remainingSuggestions": ["RR3 semantic integrated/Release platform receipt before C12 uploaded-artifact acceptance"],
  "reviewerExecutedNativeOrSyntheticTests": false,
  "reviewerWriteSet": ["Docs/claims/b7/RESUMED-REVIEW.md"],
  "limitations": ["Corrected phone117/iPad28 runtime acceptance remains root-owned and pending.", "No physical, uploaded Release, provider or store acceptance supplied.", "No new Duo attempt authorized or performed."]
}
```
