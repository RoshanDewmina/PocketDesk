# Golden regression gate

Run from the integration checkout before making a device candidate:

```sh
script/regression-gate.sh
```

The default lane DerivedData is `/Volumes/Studio/Development/Caches/b7-regress/DD`.
Use `--derived-data /Volumes/Studio/Development/Caches/<integration>/DD` for a different
integration lane. `--simulator <UDID>` accepts only an available simulator from
`simctl` and leaves that caller-managed simulator running. By default the gate creates
an isolated temporary simulator matching template `C643B2C2-3248-4AE4-B234-8F54414F3A41`
and shuts down/deletes only that created UUID at exit. The gate builds the
host, core test bundle and phone test bundles, then executes focused core classes,
mapped phone unit cases, selected offline UI cases and seven policy/report replays.
It never runs the built host or installs to physical devices.

Every Xcode build/test and xctest command runs under `lockf -k` on the shared lock.
The gate waits for PAUSE-BUILDS and QUIET-GRANTED files to clear;
PRIORITY-BUILD is honored unless its explicit exemption list includes b7-regress;
UI execution also waits for CHAIN2-GO. It rechecks after obtaining the lock and
releases it if permission changed, allowing priority builds to proceed. Caller-managed simulators are never shut down, regardless of their entry state.
Build/test stages refuse to start if the internal disk has less than 10 GiB free;
owned-simulator cleanup is exempt from that disk guard so it can reclaim space. No permission reset, host replacement or version bump occurs.

`script/regression-golden.json` is the executable row-to-test contract. Exact
terminal XCTest case receipts decide each row: missing, skipped, failed or
failed-then-retried tests cannot pass. A failed build/test process also fails the
overall gate even if its mapped rows passed. The historical G21 Session check pill is `RETIRED` because the owner explicitly
requested its removal in batch 7; it imposes no current test/smoke obligation.
Active DEVICE-only rows print `DEVICE`,
not `PASS`. Automated rows with device obligations print their proxy PASS/FAIL
and remain in the separate device list. An automated PASS is necessary for a
candidate, and does not certify physical smoothness, app-specific keyboard
delivery, real permissions or media behavior.

Receipts default to `outputs/regression-gate/<timestamp>/`: stage logs,
phone/UI xcresult bundles, exact revision/dirty state, source hashes and
`summary.json` with runtime and per-row outcomes. `--logs <new-directory>` writes
elsewhere. `--self-test` checks fail-closed receipt parsing without building.
Any missing/invalid manifest selector stops the gate before a build.
`--expected-build 20261002.3` also verifies the host and phone artifact bundle
versions and fails the overall gate on a mismatch or missing artifact. Receipts
include hashes of host, phone and shared Swift sources as well as tests/harness.

The core gesture churn replay intentionally defines a defensive bound on small
accepted requests still covered by the previous crop (at most one source-region
and one encoder-size change). The current phone normally suppresses that covered
trace during motion. A failure identifies missing host hysteresis; it alone does
not prove the physical build `.2` jitter's cause. The phone replay exercises the
real reporter's escape/delayed-echo/settle path. Configuration/cache consistency
is tested separately; pixels already in flight still need physical acceptance.

The evidence ledger and quick physical procedure are preserved beside this file
as `REGRESSION-GOLDEN.md` and `DEVICE-SMOKE.md`. Requested delivery copies live in
`~/Documents/Codex/2026-10-01/perf-push/`. The quick smoke has a strict ten-minute
hands-on budget; longer historical dwell evidence must not be claimed from a
short smoke.

## Baseline receipt and runtime

The resumed instruction supersedes the baseline run: apply the harness onto
`claude/batch-7a` after its `batch-7a-run.txt` EXIT receipt, then run against
build `20261002.3`. The integration run receipt and measured runtime are pending. The measured wall time includes shared-lock waits;
it is not a physical performance measurement.

Xcode 27.0 / 27A266a and macOS 27.0.1 / 26A434 were verified on 2 October 2026.
Apple's [test-running documentation](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results)
and iOS/macOS 27 release notes were retrieved live; the gate adds no platform API.
