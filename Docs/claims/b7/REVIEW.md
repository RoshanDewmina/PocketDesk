# Independent b7-claims review — 2 October 2026

Reviewer: fresh GPT agent, read-only source/document inspection. Baseline `20aded1554888a949943a837169a8e6de30144ea`; inspected working diff in `/Users/roshansilva/Developer/farside-b7-claims`. No build, test, simulator operation, installed-host/device action, permission change, source edit, or commit was performed by this reviewer. This report is the only reviewer write. Parent edits were visible during review; findings below distinguish original findings from observed repairs.

## Current verdict

**APPROVE source/code only / INCOMPLETE runtime — see scoped re-review below.** Original provenance and priority-lock P1 findings are repaired in source. The Duo boot receipt contains `Data Migration Failed` despite process exit 0; the parent corrected it to a failed infrastructure attempt and added a guard for that outcome. Fresh build/test/audit receipts remain pending; source review cannot approve accessibility, native touch, privacy snapshots, dictation, live Stop Sharing, or a >30-minute session.

## Findings

| ID | Severity / confidence | Evidence | Finding / required resolution |
|---|---|---|---|
| R1 | P1 / certain | Original `script/claims/run.py:45–49`; original `source_audit.py:17–18`; repaired runner `source_identity`, `artifact_identity`, `build`, `test` | Separate `phone`/`ipad` stages originally ran any DD binary with no match to current source, and provenance recorded only HEAD although this lane had uncommitted tests. Parent added a source/artifact manifest, but the first repair hashes source only **after** compilation and checks the manifest **before** waiting for the shared lock. An edit during build can bless uncompiled source; an edit during lock wait can run a no-longer-matching artifact. Snapshot source before build, require it unchanged after build, and revalidate under lock immediately before execution. Preserve that exact identity in each test log directory. |
| R2 | P1 / likely on standard Xcode Debug settings | Repaired `script/claims/run.py` `artifact_identity` limits hashes to `.xctestrun` and three executable names | Launcher-only hashing can omit `PocketDeskRemote.debug.dylib`, frameworks and bundle resources, so replacing compiled implementation may not change the recorded launcher hash. Hash complete app/test product contents or establish with effective settings that every excluded file is irrelevant. This is a provenance issue, not an assertion that current binaries were tampered with. |
| R3 | P1 / certain; repair observed | Original `script/claims/locked.py:5–7`; `RESUME-COMMON.md:12` | The original wrapper slept while owning the shared build lock when PRIORITY-BUILD appeared after queuing. The exempt priority lane then could not acquire the lock it needed to clear the gate. Parent repair returns 75, releases the persistent lock, and retries outside it; source inspection supports that repair. No live concurrency test was run by reviewer. |
| R4 | P2 / certain | Original `FarsideRedesignUITests.swift:491,493–494,508–510,528–530`; `NativeSessionView.swift:2064` | Settings subpages all accepted `remote.controls.page`; reconnect and sharing-stopped accepted the ordinary canvas. A silently ignored fixture argument could audit the wrong screen and still count the intended fixture. Require specific page titles or specific state text/markers. Parent is repairing this. |
| R5 | P2 / certain | Original `source_audit.py:8`; `HOST-AUDIT.md` C5 source evidence; `Backend/src/room.ts:1056–1149` | Session-cap scans omit the authoritative Backend, and the detailed lease discussion cites the legacy private Server. Include Backend renewal/route-expiry/config evidence, clearly separate the legacy loopback integration fixture from the shipping Worker, and keep live duration unverified. |
| R6 | P2 / certain limitation | `FarsideRedesignUITests.swift:535–538`; `NativeSessionView.swift:2104–2110`; `RemotePhone/LANWakeView.swift` | One upward swipe does not demonstrate every scroll extent at AX XXXL. The inventory also does not cover the nested LAN Wake page. Name the actual inventory and bounded scroll coverage; do not report a literal whole-app exhaustive accessibility audit. If full coverage is required, traverse each page and scroll to the end with bounded progress checks. |
| R7 | P2 / certain limitation | `script/claims/run.py` simulator argument overrides and unconditional shutdowns | The script trusts an explicitly supplied UUID as lane-owned and shuts it down even if it was already booted by another lane. Defaults are assigned lane simulators, and the README warns callers. Safe reproducibility requires preserving that ownership condition; reject or require explicit owned-simulator acknowledgment for arbitrary overrides, and record simulator/runtime identity. No actual ownership violation was observed. |

## What is sound

- No production source edits; only offline fixture tests and scripts are proposed. No script targets an actual iPhone or launches/installs the Mac host. Persistent `lockf -k` and pinned package flags match shared lane rules.
- Accessibility audits use `.all`; callbacks retain every issue and the final inventory assertion fails on findings or audit errors. Returning true is not used to turn findings into a green overall result. Screenshots and hierarchy attachments stay available.
- Coach lesson tests start each lesson behind its completion gate and do not tap Skip or force its model to pass. Move/click/drag/pinch geometry has no certain source-level defect found. Pointer scroll is explicitly labeled as a mouse-scroll substitute; two-finger touch remains HANDS.
- Dictation fixtures inject a local nonrecording transcript and leave insertion disabled. Keyboard reachability is distinguished from actual Mac delivery. Home-background/foreground concealment is distinguished from an actual physical app-switcher thumbnail.
- Matrix covers the atomic Block A/Block B clauses and C1–C13, names old binary identities, flags unsupported iPad/Duo layout, literal “nothing connects,” coach ordering, and stale C12/character math. It does not turn source scans or installation into device acceptance.
- Host audit correctly rejects a media-only 35-minute loopback as proof of C5 and preserves physical C4. It explains why the existing host E2E harness cannot be launched unchanged under this lane's permission and gate constraints.
- Hands checklist gives concrete acceptance criteria and honestly separates a ~20-minute active sitting from the ≥35-minute continuous-session tail and external/store gates.

## Incomplete evidence / next review scope

Inspect the repaired runner and fixture markers; then inspect actual source/artifact manifests, effective Debug/Release host settings, selected core results and phone/iPad `.xcresult` receipts. Report individual failing accessibility issues rather than suppressing classes. A Duo boot failure is infrastructure evidence and does not certify fold layout. Commit/integration and uploaded Release identity must be attached separately before public claim use. All physical/provider/store gates remain open unless their exact receipts are supplied.

## Scoped re-review — repairs and copy verdict

Inspected `identity.py`, repaired runner/wrapper/source audit, expanded UI inventory, `HOST-AUDIT.md`, `CLAIMS-VERDICT.md`, both draft Block A files, `COPY-BUDGET.json`, `RUNNER-GUARD-CHECKS.log`, and the single Duo attempt raw logs. No build, product test or simulator operation was run by reviewer.

- **R1 resolved in source:** source snapshots before/after phone and core compilation reject changed inputs; manifest validation runs after taking the shared lock and again after tests. Dirty source/resources are hashed, not inferred from HEAD. Archive a copy of the matching manifest with each test's log directory to retain provenance after a later DD rebuild (remaining P2 evidence-durability improvement).
- **R2 resolved in source:** complete `.app` / `.xctest` contents and `.xctestrun` files are hashed, including debug dylibs/resources. `RUNNER-GUARD-CHECKS.log` reports a changed synthetic debug dylib and changed synthetic source rejected; this is limited script-guard evidence, not feature proof. Reviewer inspected that receipt, did not execute those checks.
- **R3 resolved in source:** gate discovery under lock returns 75, and the parent retry waits only after the persistent lock is released. Low disk is checked again under lock. Simulator test shutdown remains under the lock.
- **R4 resolved in source:** settings verify individual navigation titles; reconnect and sharing-stopped use their actual state IDs; Troubleshoot uses its actual Close control. These intended queries still await runtime checks.
- **R5 resolved:** source scanning includes Backend, and host audit accurately distinguishes shipped Worker ownership/route/entitlement renewal from the legacy Bun fixture service. Neither is promoted into deployed-config or ≥35-minute live-session proof.
- **R6 partly resolved / scope explicit:** named inventory now includes LAN Wake through real navigation in landscape, with no packet action. Controls are inventoried separately for VoiceOver review. Excluded live/provider/hardware/VoiceOver flows are explicit. One post-scroll snapshot remains bounded coverage, not every scroll extent or every app screen; C8 remains withheld.
- **R7 remains a caller constraint:** only assigned lane-owned UUIDs may be used; overrides do not establish ownership. No violation observed. It does not block source approval within that condition.
- **Copy verdict sound:** `BLOCK-A-GATED.txt` is exactly 677 characters and the conservative file exactly 515 (independent read-only count). 191 characters of revised later additions would make 868; every addition is conditional on its own gate. The standalone drafts are reviewable copy, not approved submissions. Founder facts, old-build passes, source policy and future launch intent stay distinct. No fresh simulator/compiler/accessibility pass is claimed.

### R8 — new certain P1: false Duo boot success

`logs/20261002T104318Z/results.json` records exit 0 for boot/bootstatus/shutdown. However `duo-boot-status.log` ends:

```text
[2026-10-02 10:43:55 +0000] Status=3, isTerminal=YES, Elapsed=00:36.
    Data Migration Failed
```

Therefore this is a **single failed infrastructure attempt**, not a booted compatible-runtime receipt. `NOTES.md` initially said “single attempt no migration failure in this lane,” directly contradicting the raw log. Preserve the raw exit-0 receipt, correct the interpretation explicitly, and make the runner reject a failed migration even when `simctl bootstatus` exits 0. Do not retry the device under this lane's one-attempt rule. Duo fold/app acceptance remains untested regardless.

**R8 resolved in source and interpretation:** `duo()` now rejects `Data Migration Failed` even with process exit 0 and requires device state `Booted`, retaining the raw command receipt and separately recording semantic boot acceptance. `NOTES.md` explicitly corrects the prior interpretation to FAILED with no retry. Reviewer did not rerun Duo; the raw 36-second attempt remains the evidence.

**Scoped final decision: APPROVE source/code only / INCOMPLETE runtime.** No P0/P1 remains open in the reviewed changes. Phone test logs now archive the matching build manifest; preserve the equivalent core manifest with core receipts as a minor remaining durability improvement. Actual compiler and phone/iPad/core result receipts are pending and must be reviewed without inflating their scope. The failed Duo attempt is not runtime/layout acceptance. Physical and external gates remain open.
