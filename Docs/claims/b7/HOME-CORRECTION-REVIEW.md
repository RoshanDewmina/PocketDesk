# Home/Coach/LAN correction — independent source review

Verdict: **approve, source-only**. No unresolved findings in the final correction at `97e71f2e18f7c43b4ba8a874f8db67c736ba72e9`, based on `a8b62d0f646d375f5150d956654e5e9b2227a256`. This covers initial package `f484be2`, bounded follow-up `efda143`, and the one-line LAN call-site correction `97e71f2`. Recovery worktree was clean when read. The separately reviewed, uncommitted main `script/claims/locked.py` at main `67adf8d7dfe9d80c6761ac6a4ba16edd18ceb18d` has SHA-256 `9df8f384b3a9c0b4656805aa595e31091f9580c6bca7ead8d96880a7ee1040bf`.

The earlier native phone result remains **FAIL**: finalized `logs/20261002T171227.844702Z/phone-check-report-summary.log` reports 113 executed / 93 passed / 20 failed / 0 skipped / 0 expected failures. Its exact-selection acceptance is false. All 18 audit methods failed with retained findings; the aggregate Coach method failed on unsupported pointer events, and pinch failed its strict 1.0→1.0 comparison. These corrections do not replace that receipt or establish fresh native acceptance. `PHONE-FINALIZATION-RECOVERY.json` records the parent's subsequent owned-process finalization recovery and source/artifact MATCH receipt; this reviewer performed no process/device action.

## Source findings resolved before approval

1. **Popup clipping fallback:** `f484be2` accepted any containing Other ancestor, including full-screen wrappers. With the real clip absent from the query, collection∩app could authorize a gesture below the popup. `efda143` requires a positive finite on-window ancestor with matching horizontal menu bounds, excluding full/near-full app wrappers; oversized/off-window/full-wrapper-only geometry fails before any tap/drag. It then intersects all matching containing ancestors. The recorded phone XXXL tree has menu collection `{12,70,370,874}` and real clip `{12,70,370,520}`; the calculated endpoints197,486→197,200 are inside that recorded clip. This calculation is source/evidence inspection, not a gesture run.
2. **LAN destination virtualization:** the owner field follows long instructions in `LANWakeView`'s Form, so an immediate existence requirement could stop coverage at large text sizes. `efda143` audits the initial LAN destination before that gate, requires one hittable foreground Form excluding the prior named Settings form, and searches it with at most six scrolls. Each slice keeps a screenshot and unfiltered `.all` audit; title/Form loss, ambiguity or exhausted owner-field search remains failure.
3. **LAN outer swipe bypass:** the inventory's generic `app.scrollViews.firstMatch` swipe remained after the new LAN helper. `97e71f2` excludes `.openLANWake` from that call site, preserving the six-scroll bound and foreground-only destination search.

## Checks by read inspection

- The package changes only the existing UI test file, `recovery.py`, README and runner feature-count metadata. The follow-ups change only that UI test file. The diff from production baseline `20aded1` contains claims records, verification scripts and UI tests; no application/Core/Backend/project compiler input changed.
- Home uses the actual collection identified by initial Your Macs/How to steer rows. Targets are exact descendants from a five-label navigation allowlist and must be wholly within the derived visible rectangle and hittable. At most six drags use coordinates within that rectangle. No Home swipe fallback, arbitrary-row tap, destructive action, pairing/provider action or Connect action is added. Every scrolled menu audit retains all findings.
- Five atomic Coach methods share the real starting caption, hidden Next/Done gate, original bounded gesture attempts and required reachable Next/advancement. Only final Zoom reveals/taps Done. The legacy aggregate remains selected by the original eight-method guard. Unsupported public pointer Scroll remains a failure; it is neither skipped nor forced complete, and cannot strand the separately selected Drag/Zoom methods.
- Pinch adds only the existing quiet offline input probe arguments. Its real canvas pinch and strict numeric greater-than assertion remain. The existing probe records locally rather than sending control; privacyShield/contentConcealed, controls and voice hit-testing gates remain in production source.
- LAN waits for landscape, navigates actual Controls→Settings, searches only the named Settings form for the real row even when virtualized, then requires the LAN title and reachable owner field. It performs no field entry, setting mutation, wake/Send request or canvas gesture.
- All nine audit groups, 18 audit methods and 64 surfaces per size remain. Recovery selects 10 feature/UI methods: five atomic Coach plus five retained noncoach methods. Exact combined selections are phone 117 = 89 units + 18 audits + 10 features and iPad 28 = 18 + 10. The unchanged exact-result guard requires matching Class/method identities/counts, all Passed, and zero failures/skips/expected failures; missing, duplicate, unsupported, unexpected or empty selections cannot pass. The original eight-method selectors/aggregate and historical failure meaning remain.
- The `.all` callback retains audit type, compact and detailed descriptions; exceptions and reachability failures join the final nonempty-issues assertion. It does not filter finding types or suppress findings. Initial hierarchy and all initial/scrolled screenshots remain; LAN's final audit omits only a redundant hierarchy after its already retained initial tree.
- The main cleanup delta bounds only the owned `simctl shutdown` CLI to 45s, with a read-only 10s device-state fallback after nonzero exit. Unknown/non-Shutdown state or timeout converts otherwise successful native execution to 81; existing native failure codes stay failures. Already Shutdown permits successful cleanup. It never returns retry 75 or performs a global service reset/other-device action. The existing source/artifact checks and destination-conflict guards remain. No Xcode-finalization watchdog was added.

Author/root static and synthetic receipts were read as their evidence, including `RECOVERY-HOME.md` and `CLEANUP-TIMEOUT-CHECKS.json`; this reviewer did not rerun them. Reviewer actions were source/diff/receipt/image inspection and this external report only. No build, native test, simulator/native CLI, installed host, device, Git mutation or source edit was performed.

```json
{
  "verdict": "approve",
  "findings": [],
  "scope": "Source-only verification-harness correction and owned-cleanup runner delta",
  "sourceCommit": "97e71f2e18f7c43b4ba8a874f8db67c736ba72e9",
  "sourceBase": "a8b62d0f646d375f5150d956654e5e9b2227a256",
  "cleanupMainBase": "67adf8d7dfe9d80c6761ac6a4ba16edd18ceb18d",
  "cleanupFileSha256": "9df8f384b3a9c0b4656805aa595e31091f9580c6bca7ead8d96880a7ee1040bf",
  "checks": [
    {"name": "source-scoped diff", "status": "passed"},
    {"name": "read-inspection", "status": "passed"},
    {"name": "native-build", "status": "not_run", "actor": "reviewer"},
    {"name": "native-UI", "status": "not_run", "actor": "reviewer"},
    {"name": "synthetic-checks", "status": "not_run", "actor": "reviewer"}
  ],
  "selectedMethods": {"phone": 117, "ipad": 28},
  "previousNativeResult": {"result": "Failed", "executed": 113, "passed": 93, "failed": 20, "skipped": 0},
  "limitations": [
    "Source approval is not Swift compilation or fresh native acceptance.",
    "Default/XXXL phone/iPad popup and LAN runtime geometry/reachability remain unverified by this reviewer; unknown or ambiguous containers fail closed.",
    "Unsupported pointer Scroll remains failure; two-finger touch, physical usability, live Mac control and actual VoiceOver acceptance remain separate.",
    "Earlier findings, failed selections and owned-process finalization recovery remain authoritative historical evidence.",
    "Cleanup timeout does not address an Xcode process stalled before wrapper finally; owned manual recovery remains separately documented."
  ]
}
```
