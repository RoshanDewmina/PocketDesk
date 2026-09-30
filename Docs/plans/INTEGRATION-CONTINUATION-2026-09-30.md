# Native integration continuation — 30 September 2026

Engineering continuation is authorized. Worktree: `.codex/worktrees/continue-integration`, branch `codex/continue-integration`. Parent owns independent review and final landing. No installation, physical measurement, deployment, provider mutation, App Store action, or publication is performed here. iPhone Duo and website/social work are excluded.

## Package revisions and integration

| Package | Exact author base | Exact author head | Integration/check status |
| --- | --- | --- | --- |
| Wave 1: connection health, efficiency, Smooth motion, polish, transfer | a567310ea6eef152a5202501a1f2a5f41a56e0e2 | b1417a08329423a707f1c402758d5a447915ec9c (integration-2026-09-30) | Starting integration revision; no recovered final passing run |
| Connection Health | 6d83703b80cd70a1cbbda0a1aace8cf5d244659c | 84d871ed3a5b40a0f8b9be9bd0b53f619a64869c | Prior merge 09cff85; included in fresh combined checks |
| Efficiency | 6d83703b80cd70a1cbbda0a1aace8cf5d244659c | 620f2851df19a17e0063139a09a9be0d6c2c81cc | Prior merge 546e293; included in fresh combined checks |
| Smooth motion | a65e864b424cee3a8df80b768a184a46d329a8ab | bca21f2fcd1693c792343c2ab84b5e4aef51fb7a | Prior merge b71cc3d; simulator fallback only; hardware interpolation unverified |
| Polish | a567310ea6eef152a5202501a1f2a5f41a56e0e2 | 431edbd8485def6788853777e14535033621c319 | Prior merge 3bf949d; new gesture/error cases retained |
| Transfer | a567310ea6eef152a5202501a1f2a5f41a56e0e2 | af731ce5711bac25a2acadd0f20316212b8b8e09 | Prior merge 3dbb188; App Group/share extension retained |
| Trust | a567310ea6eef152a5202501a1f2a5f41a56e0e2 | 9fb69beb0651f489ec21150d9299c6b205633dbe | Merge 3b83aba; cached post-event grant remains control truth |
| Commerce/review | a567310ea6eef152a5202501a1f2a5f41a56e0e2 | 5ec4136976b2d398a63fbcc5886d3f035f3dd5e0 | Merge f67deda; fixed generic title preserved in Watch merge |
| Focus & Precision | a567310ea6eef152a5202501a1f2a5f41a56e0e2 | f82a77b1bd4f9690472fef4e5e9739d2f572e2d9 | Merge 76382d1; secure-focus flag, geometry and momentum combined |
| Motion lab | a567310ea6eef152a5202501a1f2a5f41a56e0e2 | 6eba120f2b0bb5e66c29ea868699fcfc41196428 | Merge 9791286; adopted PRODUCT D38 A and D39 live strip retained |
| Watch glance | a65e864b424cee3a8df80b768a184a46d329a8ab | 889d5b7e01048d3f4bdfc7ea1d85af9be6f9e314 (watch/wave-1) | Merge 3f1fc31; actual implementation, not scaffold branch |
| Mac vitals | 84d871ed3a5b40a0f8b9be9bd0b53f619a64869c | 1edd76065c9a56f57f810440e5c776711b678ee9 (vitals/final-fix) | Merge 95b3985; actual implementation, not scaffold branch |
| Couch mode | a65e864b424cee3a8df80b768a184a46d329a8ab | 4769f8081f67fba79ce29eb39fd3d4f530bbdb27 | Merge 198881b; whole-branch author review was interrupted; parent review pending |

Big Text, Away, perf-pack, keyboard and connection-quality are owned elsewhere and not merged in this branch.

## Conflict decisions and integration repairs

- PRODUCT keeps every dated addition: D34 amendment and D38/D39/D40/D41, polish, transfer and trust. No stale PRODUCT copy replaces newer decisions.
- xcodegen regenerated after project/source-list conflicts; all author targets and shared test sources retained. Build remains 20260930.7.
- ConnectGate retains pending server-data removal and optional device-owner authentication. Mode preparation occurs within its gated start, with no Anywhere token wait for Couch. Siri/widget default to Picture through the same gate.
- Sealed acceptedAck combines optional phone name and mode. Both bounded decoders can consume the same body; display name never grants authority.
- Capture-blocker admission happened before Couch intent existed. An optional mode in the existing sealed handshake request now supplies intent before proof admission. Couch only bypasses the picture grant blocker; local proof, route, owner consent, cached post-event grant, unlocked/active console and fresh heartbeat still gate input. Picture capture retains explicit grant and system-approval checks.
- Couch uses the cached post-event grant for control, preserving Trust's no-per-input-AX contract. AX remains required for focused-field lookup and curtain.
- Restored the removed blocker.1 downgrade handshake regression with a retained host lifetime. Its discarded host binding was a concrete fixture lifetime defect; mapping-only coverage is insufficient. It passes in the fresh full core suite, together with sealed request/challenge/proof Couch-intent regressions.
- Session feature cap increases from 16 to 32, with positive integrated-feature and negative 33-feature checks. Older installed peers may reject the combined capability list: update both apps together and retain physical compatibility acceptance.
- Watch adds wrist handoff body and delayed local test while keeping Commerce's fixed generic alert title and no agent-name toggle.
- Couch disables Precision Tap/loupe and absolute pointer targeting while there is no picture. Its one-second held-input lease and heartbeat policy remain.

## Evidence and outstanding gates

Claude integrator history: exact agent a8b7326e7f7cf8034. Initial script produced no steps due zsh array parsing; corrected verification queued but its temporary script/results are absent. Do not describe beta-overlapping author checks as stable. Focus's final report states Xcode 27.0 passing, but fresh combined verification remains required. Motion's layout regression remained unresolved before its last queued rerun.

Current verification is pinned to `/Applications/Xcode.app/Contents/Developer`, observed Xcode 27.0 (27A266a), under `/usr/bin/lockf -k /tmp/farside-xcodebuild.lock`. Dedicated DerivedData: `/Volumes/Studio/Development/Caches/Xcode/DerivedData/codex-continue-integration`. Receipts: `/Users/roshansilva/Documents/Codex/2026-09-30/ca/work/farside-integration/`. Only the dedicated simulator created by this run is shut down. No provisioning update or signed device build is needed for these source/simulator checks.

Backend initially lacked local vitest/tsc dependencies; installed exact frozen Bun lockfile before checks. Backend checks pass 135/135 plus TypeScript. Fresh native receipts and the scoped recovery follow-up are recorded below. StoreKit class is explicitly excluded from the broad phone unit run because historical fixtures hang; this is a skipped acceptance gate, not purchase verification. Host UI snapshots pass 16/16; Watch policy/render fixtures are included in the native suites, without establishing wrist acceptance. Physical use, StoreKit sandbox, Watch/CarPlay, capture re-approval, successful remove, signing/distribution and live provider acceptance remain open.

## Fresh verification receipts

First combined run began from 198881b and completed on Xcode 27.0. Core built, then executed 988 tests with 7 skips and 1 failure: the old invalid case used 17 features after the cap became 32. Corrected to 33, added boundary-positive 32 and actual combined host capabilities. Restored blocker.1 sealed-handshake regression passed in that run. Mac host build passed after the conflict-assembly syntax correction. Phone generic-simulator compile failed on missing Couch error cases in Connection Health; corrected before the rerun. These failures remain in the receipt logs; no passing combined-suite claim is made yet. Heavy build slot released to Big Text after that chain; no second lock waiter was queued.

Further source audit: a Couch session admitted through the no-Screen-Recording listener now marks the host active and exits listener-only state, so its authenticated mode-switch/session-extension gates can work. No capture starts from this transition. Combined identity JSON drops an oversized display name while preserving requested mode, with a unicode regression. xcodegen's repeated output changed only copy-phase IDs/order; reverted that generator-only churn. Backend fresh checks pass 135/135 plus TypeScript.

First-wave author bases above are merge bases against a567310; imported heads are exact second parents of their prior integration merge, not potentially moving branch labels. Author-only generation/review scripts in vanished `/private/tmp/claude-*` scratch directories cannot be reconstructed as passing receipts. Original Claude worktrees and dirty motion PNGs were not edited.


## Frozen pre-fix verification — ca99d6e

`ca99d6e` changes only the ledger; its compiled source is `d050263`. Xcode 27.0 (27A266a), shared lock, dedicated DerivedData. Receipts are preserved in `work/farside-integration/rerun/` beneath the Codex task directory cited above.

| Check | Result |
| --- | --- |
| Core build + direct xctest | 990 executed, 7 optional skips, 0 failures (68 s) |
| Mac host Debug unsigned source build | Passed |
| Generic iOS Simulator app and extensions build | Passed |
| Phone unit suite, excluding AnywhereStoreKitTests | 464 executed, 1 optional screenshot skip, 0 failures |
| Targeted Phone UI | 9 executed; 8 pass (Couch and Vitals), 1 failure in Motion landscape Controls at SessionLayoutTests.swift:206 |
| Host UI snapshots | 16 executed, 0 failures |
| Backend | 135 tests, 0 failures; TypeScript passed |

The Motion assertion was retained: Double-click must exist and be disabled offline; Hold click and Mission Control must remain present/reachable. Its failure snapshot showed Settings and Done but a zero-sized lazy key grid after rotating the keyboard and dismissing it. The existing UI regression is the acceptance check for the rendering repair. Core optional skips are four HEVC probes, one opt-in stream-loopback benchmark and two VideoToolbox probes. No physical performance run was attempted.

## Fresh review finding and recovery

A fresh independent source review of `ca99d6e` found P2: granting Screen Recording during live Couch called `loadDisplays`, whose old `!active` guard suppressed the catalog refresh. A subsequent Picture request encountered an empty catalog and ended the session. No other actionable security finding was reported in that reviewed snapshot. Review evidence was source-only.

- `1bc850c`: allow catalog-only refresh during Couch, with no normal sharing reconciliation/capture start. An explicit Picture request has a unique four-second ticket, current weak peer and input epoch; another mode request, end, backgrounding or permission denial cancels it. Completion rechecks peer/session, lock/console, local proven route, owner control/cached post-event grant, fresh heartbeat, Screen Recording/system capture approval and a valid selected display. Failure stays in Couch and sends a bounded `displayUnavailable` retry notice. Added policy, wire/copy and phone-model regressions.
- `fd8df65`: render the eight fixed non-scrolling Controls keys with eager SwiftUI Grid rows. Preserve each action, disabled state and accessibility label/hint. Apple Grid documentation was checked on 30 September; the Grid API immediately renders its cells, unlike lazy grids. No platform/deployment requirement changed. Source: https://developer.apple.com/documentation/swiftui/grid
- `7b646fb`: if Screen Recording is revoked while a Picture ticket is pending, clear the ticket and send its Screen Recording refusal while leaving Couch active. Update the catalog-staleness comment to reflect the new refresh path.

Scoped recovery validation at `fd8df65`, receipts `work/farside-integration/focused/`: core builds and executes **993 tests / 7 optional skips / 0 failures**, Mac host builds, and **15 Couch phone-model tests / 0 failures**. The first UI attempt executed zero tests: XCTest runner aborted in accessibility bootstrapping (`XCTWaiter(StallHandling) handleStalledWait`, main thread in UIKit AX bundle/dyld loading). Preserve that xcresult and `ui-runner-stall.ips`; it is an infrastructure failure and no UI success is inferred from it.

At source `7b646fb8383b9d35722caf3570b21619f8ebaa2a`, host rebuild passes. A single UI retry uses the same owned iPhone 17/iOS 27.0 simulator after boot completion and the unchanged test bundle built at `fd8df65` (the intervening source change is host-only). Receipt directory: `work/farside-integration/focused-retry/`. UI retry executes **9 tests / 7 passes / 2 failures**: Couch surface and all six Vitals checks pass; Couch Home caption static-text assertion fails at CouchModeUITests.swift:29 despite the Couch button existing; Motion fails at SessionLayoutTests.swift:163 because the initial dock swipe did not reveal Hide controls. The latter occurs before the original landscape key assertion at line206, so the eager-grid repair is not yet accepted by a completed landscape regression. No assertion was changed. Preserve logs, xcresult, screen recordings and exported attachments. The owned simulator was shut down by the script trap; the heavy slot is released.

Parent owns scoped re-review and final integration. Direct delivery to the earlier reviewer failed with the runtime's "agent thread limit reached"; parent was notified. Real Screen Recording grant/re-approval during a Couch session, physical input/network behavior, Watch/CarPlay, purchase, removal, signing/distribution and provider acceptance remain open. Both apps should be updated together because older installed peers retain the 16-feature cap. This branch has not been landed to main.


## Discussion-first hold — latest user steering

After the already-running unchanged UI retry finished, the parent relayed the user’s request to discuss competition parity/performance before further action. No more implementation, integration or build retry is authorized until that discussion. Final compiled source is `7b646fb8383b9d35722caf3570b21619f8ebaa2a`; the following commit changes this status ledger only. Couch recovery is committed and policy/model checked, but awaits independent scoped re-review and physical grant/switch acceptance. Motion’s fixed eager grid compiles and passes Couch/Vitals key-panel checks, but its complete portrait→keyboard→landscape regression remains open. Do not treat this branch as a fully green combined UI checkpoint or land it automatically.
