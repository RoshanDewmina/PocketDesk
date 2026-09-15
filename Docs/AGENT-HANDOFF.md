# PocketDesk — implementing-agent handoff

Prepared 13 September 2026. This is an execution entry point for the reviewed plan, not a second specification. Preparing or reading this handoff does not itself start implementation. The current task remains planning-only; a subsequent user instruction to implement supplies that authorization.

## Assignment to give the implementing agent

> Implement the reviewed PocketDesk browser feasibility milestone in the existing working repository. Use the swarm-orchestrator skill and as much useful native GPT parallelism as the available slots allow, with no Astra workers. Preserve the original product and native clients. First deliver a readable, protected live view of the user's Mac with practical phone controls and verified interruption/reconnection behavior. Prove one useful physical-phone task, cellular access and a separately forced relay path when the required device/provider access is available. Stop at that first feasibility checkpoint and report its evidence; do not silently build the entire later backlog. Keep the chat-launch, embedded-viewing/control, optional agent inspection and supported-runtime handoff features recorded for subsequent stages. Continue independent work when a device or account step is unavailable, without treating a local test as live acceptance. Cloudflare account/public-exposure work remains deferred until the user resumes it.

## Start here

Work in `/Users/roshansilva/Documents/ChatGPT/Saas/PocketDesk`. Important source and documents are modified or untracked. Do not start from a clean default-branch checkout unless you deliberately carry over and verify the current working state. Never reset or discard unrelated work.

Read, in order:

1. [AGENTS.md](../AGENTS.md), including the canonical local workflow instructions.
2. [PRODUCT.md](../PRODUCT.md): the current product authority. Section 4 has all features and the original-conversation mapping; section 8 contains proposed browser admission; section 9B2 owns gate ordering and acceptance.
3. [IMPLEMENTATION-PLAN.md](IMPLEMENTATION-PLAN.md): the sole execution ledger, source map, existing receipts, package ownership and outstanding work. Maintain state here rather than creating another orchestrator-state file.
4. [APPLE-API-REFERENCE.md](APPLE-API-REFERENCE.md): refresh relevant platform/dependency facts before new platform decisions.
5. [Swarm orchestrator](/Users/roshansilva/.agents/skills/swarm-orchestrator/SKILL.md) and its [verification pipeline](/Users/roshansilva/.agents/skills/swarm-orchestrator/references/verification-pipeline.md).
6. [Review reconciliation](CLAUDE-REVIEW-RECONCILIATION-2026-09-13.md). Use the reconciled plan, not the original critique's withdrawn claims or the frozen review packet.

The [product summary](IDEA-VALIDATION-2026-09-13.md) and [competitor features](COMPETITOR-FEATURES-2026-09-13.md) provide context without changing scope.

## Product experience to preserve

PocketDesk remains the owner's existing Mac workspace on a phone, for coding, ordinary apps and university/work tasks. The native app is retained. The new browser is another way into that workspace and later becomes the destination of a button in the user's existing AI chat.

Proposed journey: **Mac setup/readiness → phone browser or chat entry → Connect → live desktop → keyboard/trackpad controls → return to chat or End session.** Keep content large, controls collapsible, portrait/landscape usable, and viewing distinct from permission to control.

Do not lose the newer ideas: continuous human video; direct phone interaction; entering information directly into the remote UI; chat-launched access; optional in-chat viewing and full control; optional selected-screen inspection for the agent; explicit takeover/return for a supported runtime. Secure-field behavior remains a separately tested feature, not deleted or universally promised. A generic GUI chat is not automatically a controllable agent runtime. Rough Paper/Figma concepts remain references, not a mandate for more static design rounds.

## Starting evidence

Browser/MCP features are unbuilt. Native capture, WebRTC media, input, service and tests already exist. Archived receipts record 33 native tests, 33 service tests and successful builds, but also failed Mac permission probes. These are historical results, not fresh baseline checks. No physical Mac-to-phone/cellular/TURN success follows from them.

Recheck current runtime permissions and devices. Begin permission recovery at the earliest authorized opportunity using supported OS flows; do not promise a fixed completion time. The early host may remain awake/unlocked with its physical display visible. Locked, sleeping, hidden/headless and persistent-entitlement behavior are not prerequisites or proven capabilities.

## Parallel execution waves

At preparation time this runtime supports the root plus **three concurrent workers**. Available relevant models are `gpt-5.6-luna`, `gpt-5.6-terra`, `gpt-5.6-sol`, and `gpt-5.5`; verify the live catalog before dispatch. Use Terra/medium for bounded UI work and Sol/high for authentication, shared state and sensitive review. Luna/medium is suitable for mechanical documentation/fixtures with a clear contract. Do not use Astra workers or reviewers. Reuse workers for related corrections; use fresh reviewers for independent review. Do not recursively spawn beyond the slot limit.

The following paths are proposed additions, not claims that browser code already exists. Before dispatch, the root expands each pattern into exact filenames in the existing ledger, including tests. Root alone owns shared `RemoteShared/**` interfaces, coordinator/media wiring, `Docs/REMOTE-PROTOCOL.md`, product/ledger documents, project generation, package configuration and lockfiles.

| Package / wave | Worker A | Worker B | Worker C | Root responsibility / exit |
|---|---|---|---|---|
| S0 · Phone experiment | `BrowserFixtures/**`: advancing code-text video | `BrowserProbe/**`: readability, local keyboard form, inert-link probe | Read-only fixture/readiness review | Operate physical Safari; record readability and layout evidence; no real capture or OS input |
| G0a · Contract | Bounded proposal or fixture support only | Bounded proposal or fixture support only | Fresh read-only contract review | Serialize canonical schema, mutual identity, geometry/freshness and cross-language vectors before dependent implementation |
| G0b · Admission | `Server/src/browser/**` and assigned browser admission test files | New `RemoteHost/BrowserPeer*.swift` and assigned `RemoteTests/BrowserPeer*Tests.swift` | Read-only crypto/admission review | Integrate shared calls; prove expiry, replay/race rejection, Stop, wrong key/origin/mode, and native/browser revoke isolation |
| G1 · Live viewer | `BrowserClient/src/viewer/**` and assigned viewer tests | New `RemoteHost/BrowserMediaSession*.swift` and assigned media tests | Read-only completed viewer/security review | Own shared media wiring and physical Safari real-capture gate; prove view-only denial and end/reload cleanup |
| G2 · Controls | `BrowserClient/src/control/**` and assigned control tests | New `RemoteHost/BrowserInputGate*.swift` and assigned input tests | Independent adversarial input/lifecycle verification | Serialize shared semantics; verify reflected input, IME, stale/delayed-frame lockout and interrupted-drag cleanup |
| G3 · Private task | `scripts/browser-acceptance/**` or author corrections in a later correction wave | `scripts/browser-metrics/**` or author corrections in a later correction wave | Fresh read-only acceptance review | Run physical Safari task, then Chrome separately; own evidence and verdict |
| G4 · Away access, only after provider work resumes | Exact assigned provider/service files under `Server/` | Assigned host route diagnostics and their tests | `BrowserClient/src/diagnostics/**`, followed by a fresh review wave | Own account/credential operations and integrated cellular/forced-TURN evidence; Tailscale does not pass this gate |

Keep all three slots active when independent work is available. A reviewer starts substantive review only after the relevant artifact stabilizes; reviews are never represented as completed merely because the reviewer was dispatched. Every substantive wave receives author checks, fresh independent review, bounded correction/re-review and parent integration. Reassign the third slot to an independent reviewer after a wave where all three workers authored code.

Each author owns its tests. Stop parallel writes if a change touches another package's files; the root reassigns the dependency. One actor at a time operates the physical Mac/phone or changes global simulator/service state. Workers return evidence; the root alone records gate verdicts in the ledger.

For each dispatch, record package ID, goal, absolute workspace, exact allowed files and exclusions, dependencies, model/effort, risk, acceptance commands, sensitive invariants, expected evidence and stop/escalation trigger. Resolve shared interfaces before dependent implementation. Slot capacity is a limit, not a reason to create overlapping work.

## Build order and stop line

1. **S0:** realistic non-sensitive code-text video on the actual phone, local-only keyboard-layout form, and inert chat-link opening. This can precede real desktop authorization because it contains no private desktop or OS input. It is not permission to remove authentication from a real session.
2. **G0:** settle and verify browser admission and wire contracts. Separate browser trust from native pairing; confirm one-use tickets, scope, expiry, revocation, identity/media binding, geometry revisions and displayed-frame freshness. Review before real access.
3. **G1–G2:** real authorized live viewer and practical controls, with physical Safari used from the earliest slices. Test readability, zoom, typing/IME, shortcuts, pointer/drag, view-only rejection, stale/delayed video and interruption. Test harmless secure fields separately after ordinary input works.
4. **G3:** one complete private physical-phone task, followed by Chrome as a distinct surface. Record an actual reflected change, readability, recovery and any Mac intervention. Tailscale may assist this private proof but is not a product installation requirement.
5. **G4:** once provider work is resumed, demonstrate cellular and separately forced TURN access, truthful route reporting, cleanup and revocation. Stop the initial delivery with **works for the tested task**, **needs a specific change**, or **not yet validated**, backed by receipts. If live access is unavailable, finish authorized independent work and name the exact missing test; do not silently substitute a simulation.

The later roadmap is preserved: **G5a** chat tools opening/managing the proven viewer; **G5b** embedded view-only with Open to control; **G5c** embedded full phone control; **G5d** optional agent inspection and supported-runtime takeover/return. A simple link opening is not proof of MCP integration. Embedded viewing is not proof of embedded keyboard/control. An agent interrupt response is not proof that all its work has stopped. Proceed beyond the initial checkpoint only within the user's assigned scope.

## Verification and delivery

Use author checks → fresh independent review → bounded correction/re-review → integrated verification from the skill. Certain/likely major or blocking findings require resolution. Root reads the evidence rather than voting on agent opinions. Do not restart unchanged expensive tests without a reason.

Preserve native pairing/reconnect, host-enforced view-only mode, input cleanup, and existing clients. Keep native and browser credentials separate. Replayed, expired, revoked or wrongly scoped access must fail. A running page, open channel, passing build or advancing heartbeat alone does not prove a current controllable desktop.

Existing verification entry points were inspected while preparing this handoff; they were not rerun for this documentation-only task:

| Command from repository root | What it establishes / side effects |
|---|---|
| `./scripts/preflight-remote.sh` | Read-only dependency/readiness inventory; does not establish actual permissions, media or relay behavior |
| `./scripts/verify-remote.sh` | Generates the Xcode project, runs service/native tests and builds host/phone; serialize with other build/project operations |
| `POCKETDESK_UI_SIMULATOR=<verified-simulator-id> ./scripts/verify-remote.sh` | Adds phone UI tests; select a currently available simulator, not a stale ID |
| `./script/build_and_run.sh --build` | Host build only |
| `./script/build_and_run.sh --verify` | Builds, installs and relaunches the host; use deliberately when installed-runtime verification is needed |
| `bun test` from `Server/` | Scoped service suite |

Add actual browser package commands when that package exists. Do not invent passing browser tests. Preserve dated baseline receipts and report new results separately. Provider signaling readiness is distinct from real relayed media; a missing phone, runtime grant or provider leaves its corresponding gate unvalidated.

Deliver: changed-file summary, runnable artifact and instructions, scoped test results, real-device/route receipts, outstanding limitations, the feasibility verdict, and the next smallest step. Update PRODUCT status and the implementation ledger. Do not claim the entire product complete, publish a service, buy accounts, merge remotely, or implement the deferred backlog merely because local checks pass.
