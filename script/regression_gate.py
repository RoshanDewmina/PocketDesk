#!/usr/bin/env python3
"""Fail-closed golden gate. XCTest receipts, not build success, decide each row."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
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


def coordination_blocks(ui=False):
    return (COORDINATION / 'PAUSE-BUILDS').exists() or (COORDINATION / 'PRIORITY-BUILD').exists() or bool(list(COORDINATION.glob('QUIET-GRANTED-*'))) or (ui and not (COORDINATION / 'CHAIN2-GO').exists())


def wait_permission(ui=False):
    while coordination_blocks(ui):
        print('WAIT: build/quiet coordination' + (' / CHAIN2-GO' if ui else ''), flush=True)
        time.sleep(60)


def run_locked(command, logfile, ui=False):
    # Recheck after acquiring the shared inode: another lane may grant quiet while we wait.
    wrapper = [sys.executable, str(Path(__file__).resolve()), '--locked-command', 'ui' if ui else 'build', '--']
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    start = time.monotonic()
    while True:
        wait_permission(ui)
        with logfile.open('w') as handle:
            process = subprocess.run(['/usr/bin/lockf', '-k', '/tmp/farside-xcodebuild.lock', *wrapper, *command], cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT)
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
    print('PASS: receipt parsing, missing, skipped, failed retry and cross-suite isolation')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', default=DEFAULT_DD)
    parser.add_argument('--simulator', default=DEFAULT_SIM, help='Existing available simulator UDID only')
    parser.add_argument('--logs', help='Fresh receipt directory (must not exist)')
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
    device = next((d for d in devices if d['udid'] == args.simulator), None)
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
    sources = [*ROOT.glob('RemoteTests/*.swift'), *ROOT.glob('RemotePhoneTests/*.swift'), *ROOT.glob('RemotePhoneUITests/*.swift'), *ROOT.glob('script/regression*'), ROOT / 'PocketDesktop.xcodeproj/project.pbxproj']
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_file()}
    (logs / 'source-manifest.json').write_text(json.dumps(source_hashes, indent=2) + '\n')
    common = ['-project', 'PocketDesktop.xcodeproj', '-configuration', 'Debug', '-derivedDataPath', str(dd), '-clonedSourcePackagesDirPath', '/Users/roshansilva/Developer/PocketDesk/outputs/RemoteBuild/SourcePackages', '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile']
    stages = {}
    observed = {}
    def stage(name, command, ui=False):
        status = run_locked(command, logs / (name + '.log'), ui)
        stages[name] = status
        return status
    def tests(suite, selections, prefix):
        command = ['xcodebuild', *common, '-scheme', 'PocketDeskRemote', '-destination', f'platform=iOS Simulator,id={args.simulator}', 'ARCHS=arm64', 'test-without-building', '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '120', '-resultBundlePath', str(logs / (suite + '.xcresult'))]
        command += [f'-only-testing:{prefix}/{cls}/{method}' for cls, method in sorted(selections)]
        stage(suite, command, suite == 'ui')
        observed.update({(suite, k): v for k, v in receipts((logs / (suite + '.log')).read_text()).items()})
    try:
        stage('host-build', ['xcodebuild', *common, '-scheme', 'PocketDeskRemoteHost', '-destination', 'platform=macOS', 'build'])
        core_built = stage('core-build', ['xcodebuild', *common, '-scheme', 'RemoteCoreTests', '-destination', 'platform=macOS', 'build-for-testing']) == 0
        core = {(c['class'], c['method']) for r in rows for c in r['checks'] if c['suite'] == 'core'} | set(REPLAYS)
        if core_built:
            # xctest class selection: execute complete focused classes, validate mapped individual receipts.
            stage('core', ['/usr/bin/xcrun', 'xctest', '-XCTest', ','.join(sorted({cls for cls, _ in core})), str(dd / 'Build/Products/Debug/RemoteCoreTests.xctest')])
            observed.update({('core', k): v for k, v in receipts((logs / 'core.log').read_text()).items()})
        phone_built = stage('phone-build', ['xcodebuild', *common, '-scheme', 'PocketDeskRemote', '-destination', f'platform=iOS Simulator,id={args.simulator}', 'ARCHS=arm64', 'build-for-testing']) == 0
        if phone_built:
            for suite, prefix in [('phone', 'RemotePhoneTests'), ('ui', 'RemotePhoneUITests')]:
                selected = {(c['class'], c['method']) for r in rows for c in r['checks'] if c['suite'] == suite}
                if suite == 'phone':
                    selected.add(('ViewportCaptureTests', 'testPinchPanReplayEmitsAtMostOneEscapeAndOneSettledRegion'))
                if selected:
                    tests(suite, selected, prefix)
    finally:
        # Shut down only a simulator this invocation started. Never touch a previously booted one.
        if device['state'] != 'Booted':
            stage('simulator-cleanup', ['/usr/bin/xcrun', 'simctl', 'shutdown', args.simulator])
    results = []
    for row in rows:
        status = required_status(row['checks'], observed, row['modes'])
        results.append({'id': row['id'], 'behavior': row['behavior'], 'status': status, 'device': 'DEVICE' in row['modes']})
        print(f"{status}: {row['id']} {row['behavior']}")
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
        if 'DEVICE' in row['modes']:
            print(f"  {row['id']}: {row['behavior']}")
    elapsed = time.monotonic() - start
    passed = all(s == 0 for s in stages.values()) and all(r['status'] != 'FAIL' for r in results + replay_results)
    summary = {'revision': revision, 'dirty': dirty, 'simulator': args.simulator, 'runtime_seconds': round(elapsed, 1), 'stages': stages, 'rows': results, 'replays': replay_results, 'observed': {f'{s}/{k}': v for (s, k), v in observed.items()}, 'automated_gate': 'PASS' if passed else 'FAIL', 'device_smoke': 'PENDING'}
    (logs / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f"AUTOMATED GATE {summary['automated_gate']}; {len(rows)} rows; {elapsed:.1f}s; receipt {logs / 'summary.json'}")
    return 0 if passed else 1


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--locked-command':
        if coordination_blocks(sys.argv[2] == 'ui'):
            sys.exit(75)
        os.execvp(sys.argv[4], sys.argv[4:])
    sys.exit(main())
