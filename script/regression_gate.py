#!/usr/bin/env python3
"""Fail-closed golden gate. XCTest receipts, not build success, decide each row."""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
COORDINATION = Path.home() / 'Documents/Codex/2026-10-01/testing'
DEFAULT_DD = '/Volumes/Studio/Development/Caches/b7-regress/DD'
DEFAULT_SIM = 'C643B2C2-3248-4AE4-B234-8F54414F3A41'
REPLAYS = [
    ('LadderPolicyTests', 'testAnIdleSourceWithAHealthyPhoneAndNetworkNeverStepsDownAndClimbsBackToTheTop'),
    ('LadderPolicyTests', 'testACollapsedEstimateOnATrustedLANIsNotEvidence'),
    ('SenderQueueGovernorTests', 'testStepsDownUnderTheCapRateFirstAndStopsAtFifteenFullSize'),
    ('SenderQueueGovernorTests', 'testPersistentQueueCostsResolutionWithKeyFrameStepsSpacedApart'),
    ('ViewportCaptureTests', 'testSmallPinchAndPanReplayKeepsCoveredRegionAndEncoderSizeStable'),
    ('ViewportCaptureTests', 'testReplayConfigurationMatchesEveryEchoedRegion'),
]


def receipts(log):
    """Require explicit terminal cases. A skip or any failed retry cannot turn green."""
    result = {}
    patterns = [
        r"Test Case '-\[(?:\w+\.)?(\w+) (test\w+)\]' (passed|failed|skipped)",
        r"Test case '(?:\w+\.)?(\w+)\.(test\w+)\(\)' (passed|failed|skipped)",
    ]
    for pattern in patterns:
        for cls, method, status in re.findall(pattern, log):
            key = f'{cls}/{method}'
            previous = result.get(key)
            result[key] = previous if previous in ('failed', 'skipped') else status
    return result


def priority_blocks(text):
    # The orchestrator explicitly lists exemptions; an unknown format fails closed.
    match = re.search(r"(?m)^Exempt lanes \(may build\): ([^.\n]+)\.", text)
    return not match or os.environ.get('FARSIDE_BUILD_LANE', 'b7-regress') not in {lane.strip() for lane in match[1].split(',')}


def coordination_blocks(ui=False):
    priority = COORDINATION / 'PRIORITY-BUILD'
    try:
        priority_blocked = priority_blocks(priority.read_text())
    except FileNotFoundError:
        priority_blocked = False
    except OSError:
        priority_blocked = True
    return (COORDINATION / 'PAUSE-BUILDS').exists() or priority_blocked or bool(list(COORDINATION.glob('QUIET-GRANTED-*'))) or (ui and not (COORDINATION / 'CHAIN2-GO').exists())


def wait_permission(ui=False):
    while coordination_blocks(ui):
        print('WAIT: build/quiet coordination' + (' / CHAIN2-GO' if ui else ''), flush=True)
        time.sleep(60)


def run_locked(command, logfile, ui=False, cleanup=False):
    if not cleanup and shutil.disk_usage(Path.home()).free < 10 * 1024**3:
        logfile.write_text('FAIL: internal disk has less than 10 GiB free; stage not started.\n')
        print(f'{logfile.stem}: FAIL (internal disk below 10 GiB)', flush=True)
        return 1
    # Recheck after acquiring the shared inode: another lane may grant quiet while we wait.
    wrapper = [sys.executable, str(Path(__file__).resolve()), '--locked-command', 'cleanup' if cleanup else ('ui' if ui else 'build'), '--']
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    start = time.monotonic()
    while True:
        wait_permission(ui)
        with logfile.open('w') as handle:
            process = subprocess.run([str(Path.home() / 'bin/farside-lock'), *wrapper, *command], cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT)
        if process.returncode != 75:
            break
        # The wrapper released the lock before waiting, so priority builds can acquire it.
    print(f'{logfile.stem}: {"PASS" if process.returncode == 0 else "FAIL"} ({time.monotonic()-start:.1f}s), {logfile}', flush=True)
    return process.returncode


def required_status(checks, observed, modes=('DEVICE',)):
    if not checks:
        return 'DEVICE' if set(modes) == {'DEVICE'} else 'FAIL'
    return 'PASS' if all(observed.get((c['suite'], f"{c['class']}/{c['method']}")) == 'passed' for c in checks) else 'FAIL'


def self_test():
    assert receipts("Test Case '-[M.C testOne]' passed (0.1 seconds).") == {'C/testOne': 'passed'}
    assert receipts("Test case 'M.C.testOne()' passed on 'sim' (0.1 seconds).") == {'C/testOne': 'passed'}
    assert receipts("Test Case '-[C testOne]' failed\nTest Case '-[C testOne]' passed") == {'C/testOne': 'failed'}
    check = [{'suite': 'ui', 'class': 'C', 'method': 'testOne'}]
    assert required_status(check, {}) == 'FAIL'
    assert required_status(check, {('ui', 'C/testOne'): 'skipped'}) == 'FAIL'
    assert required_status(check, {('phone', 'C/testOne'): 'passed'}) == 'FAIL'
    assert required_status(check, {('ui', 'C/testOne'): 'passed'}) == 'PASS'
    assert required_status([], {}, ['AUTO', 'DEVICE']) == 'FAIL'
    assert required_status([], {}, ['SIM']) == 'FAIL'
    assert not priority_blocks('Exempt lanes (may build): b8-vdisplay, batch-7a, b7-regress.\n')
    assert priority_blocks('Exempt lanes (may build): batch-7a.\n')
    assert priority_blocks('b7-regress maybe exempt')
    print('PASS: receipt parsing, missing, skipped, failed retry, cross-suite isolation and priority exemptions')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', default=DEFAULT_DD)
    parser.add_argument('--simulator', help='Existing caller-managed simulator UDID; default creates an isolated temporary simulator')
    parser.add_argument('--logs', help='Fresh receipt directory (must not exist)')
    parser.add_argument('--expected-build', help='Require the host and phone artifacts to have this CFBundleVersion')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    rows = json.loads((ROOT / 'script/regression-golden.json').read_text())
    if isinstance(rows, dict):
        rows = rows['rows']
    assert rows and len({r['id'] for r in rows}) == len(rows), 'Empty or duplicate golden rows'
    for row in rows:
        assert row['modes'] and set(row['modes']) <= {'AUTO', 'SIM', 'REPLAY', 'DEVICE'}, 'Invalid modes'
        assert row['checks'] or set(row['modes']) == {'DEVICE'}, f"Missing automation for {row['id']}"
        for check in row['checks']:
            assert check['suite'] in ('core', 'phone', 'ui')
            assert re.fullmatch(r'\w+', check['class']) and re.fullmatch(r'test\w+', check['method'])
            folder = {'core': 'RemoteTests', 'phone': 'RemotePhoneTests', 'ui': 'RemotePhoneUITests'}[check['suite']]
            assert any(re.search(r'func\s+' + check['method'] + r'\s*\(', p.read_text()) and re.search(r'class\s+' + check['class'] + r'\b', p.read_text()) for p in (ROOT / folder).glob('*.swift')), f"Missing source selector {check}"
    inventory = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    devices = [d for group in inventory['devices'].values() for d in group]
    device = next((d for d in devices if d['udid'] == (args.simulator or DEFAULT_SIM)), None)
    if not device:
        parser.error('Destination must be an available simulator; real device destinations are forbidden')
    dd = Path(args.derived_data).resolve()
    assert dd != Path('/'), 'Invalid DerivedData'
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    logs = Path(args.logs) if args.logs else ROOT / 'outputs/regression-gate' / stamp
    logs.mkdir(parents=True, exist_ok=False)
    start = time.monotonic()
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)
    sources = [*ROOT.glob('RemoteHost/**/*.swift'), *ROOT.glob('RemotePhone/**/*.swift'), *ROOT.glob('RemoteShared/**/*.swift'), *ROOT.glob('RemoteTests/*.swift'), *ROOT.glob('RemotePhoneTests/*.swift'), *ROOT.glob('RemotePhoneUITests/*.swift'), *ROOT.glob('script/regression*'), ROOT / 'PocketDesktop.xcodeproj/project.pbxproj']
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_file()}
    (logs / 'source-manifest.json').write_text(json.dumps(source_hashes, indent=2) + '\n')
    common = ['-project', 'PocketDesktop.xcodeproj', '-configuration', 'Debug', '-derivedDataPath', str(dd), '-clonedSourcePackagesDirPath', '/Users/roshansilva/Developer/PocketDesk/outputs/RemoteBuild/SourcePackages', '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile']
    stages = {}
    observed = {}
    builds = {}
    destination = args.simulator
    owned_simulator = None
    def stage(name, command, ui=False):
        status = run_locked(command, logs / (name + '.log'), ui, cleanup=name == 'simulator-cleanup')
        stages[name] = status
        return status
    def tests(suite, selections, prefix):
        command = ['xcodebuild', *common, '-scheme', 'PocketDeskRemote', '-destination', f'platform=iOS Simulator,id={destination}', 'ARCHS=arm64', 'test-without-building', '-collect-test-diagnostics', 'never', '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '120', '-resultBundlePath', str(logs / (suite + '.xcresult'))]
        command += [f'-only-testing:{prefix}/{cls}/{method}' for cls, method in sorted(selections)]
        stage(suite, command, suite == 'ui')
        observed.update({(suite, k): v for k, v in receipts((logs / (suite + '.log')).read_text()).items()})
    try:
        if not destination:
            runtime = next(runtime for runtime, group in inventory['devices'].items() if device in group)
            created = stage('simulator-create', ['/usr/bin/xcrun', 'simctl', 'create',
                'Farside Regression ' + stamp, device['deviceTypeIdentifier'], runtime])
            match = re.search(r'(?m)^([A-Fa-f0-9-]{36})$', (logs / 'simulator-create.log').read_text())
            if created == 0 and match:
                destination = owned_simulator = match[1]
            else:
                stages['simulator-create'] = 1
        stage('host-build', ['xcodebuild', *common, '-scheme', 'PocketDeskRemoteHost', '-destination', 'platform=macOS', 'build'])
        core_built = stage('core-build', ['xcodebuild', *common, '-scheme', 'RemoteCoreTests', '-destination', 'platform=macOS', 'build-for-testing']) == 0
        core = {(c['class'], c['method']) for r in rows for c in r['checks'] if c['suite'] == 'core'} | set(REPLAYS)
        if core_built:
            # xctest class selection: execute complete focused classes, validate mapped individual receipts.
            stage('core', ['/usr/bin/xcrun', 'xctest', '-XCTest', ','.join(sorted({cls for cls, _ in core})), str(dd / 'Build/Products/Debug/RemoteCoreTests.xctest')])
            observed.update({('core', k): v for k, v in receipts((logs / 'core.log').read_text()).items()})
        phone_built = bool(destination) and stage('phone-build', ['xcodebuild', *common, '-scheme', 'PocketDeskRemote', '-destination', f'platform=iOS Simulator,id={destination}', 'ARCHS=arm64', 'build-for-testing']) == 0
        if not destination:
            stages['phone-build'] = 1
        if phone_built:
            for suite, prefix in [('phone', 'RemotePhoneTests'), ('ui', 'RemotePhoneUITests')]:
                selected = {(c['class'], c['method']) for r in rows for c in r['checks'] if c['suite'] == suite}
                if suite == 'phone':
                    selected.add(('ViewportCaptureTests', 'testPinchPanReplayEmitsAtMostOneEscapeAndOneSettledRegion'))
                if selected:
                    tests(suite, selected, prefix)
    finally:
        # Only a UUID created by this invocation is ours; caller-managed/shared sims stay untouched.
        if owned_simulator:
            cleanup = 'import json,subprocess,sys; u=sys.argv[1]; d=json.loads(subprocess.check_output(["xcrun","simctl","list","devices","--json"])); booted=any(x["udid"]==u and x["state"]=="Booted" for g in d["devices"].values() for x in g); subprocess.check_call(["xcrun","simctl","shutdown",u]) if booted else None; subprocess.check_call(["xcrun","simctl","delete",u])'
            stage('simulator-cleanup', [sys.executable, '-c', cleanup, owned_simulator])
    for target, artifact in [('host', dd / 'Build/Products/Debug/PocketDeskRemoteHost.app/Contents/Info.plist'),
                             ('phone', dd / 'Build/Products/Debug-iphonesimulator/PocketDeskRemote.app/Info.plist')]:
        if artifact.exists():
            builds[target] = str(plistlib.loads(artifact.read_bytes()).get('CFBundleVersion', ''))
        if args.expected_build:
            stages[target + '-build-version'] = 0 if builds.get(target) == args.expected_build else 1
            print(f'{target} build version: {builds.get(target, "MISSING")}; expected {args.expected_build}')
    results = []
    for row in rows:
        status = 'RETIRED' if row.get('retired') else required_status(row['checks'], observed, row['modes'])
        results.append({'id': row['id'], 'behavior': row['behavior'], 'status': status, 'device': 'DEVICE' in row['modes'] and not row.get('retired')})
        suffix = " [automated proxy; DEVICE pending]" if row["checks"] and "DEVICE" in row["modes"] else ""
        print(f"{status}: {row['id']} {row['behavior']}{suffix}")
    replay_results = []
    for cls, method in REPLAYS:
        status = 'PASS' if observed.get(('core', f'{cls}/{method}')) == 'passed' else 'FAIL'
        replay_results.append({'test': f'{cls}/{method}', 'status': status})
        print(f'REPLAY {status}: {cls}/{method}')
    phone_replay = 'ViewportCaptureTests/testPinchPanReplayEmitsAtMostOneEscapeAndOneSettledRegion'
    phone_replay_status = 'PASS' if observed.get(('phone', phone_replay)) == 'passed' else 'FAIL'
    replay_results.append({'test': 'phone/' + phone_replay, 'status': phone_replay_status})
    print(f'REPLAY {phone_replay_status}: phone/{phone_replay}')
    print('DEVICE smoke required before installation acceptance:')
    for row in rows:
        if 'DEVICE' in row['modes'] and not row.get('retired'):
            print(f"  {row['id']}: {row['behavior']}")
    elapsed = time.monotonic() - start
    passed = all(s == 0 for s in stages.values()) and all(r['status'] != 'FAIL' for r in results + replay_results)
    summary = {'builds': builds, 'expected_build': args.expected_build, 'revision': revision, 'dirty': dirty, 'simulator': destination, 'runtime_seconds': round(elapsed, 1), 'stages': stages, 'rows': results, 'replays': replay_results, 'observed': {f'{s}/{k}': v for (s, k), v in observed.items()}, 'automated_gate': 'PASS' if passed else 'FAIL', 'device_smoke': 'PENDING'}
    (logs / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f"AUTOMATED GATE {summary['automated_gate']}; {len(rows)} rows; {elapsed:.1f}s; receipt {logs / 'summary.json'}")
    return 0 if passed else 1


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--locked-command':
        if coordination_blocks(sys.argv[2] == 'ui'):
            sys.exit(75)
        if sys.argv[2] != 'cleanup' and shutil.disk_usage(Path.home()).free < 10 * 1024**3:
            print('FAIL: internal disk below 10 GiB; stage not started', flush=True)
            sys.exit(1)
        os.execvp(sys.argv[4], sys.argv[4:])
    sys.exit(main())
