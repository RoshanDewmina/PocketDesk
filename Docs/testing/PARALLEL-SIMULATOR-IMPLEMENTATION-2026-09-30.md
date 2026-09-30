# Parallel simulator stub lanes — implementation contract

Date: 30 September 2026. Status: independently reviewed plan implemented; final code review/runtime gates pending.
Source baseline: `a567310`, isolated branch `codex/parallel-simulator-lanes`.
Risk: sensitive (filesystem identity, simulator/process ownership and concurrent execution).

This first package proves two native clients can pair, receive generated frames and deliver
isolated virtual input during a measured overlapping XCTest interval. It does not establish
Mac capture/input, physical phone behavior, older-chip performance or release acceptance.
The existing serial real-host runner and its fixed root/lock retain their current behavior.

## Ownership and command interface

The parent owns the dedicated Simurgh daemon, exactly two acquired leases, heavy builds,
product snapshots, foreign-load coordination and final lease/daemon release. This runner
does not acquire devices, boot/shutdown them, start/stop a daemon, build, install a Mac app,
reset permissions or use the installed host. Its no-build design makes the lock split explicit.
The parent must not run these lanes during virtual-display performance measurements.

Proposed CLI (absolute paths required):

```text
python3 script/e2e/parallel-stub.py prepare
  --run-id RUN
  --simurgh PINNED_BINARY --simurgh-sha256 HASH --simurgh-home PRIVATE_HOME
  --daemon-pid PID --daemon-identity NORMALIZED_PS_LSTART_AND_COMMAND
  --lane-a-lease-json A.json --lane-b-lease-json B.json
  --lane-a-xctestrun A.xctestrun --lane-b-xctestrun B.xctestrun
  --stub-app BUILT_DEBUG_STUB.app --artifact-dir NEW_PRIVATE_DIRECTORY
  --build-receipt OWNER_ONLY_PARENT_BUILD_RECEIPT.json
  [--runtime-library-root EXACT_EXISTING_CORE_SIMULATOR_RUNTIME_ROOT]
python3 script/e2e/parallel-stub.py validate --manifest RUN_MANIFEST
python3 script/e2e/parallel-stub.py run --manifest RUN_MANIFEST
python3 script/e2e/parallel-stub.py cleanup --manifest RUN_MANIFEST
```

`prepare` consumes parent-recorded acquire/env JSON and already isolated complete product
closures; validates ownership, path separation, UDIDs, lease identity, product references,
binary hashes and current TTL; creates fresh private roots/config/tokens/manifests only.
No existing root is chmodded, pruned or reused. `validate` is side-effect free.
`run` starts two owned loopback signaling services and stub executables, then concurrently
launches only the exact allowed `xcodebuild test-without-building` selector directly with
explicit validated lease destination/DerivedData/SwiftPM/cache/result paths. It holds
per-lane execution locks, never the global heavy-build lock. No `simurgh` CLI client is
executed: its IPC client autostarts a daemon after socket disappearance, including in
`exec`, so a prior successful daemon-status check cannot guarantee no autostart.
`cleanup` stops only verified process identities recorded in this run. It does not release
leases or delete common roots. Reports are retained; parent handles final disposal/release.
Any CLI adjustment must be documented and reviewed before runtime execution.

Simurgh metadata/lease cache home and artifacts may use a private SSD directory with owned
0700 root, real directory ancestry and no group/other-writable or symlink ancestors. This
does not move CoreSimulator's device data: the parent provisioner retains the default
internal device set. Run roots remain strictly under `/private/tmp/farside-e2e/parallel`.
The parent build receipt is a regular owned 0600 JSON file containing `sourceRevision`,
`stubClosureSHA256`, ordered `laneClosureSHA256` (phone then tablet), `buildsPassed: true`
and `xcodeVersion`. These must match the exact source checkpoint and already copied product
closures; prepare never manufactures a receipt or treats a build from different sources
as matching. The runner validates bundle IDs, DEBUG hooks, arm64 Mach-O simulator/Mac
platform and codesign, and hashes complete closures including debug dylibs. Runtime roots
are exact existing `/Library/Developer/CoreSimulator/Volumes/...` roots supplied/pinned
by the parent; `/usr/lib` is the additional system library exception, never a product root.

## Manifest and launch policy

Shared standalone `RemoteShared/E2ELaneContract.swift` is compiled into the apps, core tests
and UI test runner. `FARSIDE_E2E_LANE_MANIFEST` names exactly
`/private/tmp/farside-e2e/parallel/<runID>/<laneID>/lane.json`. Run/lane identifiers accept
1–64 ASCII letters/digits/hyphen/underscore only. Each lane manifest contains schema version
1, `mode: stub`, run/lane IDs, exact root, owner UID, lease ID, simulator UDID, distinct
session ID, loopback URL, creation time and expiry. The manifest and configuration files
are regular owner-only 0600 files; the directory chain from the fixed E2E root downward
must be owned by the current user and exactly 0700. Check each component with `lstat`, reject
symlinks/canonical aliases/traversal, and open manifests with `O_NOFOLLOW` plus `fstat`.
The trusted `/private/tmp` ancestry is checked as real directories rather than incorrectly
requiring private mode on the system temp directory. Bounded file size and TTL fail closed.

`E2ELaunchOptions.validatedCommon()` keeps its fixed serial-root policy by default. An
explicit role argument enables the lane policy only for `.stubHost` or `.simulatorPhone`.
A manifest supplied to the default real-host role is always refused. Lane mode requires
matching manifest/config/env run/root/signal identity. Simulator phone and test-runner
launches must be built for simulator and report `SIMULATOR_UDID` matching the manifest.
Physical phones cannot enable this policy. Missing, malformed, expired or mismatched
manifests are errors; they never revert to serial paths.

Forward the host runner environment through Xcode's existing `TEST_RUNNER_` prefix:
`TEST_RUNNER_FARSIDE_E2E=1`, `TEST_RUNNER_FARSIDE_E2E_DIR`,
`TEST_RUNNER_FARSIDE_E2E_RUN_ID`, `TEST_RUNNER_FARSIDE_E2E_SIGNAL_URL`,
`TEST_RUNNER_FARSIDE_E2E_LANE_MANIFEST` and `TEST_RUNNER_FARSIDE_E2E_CONFIG`.
The UI test runner validates the resulting unprefixed `FARSIDE_*` values, then explicitly
copies only that validated lane contract into `XCUIApplication.launchEnvironment` with
`--farside-e2e`. It never relies on the phone app inheriting UI runner environment.
`SIMULATOR_UDID` must come from the simulator OS inside both the UI runner and app; the
orchestrator and XCUIApplication launchEnvironment must never set it. If OS-provided
identity is unavailable or differs from the lane manifest, refuse and mark the runtime
gate incomplete rather than trusting an injected identity. Unit fixtures can pass a
synthetic environment to the pure validator; runtime code always reads ProcessInfo.

Manifest environment-key presence (including an empty value) itself counts as an E2E lane
request. `requested` therefore returns true for this presence even if launch argument/flag
are missing, while validation still requires both argument and `FARSIDE_E2E=1`. This makes
the real-host/phone bootstrap refuse before ordinary pairing trust is selected. A manifest
must never be ignored by an early ordinary-launch return. Test missing argument, missing
flag and empty manifest cases, both with and without a valid lane file.

Phone bootstrap refuses lane errors before accessing/resetting E2E trust. Its existing
serial accessibility-only fallback is retained. Stub refusal emits stderr and, only if
fully validated, the lane refusal file; a bad lane request never writes the serial root.
Native pairing remains per-lane stub file trust plus the separate simulator's E2E Keychain.
No trust/token/simulator data is copied across lanes.

## Source call map and write set

| File | Change / dependent path |
|---|---|
| `RemoteShared/E2ELaneContract.swift` (new) | Small standalone decoder/validator, independent of PairInvitation/UI; reused by launch and UI test paths. |
| `RemoteShared/E2ESupport.swift` | `validatedCommon` role dispatch; existing default callers (`HostE2E`, `WatchdogE2E`, browser fixture) remain serial-only. |
| `RemoteHost/HostE2E.swift` | Narrow refusal-output guard: a rejected manifest-bearing real-host launch emits stderr without writing the serial-root refusal file or starting normal host trust. |
| `RemotePhone/PhoneE2E.swift` | Explicit simulator-only lane validation before PairStore mutation; no lane fallback. |
| `E2EStubHost/E2EStubHostApp.swift` | Stub role; root-local geometry; fixed synthetic 1280×720 lane display and no frontmost-app queries; existing serial self-test retained. |
| `RemoteE2ETests/E2EHarness.swift` | Validated manifest-based root; config binds root/run/UDID/mode; other computed paths follow root. |
| `RemoteE2ETests/E2ETestCase.swift` | Propagate lane manifest to XCUIApplication; lazy host/pad clients initialize after config validation, not with serial paths before setUp; refused setUp has safe guarded teardown. |
| `RemoteE2ETests/ParallelStubE2ETests.swift` (new) | One minimal native pairing/frame/virtual input smoke with parent barrier. |
| `RemoteTests/E2ELaneContractTests.swift` (new) | Fail-closed policy and pairing separation fixtures. |
| `script/e2e/parallel-stub.py`, `script/e2e/test_parallel_stub.py` (new) | Lifecycle runner and fake-process/unit safety checks. |
| Parent-owned `project.yml`, `PocketDesktop.xcodeproj/project.pbxproj` | Parent adds the standalone contract to UI test runner membership and generates new sources; this package does not edit either file. |
| This document and `script/e2e/README.md` | Actual CLI, evidence, ownership limits and run instructions. |

Do not edit PRODUCT, the main implementation plan, project generation/membership, dirty main
checkout or dirty Simurgh source. Review must include an `rg` call-site map for changed
public/shared symbols. Typed-text and clipboard assertions are deferred from the first smoke.

## Barrier and negative controls

Each lane pairs with its own invitation/token, observes host approval without manual
approval, verifies consumed token, control readiness and fresh decoded/generated frames.
It sends `parallel.ready` through its own request directory. Only after both are ready does
the runner snapshot both hosts' accepted virtual click/key counters and grant lane A its
turn. A clicks its canvas and sends a lane-specific admitted key, asserts local accepted
input, and requests `parallel.actionDone`. The runner verifies A's counters advanced and
B's click/key counters stayed unchanged, then grants B its turn. Repeat the comparison
in reverse; only a successful pair of controls completes both responses. Heartbeats and
release/quality traffic are excluded from the idle counters rather than asserting all
network activity stops. A shared-file token fixture separately proves A's proof cannot
consume B's token. Neither test reads another lane's secrets.

Actual XCTest start/end receipts must yield positive overlap; process launch overlap alone
does not pass. Both lane results must contain successful assertions and separate preserved
`.xcresult` bundles. Reports bind source revision, product/binary hashes, Xcode/runtime,
run/lane/lease/UDID/session/port/root/process identities, intervals, negative controls and
cleanup checks. Missing/skipped checks are incomplete. Gesture-helper unavailable is an
explicit skip; this first smoke needs no private multi-touch helper.

## Runtime and cleanup

Use a parent-pinned immutable copy of the repository Simurgh `dced58f` binary and record
SHA-256 plus Go build metadata, explicitly noting dirty-build provenance. Never use PATH
fallback or claim reproducible clean-source build. Parent may choose a separate reproducible
build instead; runner accepts the exact explicit path/hash only. One build-for-testing
under `/tmp/farside-xcodebuild.lock` may supply copied complete product closures if every
`.xctestrun` reference validates inside its own lane; otherwise parent performs a second
serialized build. No shared writable DerivedData or package/cache/result paths.

Validate both `.xctestrun` formats: v1's top-level `RemoteE2ETests` target dictionary and v2's
`TestConfigurations[].TestTargets[]`. Resolve `__TESTROOT__` against the lane's copied test
product root and `__TESTHOST__` recursively against the already-resolved target's host path
(including nested `PlugIns` paths and mixed placeholders). Every referenced application,
test bundle and dependent product must resolve into that lane's product closure. Environment
library/framework paths may additionally use explicitly pinned active Xcode SDK/runtime
roots; do not reject trusted system runtime references or permit arbitrary external paths.
No unresolved placeholders, absent products, sibling-lane products or shared writable
references. Cover v1/v2, host-relative PlugIns, mixed placeholder and external-product
rejection fixtures. Parent supplies the copied complete product closure; the runner does
not build or broadly rewrite source products to make a bad manifest pass.

Maintain stable distinct `SIMURGH_SESSION_ID` per lane. A bounded direct Unix-socket
protocol-v1 adapter uses only `lease.get` and `lease.renew` (newline JSON, exact request
ID/version/ok checks, bounded 1 MiB response and short socket deadlines). It never autostarts
or reconnects through a CLI. Verify the recorded daemon PID/start/executable identity and
owner-only socket/private home before each operation, validate each returned lease's ID,
owner session, active state, UDID and isolated env against the parent's supplied receipt,
and renew only those exact two owned leases. Parent must hold/renew them during preparation.
Renewal failure, daemon death/identity drift or insufficient expiry margin stops the owned
batch. Before starting tests, remaining TTL must exceed the entire batch deadline plus a
cleanup margin; periodic renewal maintains this margin. No CLI fallback is allowed. If the
inspected RPC shape is unsupported at runtime, report an incomplete run; parent can select
an explicitly documented TTL-held mode only after re-review. The runner checks expiry
before each phase and uses bounded deadlines, no indefinite retries. Two owned
clones maximum; inner Xcode parallel testing disabled, exact leased destination checked.
Child processes get dedicated process groups and ownership receipts (PID, start time,
executable/run markers). Before signals, verify the tuple and direct/group ownership;
never kill by name. On SIGINT/TERM/timeout/failure, preserve reports, stop verified owned
test/service/stub processes, remove only owned secret leaves, and return failure. No
`shutdown all`, `killall`, `release --all`, global pruning or foreign simulator actions.
Parent handles resource sampling/stop policy and owned lease/daemon release afterward.

The ownership record hash is saved in the private run manifest as children/group members
are observed. Recovery `cleanup` validates this stable private authority and record hash,
then each group's recorded process identities; it does not require an unexpired launch
manifest, unchanged source HEAD, available products or a running daemon. Unknown/reused
members fail closed. Each group receives bounded cleanup independently; descendant
absence is checked, and incomplete cleanup remains failure. Artifact copying, secret-leaf
cleanup, lock closure and final receipt writing each have independent failure handling so
an export failure cannot skip stopping owned children. The two-file ownership/hash update
can be interrupted between writes; a resulting hash mismatch requires parent inspection
and never authorizes signals to unproven processes.

## Acceptance gates

1. Independent plan review and parent go before source edits.
2. No-build checks: Python syntax/unit fixtures, generated membership and `git diff --check`.
3. Assigned parent heavy-build slot: targeted `E2ELaneContractTests` and existing launch/token
   `E2EHooksTests`; compile stub and phone/UI runner; fail/symlink/TTL/identity regression checks.
4. Independent sensitive diff/dependents review; fix one bounded re-review.
5. Parent runtime slot after foreign-load/resource check; individual lane smoke, then one
   short two-lane batch with measured overlap and both-direction negative controls.
6. Parent integration verification. No runtime pass is claimed from source/unit fixtures.

## Source checkpoint evidence

Author lightweight checks: standalone `xcrun swiftc -typecheck -D DEBUG
RemoteShared/E2ELaneContract.swift` passed; `python3 -m unittest discover -s script/e2e
-p test_parallel_stub.py -v` passed 13 fixtures; `git diff --check` passed. Fixtures cover
v1/v2 host-relative products, external-product rejection, platform admission, complete
debug-dylib hashing, no OS identity injection, both negative-control directions, missing
socket/no-autostart, private JSON, PID drift, proven descendants, fast-exit tracking,
copy-failure cleanup and expired/changed-source recovery with record corruption refusal.

Parent-reported native gates: 25 selected `E2ELaneContractTests`/`E2EHooksTests` methods
passed after the lexical path correction; stub build passed; simulator phone/UI
build-for-testing passed in 32.7 seconds. The initial valid-root failure is retained in
the parent's `work/parallel-simulator-build/lane-policy-tests.log`; Foundation's alias
normalization was replaced with explicit lexical checks, retaining `/tmp` alias,
traversal and duplicate-slash rejection. Root owns generated test membership.

No author heavy build, daemon/lease/simulator lifecycle, app install, actual Mac input,
permission change or pairing reset was performed. Per-lane runtime, OS identity/lease RPC,
two-lane measured overlap, actual negative controls and final cleanup remain unverified.
