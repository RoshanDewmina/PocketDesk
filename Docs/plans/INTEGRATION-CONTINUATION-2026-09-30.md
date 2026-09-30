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
- Restored the removed blocker.1 downgrade handshake regression with a retained host lifetime. Its discarded host binding was a concrete fixture lifetime defect; mapping-only coverage is insufficient. Fresh full check pending.
- Session feature cap increases from 16 to 32, with positive integrated-feature and negative 33-feature checks. Older installed peers may reject the combined capability list: update both apps together and retain physical compatibility acceptance.
- Watch adds wrist handoff body and delayed local test while keeping Commerce's fixed generic alert title and no agent-name toggle.
- Couch disables Precision Tap/loupe and absolute pointer targeting while there is no picture. Its one-second held-input lease and heartbeat policy remain.

## Evidence and outstanding gates

Claude integrator history: exact agent a8b7326e7f7cf8034. Initial script produced no steps due zsh array parsing; corrected verification queued but its temporary script/results are absent. Do not describe beta-overlapping author checks as stable. Focus's final report states Xcode 27.0 passing, but fresh combined verification remains required. Motion's layout regression remained unresolved before its last queued rerun.

Current verification is pinned to `/Applications/Xcode.app/Contents/Developer`, observed Xcode 27.0 (27A266a), under `/usr/bin/lockf -k /tmp/farside-xcodebuild.lock`. Dedicated DerivedData: `/Volumes/Studio/Development/Caches/Xcode/DerivedData/codex-continue-integration`. Receipts: `/Users/roshansilva/Documents/Codex/2026-09-30/ca/work/farside-integration/`. Only the dedicated simulator created by this run is shut down. No provisioning update or signed device build is needed for these source/simulator checks.

Backend initially lacked local vitest/tsc dependencies; installed exact frozen Bun lockfile before checks. Native core/host/simulator builds and phone units/targeted layout-Couch-vitals UI checks are in progress. StoreKit class is explicitly excluded from the broad phone unit run because historical fixtures hang; this is a skipped acceptance gate, not purchase verification. Host UI snapshots and meaningful Watch render/layout checks remain in the integrated suites. Physical use, StoreKit sandbox, Watch/CarPlay, capture re-approval, successful remove, signing/distribution and live provider acceptance remain open.

## Fresh verification receipts

First combined run began from 198881b and completed on Xcode 27.0. Core built, then executed 988 tests with 7 skips and 1 failure: the old invalid case used 17 features after the cap became 32. Corrected to 33, added boundary-positive 32 and actual combined host capabilities. Restored blocker.1 sealed-handshake regression passed in that run. Mac host build passed after the conflict-assembly syntax correction. Phone generic-simulator compile failed on missing Couch error cases in Connection Health; corrected before the rerun. These failures remain in the receipt logs; no passing combined-suite claim is made yet. Heavy build slot released to Big Text after that chain; no second lock waiter was queued.

Further source audit: a Couch session admitted through the no-Screen-Recording listener now marks the host active and exits listener-only state, so its authenticated mode-switch/session-extension gates can work. No capture starts from this transition. Combined identity JSON drops an oversized display name while preserving requested mode, with a unicode regression. xcodegen's repeated output changed only copy-phase IDs/order; reverted that generator-only churn. Backend fresh checks pass 135/135 plus TypeScript.

First-wave author bases above are merge bases against a567310; imported heads are exact second parents of their prior integration merge, not potentially moving branch labels. Author-only generation/review scripts in vanished `/private/tmp/claude-*` scratch directories cannot be reconstructed as passing receipts. Original Claude worktrees and dirty motion PNGs were not edited.
