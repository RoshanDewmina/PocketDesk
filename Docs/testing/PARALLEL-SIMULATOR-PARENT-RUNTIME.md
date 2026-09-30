# Parent runtime orchestration

The preparation-only version has been exercised by root in owned, bounded batches.
Those batches stopped before native tests and their exact leases, clone devices and daemon
were recovered. The process-lifetime and resource updates passed independent source review. Source checkout
and helper remain explicitly frozen for execution. Native simultaneous XCTest acceptance
is still pending: the latest bounded initial preflight observed only warning pressure
for90seconds and started no daemon, leases or simulator devices.

This script requires the reviewed final Farside runner in a clean checkout and parent-owned
build evidence. It makes a new private per-run Simurgh home, pins the explicit repository
binary by SHA-256, explicitly starts exactly one owned daemon, sequentially requests an
iPhone 17 and iPad mini (A17 Pro) on the same iOS 27.0 runtime through direct protocol-v1
RPC, snapshots the complete Products closure for each lease, and calls runner prepare,
validate and run. There is no Simurgh CLI invocation/autostart, xcodebuild build, installation
to the Mac or physical phone, permission reset, warm template or broad simulator operation.
Xcode test-without-building remains the only native execution, inside the reviewed runner.

Parent input build receipt (regular owned 0600 JSON) must contain:

```json
{
  "sourceRevision": "exact frozen commit",
  "buildsPassed": true,
  "xcodeVersion": "exact xcodebuild -version output without trailing newline",
  "developerDir": "/Applications/Xcode.app/Contents/Developer",
  "productsRootSHA256": "runner.tree_hash of source Build/Products closure",
  "xctestrunSHA256": "SHA256 of supplied source xctestrun",
  "stubClosureSHA256": "runner.tree_hash of supplied built stub app",
  "scope": "parent-recorded actual build/test scope",
  "logs": ["parent build/test receipt paths"]
}
```

Derive the parent input from its actual final build provenance and actual closures; do not mark a stale build
as the current commit merely to satisfy this script. The script checks the original closures
before copying, rebases only original product-root strings and lane-owned LLVM profile paths
in the copied xctestrun, then emits a derived runner receipt carrying the supplied parent
claims and original receipt hash with the new phone/tablet closure hashes. It does not claim
that copying proves tablet portability; the actual lane assertions remain the acceptance.

A separate fresh 0600 parent coordination receipt must contain `sourceRevision`,
`buildsAndPerformanceIdle: true`, and numeric Unix `capturedAt` no older than five minutes.
Read-only process/resource checks are additional checks. Foreign booted simulators cause
refusal unless each exact UDID is explicitly allowed after parent workload coordination;
the script never stops them. Stable normal pressure is required before new provisioning or
native work, thermal must be nominal, and each checked filesystem must have at least5GiB.
Missing/unknown signals refuse without fallback. Active pressure is sampled every second
with the separately documented bounded functional warning policy; exact lease renewal
has a separate15-second cadence.

Example command shape, for root to fill with exact reviewed artifacts:

```text
./script/e2e/parent-runtime.py --execute
  --repo /Users/roshansilva/Developer/PocketDesk/.codex/worktrees/parallel-simulator-lanes
  --run-id SHORT_UNIQUE_RUN_ID
  --simurgh-source-binary /Volumes/Studio/Development/simurgh/simurgh
  --simurgh-parent /private/tmp/farside-simurgh-runtime-20260930
  --workspace-parent /Users/roshansilva/Documents/Codex/2026-09-30/ca/work/parallel-simulator-runtime
  --products-root EXACT_FINAL_DERIVED_DATA/Build/Products
  --xctestrun EXACT_FINAL_DERIVED_DATA/Build/Products/FarsideE2E_iphonesimulator27.0-arm64.xctestrun
  --stub-app EXACT_FINAL_STUB_PRODUCTS/FarsideE2EStubHost.app
  --source-build-receipt EXACT_OWNER_ONLY_FINAL_BUILD_RECEIPT.json
  --coordination-receipt EXACT_OWNER_ONLY_COORDINATION_RECEIPT.json
  [--runtime-library-root EXACT_EXISTING_CORE_SIMULATOR_RUNTIME_ROOT]
  [--allow-foreign-booted EXACT_COORDINATED_FOREIGN_UDID]
```

Existing private parent directories must be owned real 0700 directories, with no symlink or
writable ancestry. Source product snapshots can be on the SSD; CoreSimulator itself remains
in the default internal device set. The exact pinned binary is revision `dced58f`, SHA-256
`cac5f8c3b815604072fc54b0cf9e61971d36a886a9d98a20e5820ed0cc13c509`, and has dirty-build
provenance. The script never rebuilds or modifies that repository.

Root observed `/Volumes/Studio` is group-writable (0775), so it fails the current reviewed
private ancestry guard. Do not chmod the volume or weaken that guard. The selected daemon/
lease product-copy parent is a new internal 0700 `/private/tmp/farside-simurgh-runtime-20260930`;
the compiled original Products/stub remain read-only SSD sources. The workspace parent
prepared here is 0700. Explicit `DEVELOPER_DIR` is pinned from the actual parent receipt
inside the daemon and child environments; simulator UDID is never injected or overridden.

Acquired leases bind `releaseOnPIDExit: true` to the persistent parent Python PID, stable
distinct sessions and exact project/run/lane labels. TTL is 15 minutes; hard timeout is
30 minutes. Preparation renews those exact leases. RPCs are direct Unix-socket calls with
bounded response size, ID/version/ok checks and recorded daemon PID/start/executable/hash/
socket inode identity. Failed/unknown acquisition is recovered by an exact run label query,
then owner/spec checks before release. No global list-driven release or name glob cleanup.

On every failure, cleanup phases remain independent: reviewed runner ownership cleanup,
diagnostic export excluding token/invitation/pair trust, exact owned release, read-only
verification that clone UDIDs disappeared, then owned daemon termination only after full
release verification. Because Simurgh release teardown is best effort, a leftover clone or
unknown acquire outcome keeps the verified daemon alive for PID/TTL/reaper recovery and
records incomplete cleanup for root; it never kills a replacement daemon or foreign clone.
The persistent parent exits only after its bounded finally path writes
`parent-runtime-receipt.json`. Both artifacts and daemon identity logs remain in the new
private per-run workspace. Runtime results are not known until root reviews and executes.
Cleanup refetches each exact lease immediately before release to revalidate ownership,
then waits up to 30 seconds for only those known clone UDIDs to disappear. Unknown acquire
outcomes preserve the recorded daemon authority and discovered exact owned candidates for
root recovery, without claiming complete cleanup.


Simulator products must pass strict codesign admission. This project disables signing by
default; root performed a simulator-only build-for-testing override with
`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`.
This uses ad hoc signing and does not change a developer account or production identity.
The input receipt identifies the compiled Swift checkpoint separately from subsequent
Python runner changes, with exact unchanged Swift/project diff and product hashes.

Leaders settle into the exact intended main executable and argv before ownership is frozen.
For descendants proven by current-census ancestry, public macOS proc_pidinfo birth seconds/
microseconds plus PID, effective/real UID and original process group survive normal exec.
Leader and legacy records retain strict full command identity. Missing or unknown live
identity fails closed. The SDK ABI and actual harmless exec probe are recorded separately.

Each readonly phase records a completed group only after the direct child exited and an
independent final census proved no descendants. If prepare/validate fails before run is
invoked and no native ownership record exists, cleanup recenses these groups before
allowing exact lease release. Once native run is invoked or ownership exists, strict
runner cleanup is mandatory. Failed/missing census or unresolved groups preserve recovery
authority. Successful mocked checks do not establish native overlap.


### Functional resource policy correction

Initial preflight still requires known Dispatch NORMAL (1), nominal thermal state and
at least5GiB per checked filesystem. Unknown or missing sysctl signals refuse without
fallback. After exact lease provisioning, a no-new-child settling phase waits at most90s
(and within the total orchestration deadline), renewing exact owned leases only. Three
normal observations at least2s apart spanning at least4s precede each additional lease
and native-run workload. Critical (4) or unknown pressure refuses on observation.

The active functional allowance starts with preparation and carries one monotonic budget
through validation, the before-native gate and native run; it never resets between phases.
Warning (2) may last at most30s continuously and in aggregate. Clearing requires three
normal samples at least2s apart spanning4s; brief flapping cannot reset warning exposure.
Active child monitoring targets one-second sampling and refuses observed gaps over2s.
Local lease renewal requests have0.5s deadlines. Actual samples are written before pressure
policy refusal, including raw values and monotonic timestamps; missing-signal errors are
recorded separately. Existing process/lease/product/isolation admission stays unchanged.
These caps are conservative engineering choices, not Apple-prescribed safe durations,
and acceptance remains incomplete if they cannot be met on this Mac.

The public AppleOSS sysctl handler maps internal pressure enums to Dispatch mask values.
Installed source.h corroborates1/2/4; the internal enum table0..4 must not be mistaken for
the exposed sysctl output. Sources:
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c
https://developer.apple.com/documentation/dispatch/dispatchsource/memorypressureevent/warning
https://developer.apple.com/documentation/dispatch/dispatch_memorypressure_critical

The previous warning after two cold boots does not prove boot was the cause; warnings
also persisted after cleanup. This policy verifies functional isolation only and cannot
establish performance, power, phone latency or comfortable user-session headroom.

The30s warning threshold is evaluated on the next resource observation; sampling and
command latency mean it is not a hard wall-clock stop guarantee. A sample gap over2s
refuses active monitoring rather than treating the missing interval as healthy. If a
thermal/disk read fails after a pressure value was obtained, the partial pressure report
and error are preserved before failure; a missing sysctl never manufactures a level.
Initial preflight uses the same no-child90s settling wait, with no daemon/RPC/lease yet,
and still requires stable normal before any daemon or first lease starts.

## Durable helper checkpoint

The helper and25 fixtures are committed beside the runner, copied byte-for-byte from
the independently reviewed helper SHA-256`fd34b7d7e010d55cd4f288fde39989c182ca020474e04e097dea8a2207e3c076`. Run
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s script/e2e -p test_parent_runtime.py -v`
for its fixture suite. These mocked tests prove policy behavior, not native device overlap.
The runner has21 separate fixtures. Existing native products were compiled at4ded584;
later commits change Python orchestration/docs only. Preserve that distinction in receipts.
