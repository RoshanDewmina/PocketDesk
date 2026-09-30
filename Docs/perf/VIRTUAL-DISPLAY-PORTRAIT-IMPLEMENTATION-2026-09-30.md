# Portrait virtual-display prototype implementation

30 September 2026. **Independently reviewed; approved for implementation.** Product authority: PRODUCT D11. Roshan authorized writing, verifying and implementing this plan after the API research. This is a private feasibility prototype; supported shipping remains unresolved. Independent plan review approved the revised ABI, exclusive ownership, async-owner testing and motion-evidence requirements before coding.

## Goal and stop line

Build a manually initiated, Debug-only 60 Hz portrait virtual display, show only Farside's own synthetic code/text/motion window, and capture that window into a local preview. Establish creation, actual logical/backing geometry, capture identity, delivered cadence and teardown. Provide a repeatable smoke command and readable evidence. This increment does not wire private APIs into ordinary phone sessions. A physical phone comparison and user-app placement are later increments after this feasibility result.

The feature remains absent from Release and disabled in ordinary launches. Existing 120/144 Hz spike stays separate and unchanged. No real Mac input, pairing, network service, system clipboard, user-window migration, lock experiment, privacy-curtain activation, login item or watchdog configuration belongs to this prototype. Creating a display can still change macOS desktop topology; we inspect the before/after state and do not promise full window/Space restoration.

## Architecture and ownership

Worktree: `/Users/roshansilva/Developer/PocketDesk/.codex/worktrees/virtual-display-prototype`, branch `codex/virtual-display-prototype`, baseline `a567310`. Main contains unrelated edits and is preserved.

1. **Debug bootstrap:** new explicit portrait argument checked before normal host initialization, alongside the existing spike hook. Reject conflicting flags and invalid modes before startup. Detach normal app launch callbacks; never instantiate host model, network, pair store or login/recovery services in the experiment. A standalone controller owns its process and application loop.
2. **Pure policy:** a small Debug-only shared policy defines modes, geometry validation, run generation/state transitions and bounded metric accounting. XCTest can test it without WindowServer, private classes or screen-capture permission.
3. **Private adapter:** all SPI isolated in the portrait file. Discover classes/selectors and verify Objective-C method signatures before invocation, including alloc/init/apply, getters/setters, scalar widths and struct types. Use an explicit arm64 ABI allowlist and reject unknown signatures before allocation. Omit the optional termination callback: Objective-C `@?` does not disclose a block's argument ABI, so setter introspection cannot verify a safe callback cast. Detect disappearance through owned display inventory and capture failure. Do not copy unchecked unsafe casts or expose private symbols through Release. No downloaded implementation or new license dependency is needed.
4. **Lifecycle controller:** one main-actor owner serializes Start and Stop, holds the display strongly, tracks cancellation generation, and rejects late discovery/capture completions. Acquire a process-wide nonblocking advisory runtime lease before creation, on an owned private regular file with no symlink traversal, and retain it until all resources resolve or process exit. Reject a pre-existing experiment display identity, rather than capturing/releasing a display another process created. No overlapping or automatic restart. A failed/late start must release its own acquired resources. Failed teardown cannot be reported as clean or permit another Start while resources remain unresolved.
5. **Own synthetic window:** ordinary AppKit view with code text, line markers, resolution labels and optional motion. Window placed on the exact newly created NSScreen; normal physical modes, mirroring and main-display selection are untouched. The control/preview window remains on the existing physical screen. Neither owns nor moves other apps' windows.
6. **Public capture:** find the own synthetic SCWindow by exact window number, verify the virtual display identity and window placement, then use `SCContentFilter(desktopIndependentWindow:)` so unrelated apps are never sampled. Report that this is own-window capture, rather than proof of complete desktop capture. Explicit 1/60 minimumFrameInterval, native measured backing dimensions, no audio/cursor, bounded queue depth. Coalesce the preview to at most one pending frame to prevent main-queue growth.
7. **Evidence and runner:** interactive Start/Stop plus bounded automated smoke mode. JSON/text reports include environment/revision, requested and actual geometry/mode, capture identity, complete/idle/repeated timestamps, distinct cadence/gaps, first-frame timing, before/after display inventory and cleanup result. These are local capture observations, not phone glass latency, encoder or network performance. Never save pixels or unrelated window titles; metric records remain bounded.

## Modes and acceptance rules

- 1×: propose 430×932 logical points/backing pixels at 60 Hz.
- HiDPI: propose 430×932 logical points and 860×1864 backing pixels at 60 Hz. This is a hypothesis; verify selected CGDisplayMode dimensions, NSScreen backing scale and SCFilter/frame output. Do not silently accept a landscape or incorrectly scaled mode.
- Fixed private experiment identity per mode; no automatic physical display reconfiguration. If the intended mode isn't actually selected, report unsupported geometry and clean up rather than change physical displays.
- Check screen-recording preflight before creating resources. Missing consent produces a useful denied result without requesting/resetting/granting permissions automatically.
- Bound discovery, capture setup/first frame and normal removal to five seconds each. Async framework calls that outlive a timeout require generation-fenced eventual cleanup, not abandonment. Synchronous SPI calls cannot be forcibly cancelled; the runner has an outer timeout, and the report distinguishes process termination from normal verified teardown.
- Normal Stop: close admission, invalidate generation, stop display-link ticks, stop/drain capture, close own window, release display, verify disappearance, clear held references. Closing control window, capture error and signal termination take the same owned cleanup path. Display-disappearance and capture-error completions must be generation-scoped and must not accidentally stop a newer run; signals end the owned process through its cleanup path.
- Automated smoke records moving content for a bounded interval, then static content, and verifies first frame, expected output size, at least two distinct complete timestamps during motion and display removal. Record actual cadence; do not force a 60 fps success threshold before measuring. Wrong geometry/capture identity or cleanup failure is a failed result, not a skip.
- Crash/SIGKILL behavior, sleep/wake, lock, user switching, actual old Mac/OS26 compatibility and physical phone usability stay unverified. No crash test is required in this first increment.

## Packages and sequencing

Parent owns this plan, PRODUCT authorization record, generated Xcode project integration, build coordination and final assessment. Supported worker models include GPT6.1 Sol/high and smaller GPT routes; sensitive SPI/lifecycle implementation and fresh review use GPT6.1 Sol/high. Four slots total, no recursive agents. The parallel simulator package uses a separate branch and disjoint write-set; heavy builds are serialized, and simulator execution cannot overlap display-performance measurement.

| Package | Allowed writes | Dependency |
|---|---|---|
| Independent plan review | review note in chat workspace `work/` | this draft + prior API reports + existing spike/bootstrap |
| Portrait implementation and meaningful tests | new `RemoteHost/VirtualDisplayPortraitPrototype.swift`, `RemoteShared/VirtualDisplayPrototypePolicy.swift`, `RemoteTests/VirtualDisplayPrototypePolicyTests.swift`, portrait bootstrap lines in `RemoteHost/RemoteHostApp.swift`, `script/perf/virtual-display-portrait.sh`, package usage/evidence docs | root accepts plan review and corrections |
| Fresh code review | separate review note, no source edits | implementation diff + dependents + actual author checks |
| Parent integration/verification | `project.yml` only if needed, generated project, PRODUCT and existing implementation ledger, plan status | scoped checks + independent review |

## Verification

1. Plan reviewer checks scope, API evidence, ABI validation, privacy, ownership/cancellation/cleanup, testability, baseline targets and signing constraints. Resolve certain/likely major findings before coding.
2. Author checks shell syntax, invalid arguments/Release guard and pure state/geometry/statistics tests. Include an injected asynchronous resource-owner test seam, not only state enum checks: delayed successful capture start after Stop/timeout must stop that exact acquired stream, delayed stop completion cannot clear a newer run, and an unresolved stop retains resources/blocks a new Start. Important cases also include repeated Stop, display disappearance, unsupported signatures/modes, zero/missing/repeated timestamps, no permission, occupied runtime lease/pre-existing identity and failed cleanup. No termination callback is installed in this increment.
3. Parent generates project in isolated checkout and runs Debug host build, Release host build and scoped XCTest under `/usr/bin/lockf -k /tmp/farside-xcodebuild.lock`, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and DerivedData under `/Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsidePortraitPrototype`. Keep macOS26 deployment and arm64/signing identity. Release binary inspection must show no portrait argument/SPI strings or new prototype code; ordinary host behavior remains covered by existing checks.
4. Fresh independent code reviewer evaluates full diff and call-site map, including async timeout ownership, Objective-C signatures, preflight, capture selection, frame queue bounds, Release guards and cleanup. Resolve blockers and rerun affected checks.
5. Bounded real runtime smoke only after code review and resource coordination. Do not install from a worktree, quit an unrelated app, reset TCC or act on a prompt automatically. Launch isolated Debug experiment only when safe; if current permission or shared desktop/resource state prevents the smoke, preserve the built artifact and mark that gate incomplete. No simulator/benchmark load at the same time. A native prompt belongs to Roshan.
6. Only after the experiment proves geometry/capture/removal may we choose a next integration slice: selected virtual-display capture in an authenticated phone session with epoch-fenced input, existing privacy/recovery rules and separate physical acceptance. Never equate a compiled prototype with a shipped feature.

## Integration and records

Commit finished scoped work promptly. Land into main only after its concurrent owners are clear and parent checks can be rerun; preserve its existing modified/untracked documents. Push verified main checkpoint to its existing private origin per AGENTS. If integration is unsafe, keep a reviewed branch/build and record the exact remaining step. Do not publish or install. Copy plan, review and build/evidence summary into the current chat's `outputs/` for review.

## Sources

Prior research: `farside-virtual-display-api-research-2026-09-30.md` and independent review in `/Users/roshansilva/Documents/Codex/2026-09-30/ca/outputs/`. Original spike: `Docs/perf/VIRTUAL-DISPLAY-SPIKE.md` and `RemoteHost/VirtualDisplaySpike.swift`, dated observations only.

- Apple [window capture](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:)) and [capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos).
- Apple [minimum frame interval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval). Docs/header default discrepancy is resolved by explicit settings, not assumption.
- Apple [current macOS release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes). SDK27 presence does not establish OS26 runtime support.
- Apple [developer agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/): distribution/contract applicability remains unresolved; this local prototype does not resolve it.
