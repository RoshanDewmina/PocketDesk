#!/usr/bin/env python3
"""Review-only preparation. Root may explicitly execute this bounded two-lane orchestration."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
SIMURGH_SHA256 = 'cac5f8c3b815604072fc54b0cf9e61971d36a886a9d98a20e5820ed0cc13c509'
AGENT = 'farside-parent-runtime'
PROVISION_SECONDS = 240
TOTAL_SECONDS = 1000


class Refused(RuntimeError): pass


class ResourceSnapshotFailure(Refused):
    def __init__(self, message, partial):
        super().__init__(message); self.partial = partial


def check(condition, message):
    if not condition: raise Refused(message)


def command(argv, **kwargs):
    return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=kwargs.pop('timeout', 15), **kwargs).stdout


def devices():
    payload = json.loads(command(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json']))
    return {item['udid']: item for group in payload['devices'].values() for item in group}


def resource_snapshot(paths):
    """Read known Dispatch pressure bits plus independent thermal/disk admission."""
    report = {'at': time.time(), 'disk': {}}
    try:
        level = int(command(['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level'], timeout=0.5).strip())
        report['memoryPressure'] = level
        thermal = command(['/usr/bin/pmset', '-g', 'therm'], timeout=0.5)
        nominal = 'No thermal warning level has been recorded' in thermal
        speed = re.search(r'CPU_Speed_Limit\s*=\s*(\d+)', thermal)
        scheduler = re.search(r'CPU_Scheduler_Limit\s*=\s*(\d+)', thermal)
        check(nominal or (speed and scheduler and int(speed.group(1)) == 100 and int(scheduler.group(1)) == 100),
              'thermal status unavailable or throttled')
        report['thermal'] = thermal.strip()
        for path in paths:
            info = os.statvfs(path)
            available = info.f_bavail * info.f_frsize
            check(available >= 5 << 30, f'disk below 5 GiB: {path}')
            report['disk'][str(path)] = available
    except Exception as error:
        raise ResourceSnapshotFailure(str(error), report) from error
    return report


def resources(paths):
    report = resource_snapshot(paths)
    check(report['memoryPressure'] == 1, f"memory pressure is not normal ({report['memoryPressure']})")
    return report


class FunctionalWarningBudget:
    """Shared across prepare/validate/run; no reset on phase changes or brief normal flaps."""
    def __init__(self):
        self.last = None; self.warning_start = None; self.warning_seconds = 0.0
        self.normal_start = None; self.normal_last = None; self.normal_count = 0

    def observe(self, level, now, enforce_gap=False):
        check(level in (1, 2), f'critical or unknown memory pressure ({level})')
        if self.last is not None:
            delta = now - self.last
            check(delta >= 0 and (not enforce_gap or delta <= 2), 'resource sample gap exceeds two seconds')
            if self.warning_start is not None: self.warning_seconds += delta
        self.last = now
        check(self.warning_seconds <= 30, 'aggregate functional warning budget exceeded')
        if self.warning_start is not None:
            check(now - self.warning_start <= 30, 'continuous functional warning budget exceeded')
        if level == 2:
            if self.warning_start is None: self.warning_start = now
            self.normal_start = self.normal_last = None; self.normal_count = 0
        else:
            if self.normal_start is None:
                self.normal_start = self.normal_last = now; self.normal_count = 1
            elif now - self.normal_last >= 2:
                self.normal_last = now; self.normal_count += 1
            if self.normal_count >= 3 and now - self.normal_start >= 4:
                self.warning_start = None
        return {'level': level, 'aggregateWarningSeconds': self.warning_seconds,
                'warningActive': self.warning_start is not None, 'normalCount': self.normal_count}


def sample_resources(runner, args, workspace, phase, budget=None, enforce_gap=False):
    stamp = time.monotonic()
    try: report = resource_snapshot([Path('/private/tmp'), Path(args.simurgh_parent)])
    except Exception as error:
        runner.write_json(workspace / 'latest-resource-sample.json', {**getattr(error, 'partial', {}), 'at': time.time(), 'phase': phase, 'error': str(error)})
        raise
    report.update(phase=phase, monotonic=stamp)
    # Trace the actual pressure value BEFORE any policy refusal.
    runner.write_json(workspace / 'latest-resource-sample.json', report)
    with open(workspace / 'resource-samples.jsonl', 'a') as handle:
        os.chmod(handle.name, 0o600); handle.write(json.dumps(report) + '\n')
    check(report['memoryPressure'] in (1, 2), f"critical or unknown memory pressure ({report['memoryPressure']})")
    if budget is not None: budget.observe(report['memoryPressure'], stamp, enforce_gap)
    return report


def settle_resources(runner, authority, args, leases, workspace, phase, budget=None):
    """No new child/load until three normal readings >=2s apart within <=90s."""
    end = min(time.monotonic() + 90, args.total_deadline)
    normal_start = normal_last = None; count = 0; next_renew = 0
    while True:
        check(time.monotonic() < end, 'normal resource settling deadline exceeded')
        sample = sample_resources(runner, args, workspace, phase, budget)
        now = time.monotonic()
        check(now < end, 'normal resource settling deadline exceeded during snapshot')
        if sample['memoryPressure'] == 1:
            if normal_start is None: normal_start = normal_last = now; count = 1
            elif now - normal_last >= 2: normal_last = now; count += 1
            if count >= 3 and now - normal_start >= 4: return sample
        else: normal_start = normal_last = None; count = 0
        if now >= next_renew:
            for lease in leases:
                live = protocol(runner, authority, 'lease.renew', {'id': lease['id'], 'ttl': '15m'}, timeout=0.5)['lease']
                runner.validate_lease(live, lease)
            next_renew = now + 15
        time.sleep(1)


def protocol(runner, authority, method, params, timeout=5):
    check(method in ('lease.acquire', 'lease.get', 'lease.renew', 'lease.release', 'lease.list'), 'RPC method denied')
    sock = runner.validate_daemon(authority)
    request_id = uuid.uuid4().hex
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(timeout)
        client.connect(str(sock))
        client.sendall(json.dumps({'v': 1, 'id': request_id, 'method': method, 'params': params}).encode() + b'\n')
        data = bytearray()
        while b'\n' not in data:
            chunk = client.recv(65536)
            check(chunk, 'daemon disconnected during RPC')
            data.extend(chunk)
            check(len(data) <= 1 << 20, 'oversized RPC response')
    reply = json.loads(data.split(b'\n', 1)[0])
    check(reply.get('v') == 1 and reply.get('id') == request_id and reply.get('ok') is True,
          'RPC failed: ' + str(reply.get('error', {}).get('code', 'invalid response')))
    return reply['result']


def rewrite_snapshot(value, old_products, new_products, profile):
    if isinstance(value, dict):
        return {key: str(profile / '%p.profraw') if key == 'LLVM_PROFILE_FILE'
                else rewrite_snapshot(item, old_products, new_products, profile) for key, item in value.items()}
    if isinstance(value, list): return [rewrite_snapshot(item, old_products, new_products, profile) for item in value]
    if isinstance(value, str): return value.replace(str(old_products) + '/', str(new_products) + '/')
    return value


def lease_matches(lease, args, sessions):
    lane = lease.get('labels', {}).get('lane')
    check(lane in sessions and lease['labels'].get('run') == args.run_id
          and lease['labels'].get('project') == 'farside-parallel-stub'
          and lease['owner']['pid'] == os.getpid() and lease['owner']['agent'] == AGENT
          and lease['owner']['sessionId'] == sessions[lane], 'unowned lease discovered')
    check(lease['spec']['platform'] == 'iOS' and lease['spec']['runtime'] == args.runtime
          and lease['spec']['model'] == ('iPhone 17' if lane == 'phone' else 'iPad mini (A17 Pro)'), 'lease spec mismatch')
    return lane


def run_child(runner, authority, args, argv, leases, workspace, log_name, timeout, monitor=True):
    # Invoke the current interpreter's final main image instead of Homebrew's exec launcher.
    if argv[0] == sys.executable:
        argv = [runner.main_image(os.getpid()), *argv[1:]]
    if monitor: sample_resources(runner, args, workspace, log_name, args.resource_budget)
    log = workspace / log_name
    handle = open(log, 'xb'); os.chmod(log, 0o600)
    child_env = {key: value for key, value in os.environ.items() if key in ('PATH', 'HOME', 'USER', 'LOGNAME', 'LANG')}
    child_env.update(DEVELOPER_DIR=authority['developerDir'], PYTHONDONTWRITEBYTECODE='1')
    # Neither SIMULATOR_UDID nor a TEST_RUNNER_ identity override is inherited/set here.
    child = subprocess.Popen(argv, env=child_env, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
    handle.close()
    # Parent Popen handle is tracked before any ps/log/RPC failure can interrupt cleanup.
    child_authority = {'pid': child.pid, 'identity': None, 'role': log_name, 'command': argv, 'members': {}}
    startup_admitted = False
    end, next_sample, next_renew = time.monotonic() + timeout, 0, 0
    try:
        child_authority.update(runner.settle_child(child, argv))
        startup_admitted = True
        while child.poll() is None:
            check(time.monotonic() < end, 'parent child deadline exceeded')
            check(time.monotonic() < args.total_deadline, 'total orchestration deadline exceeded')
            runner.validate_members(child_authority, runner.group_members(child.pid), discover=True)
            runner.write_json(workspace / ('parent-' + log_name + '-ownership.json'), child_authority)
            if monitor and time.monotonic() >= next_sample:
                sample_resources(runner, args, workspace, log_name, args.resource_budget, enforce_gap=True)
                next_sample = time.monotonic() + 1
            if monitor and time.monotonic() >= next_renew:
                for lease in leases:
                    live = protocol(runner, authority, 'lease.renew', {'id': lease['id'], 'ttl': '15m'}, timeout=0.5)['lease']
                    runner.validate_lease(live, lease)
                next_renew = time.monotonic() + 15
            time.sleep(0.3)
        check(child.returncode == 0, f'child failed ({child.returncode}); see {log}')
    finally:
        # Run recovery before force group cleanup in main finally. This helper only stops its own group.
        cleanup_error = None
        try:
            if child_authority['identity'] is not None:
                runner.stop_group(child_authority)
        except Exception as error:
            cleanup_error = error
        finally:
            # Direct child authority survives failed initial group validation. Its Popen
            # remains unreaped while live; no other poller or name-based signal is used.
            if not startup_admitted and child.poll() is None:
                try:
                    child.terminate(); child.wait(timeout=10)
                except Exception as error:
                    cleanup_error = cleanup_error or error
            census_failed = False
            try:
                remaining = runner.group_members(child.pid)
            except Exception as error:
                remaining = {}; census_failed = True
                cleanup_error = cleanup_error or error
            if census_failed or remaining or child.poll() is None:
                args.unresolved_children.append(child_authority)
                runner.write_json(workspace / ('unresolved-' + log_name + '.json'), child_authority)
                raise Refused('child descendants unresolved; preserve lease/daemon authority') from cleanup_error
            args.completed_children.append({'pid': child.pid, 'role': log_name, 'groupVerifiedAbsent': True})


def cleanup_native_authority(runner, manifest, artifacts, run_invoked, args):
    """The absence exception applies only before run, with fresh readonly-group proof."""
    if run_invoked or (artifacts / 'ownership.json').exists():
        runner.cleanup(str(manifest))
        return False
    check(not args.unresolved_children, 'readonly child cleanup unresolved')
    for child in args.completed_children:
        check(child['groupVerifiedAbsent'] is True and not runner.group_members(child['pid']),
              'readonly group not verified absent before release')
    return True


def finish_child_cleanup(runner, manifest, workspace, run_invoked, args, outcome, errors):
    """Always require native cleanup after invocation, even when its manifest disappeared."""
    complete = not args.unresolved_children
    if manifest is not None or run_invoked:
        try:
            check(manifest is not None, 'native run invoked without manifest authority')
            outcome['noNativeBatchInvoked'] = cleanup_native_authority(
                runner, manifest, workspace / 'artifacts', run_invoked, args)
        except Exception as error:
            complete = False
            errors.append('runner process cleanup: ' + str(error))
    if manifest is not None and manifest.exists():
        try:
            shutil.copytree(manifest.parent, workspace / 'preserved-lane-root', symlinks=True,
                            ignore=shutil.ignore_patterns('pairing-token', 'invitation.code', 'pair.json'))
        except Exception as error:
            errors.append('runner export: ' + str(error))
    return complete


def main(args):
    check(args.execute, 'prepared script: root must explicitly select --execute after review')
    check(re.fullmatch(r'[A-Za-z0-9_-]{1,42}', args.run_id), 'run ID must fit two distinct <=64-character sessions')
    os.umask(0o077)
    repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('farside_parallel_runner', repo / 'script/e2e/parallel-stub.py')
    runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
    check(not command(['git', 'status', '--porcelain'], cwd=repo).strip(), 'commit/freeze and clear generated scratch before execution')
    source_revision = command(['git', 'rev-parse', 'HEAD'], cwd=repo).strip()
    input_receipt = runner.read_json(Path(args.source_build_receipt))
    developer_dir = input_receipt['developerDir']
    check(developer_dir == '/Applications/Xcode.app/Contents/Developer'
          and Path(developer_dir).is_dir() and not Path(developer_dir).is_symlink(), 'pinned parent Xcode developer directory required')
    os.environ['DEVELOPER_DIR'] = developer_dir
    products = runner.absolute(args.products_root); xctestrun = runner.absolute(args.xctestrun)
    stub_app = runner.absolute(args.stub_app)
    check(xctestrun.parent == products and runner.inside(xctestrun, products), 'source xctestrun must be directly under supplied Products root')
    check(input_receipt['sourceRevision'] == source_revision and input_receipt['buildsPassed'] is True
          and input_receipt['productsRootSHA256'] == runner.tree_hash(products)
          and input_receipt['xctestrunSHA256'] == runner.sha256(xctestrun)
          and input_receipt['stubClosureSHA256'] == runner.tree_hash(stub_app), 'parent source/build receipt mismatch')
    xcode_version = command(['/usr/bin/xcodebuild', '-version']).strip()
    check(input_receipt['xcodeVersion'] == xcode_version, 'Xcode differs from parent build')
    source_binary = runner.absolute(args.simurgh_source_binary)
    runner.owned(source_binary, stat.S_ISREG)
    check(runner.sha256(source_binary) == SIMURGH_SHA256, 'Simurgh binary differs from pinned dced58f dirty build')
    runner.private_chain(Path(args.simurgh_parent)); runner.private_chain(Path(args.workspace_parent))
    workspace = Path(args.workspace_parent) / args.run_id; runner.mkdir_private(workspace)
    home = Path(args.simurgh_parent) / args.run_id; runner.mkdir_private(home)
    pinned = home / 'simurgh'; shutil.copy2(source_binary, pinned); pinned.chmod(0o500)
    check(runner.sha256(pinned) == SIMURGH_SHA256, 'pinned binary copy mismatch')
    snapshot_stub = workspace / 'Stub.app'; shutil.copytree(stub_app, snapshot_stub, symlinks=True)
    check(runner.tree_hash(snapshot_stub) == input_receipt['stubClosureSHA256'], 'stub snapshot drift')
    baseline = devices()
    booted = {udid for udid, item in baseline.items() if item['state'] == 'Booted'}
    check(booted <= set(args.allow_foreign_booted), 'uncoordinated foreign simulator load; nothing stopped')
    heavy_jobs = [line for line in command(['/bin/ps', '-axo', 'command=']).splitlines()
                  if re.search(r'(?:^|/|\s)xcodebuild(?:\s|$)', line)]
    check(not heavy_jobs, 'uncoordinated heavy job')
    coordination = runner.read_json(Path(args.coordination_receipt))
    check(coordination.get('sourceRevision') == source_revision and coordination.get('buildsAndPerformanceIdle') is True
          and 0 <= time.time() - coordination.get('capturedAt', 0) <= 300, 'fresh parent workload coordination required')
    args.total_deadline = time.monotonic() + TOTAL_SECONDS
    initial_resources = settle_resources(runner, None, args, [], workspace, 'initial-preflight')
    runner.write_json(workspace / 'parent-input-receipt.json', input_receipt)
    runner.write_json(workspace / 'preflight.json', {'sourceRevision': source_revision, 'foreignBooted': sorted(booted),
                      'resources': initial_resources, 'simurghSHA256': SIMURGH_SHA256, 'simurghRevision': 'dced58f', 'dirtyBuild': True})
    args.unresolved_children = []
    args.completed_children = []
    run_invoked = False
    sessions = {lane: args.run_id + '-' + lane + '-' + uuid.uuid4().hex[:8] for lane in ('phone', 'tablet')}
    leases, errors, run_manifest, daemon_authority = [], [], None, None
    acquire_outcome_unknown = False
    daemon = None; outcome = {'status': 'failed', 'startedAt': time.time(), 'runID': args.run_id}
    try:
        daemon_env = {key: value for key, value in os.environ.items() if key in ('PATH', 'HOME', 'USER', 'LOGNAME', 'LANG')}
        daemon_env.update(SIMURGH_HOME=str(home), SIMURGH_CAPACITY='2', SIMURGH_PER_SPEC_CAPACITY='1',
                          SIMURGH_MAX_PROVISIONING='1', SIMURGH_BUILD_SLOTS='1', DEVELOPER_DIR=developer_dir)
        handle = open(workspace / 'daemon.log', 'xb'); os.chmod(handle.name, 0o600)
        daemon = subprocess.Popen([str(pinned), 'daemon', 'run'], env=daemon_env, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        handle.close()
        daemon_authority = {'simurghHome': str(home), 'simurghBinary': str(pinned), 'simurghSHA256': SIMURGH_SHA256,
                            'daemonPID': daemon.pid, 'daemonIdentity': runner.process_identity(daemon.pid), 'developerDir': developer_dir}
        runner.write_json(workspace / 'daemon-ownership.json', daemon_authority)
        deadline = time.monotonic() + 20
        while daemon.poll() is None and time.monotonic() < deadline and not (home / 'simurghd.sock').exists(): time.sleep(0.2)
        check(daemon.poll() is None, 'owned daemon exited')
        sock_info = runner.validate_daemon(daemon_authority).lstat()
        daemon_authority['socketIdentity'] = {'dev': sock_info.st_dev, 'ino': sock_info.st_ino, 'uid': sock_info.st_uid}
        runner.write_json(workspace / 'daemon-ownership.json', daemon_authority)
        for lane, model in (('phone', 'iPhone 17'), ('tablet', 'iPad mini (A17 Pro)')):
            settle_resources(runner, daemon_authority, args, leases, workspace, 'before-acquire-' + lane)
            params = {'spec': {'platform': 'iOS', 'model': model, 'runtime': args.runtime},
                      'labels': {'project': 'farside-parallel-stub', 'run': args.run_id, 'lane': lane},
                      'ttl': '15m', 'reuseIfExists': False, 'wait': False, 'releaseOnPIDExit': True,
                      'owner': {'pid': os.getpid(), 'ppid': os.getppid(), 'agent': AGENT, 'sessionId': sessions[lane]},
                      'timeouts': {'inactivity': '15m', 'hard': '30m'}}
            # Sequential provisioning; no third lease, no warm template, no foreign-device mutation.
            acquire_outcome_unknown = True
            lease = protocol(runner, daemon_authority, 'lease.acquire', params, timeout=PROVISION_SECONDS)['lease']
            acquire_outcome_unknown = False
            leases.append(lease)
            check(lease_matches(lease, args, sessions) == lane, 'lane acquisition mismatch')
            runner.validate_lease(lease)
            check(lease['device']['udid'] not in baseline and lease['device'].get('cloneOf'), 'grant is not a new owned clone')
            runner.write_json(workspace / (lane + '-lease.json'), {'lease': lease})
            runner.write_json(workspace / 'owned-leases.json', leases)
            destination_products = Path(lease['env']['env']['SIMURGH_DERIVED_DATA']) / 'Build/Products'
            destination_products.parent.mkdir(mode=0o700)
            shutil.copytree(products, destination_products, symlinks=True)
            profile = destination_products.parent / 'ProfileData'; profile.mkdir(mode=0o700)
            destination_xctestrun = destination_products / xctestrun.name
            original = plistlib.loads(destination_xctestrun.read_bytes())
            destination_xctestrun.write_bytes(plistlib.dumps(rewrite_snapshot(original, products, destination_products, profile)))
            destination_xctestrun.chmod(0o600)
        settle_resources(runner, daemon_authority, args, leases, workspace, 'after-provision')
        args.resource_budget = FunctionalWarningBudget()
        check(len(leases) == 2 and len({lease['device']['udid'] for lease in leases}) == 2, 'two distinct clones required')
        copied = [Path(lease['env']['env']['SIMURGH_DERIVED_DATA']) / 'Build/Products' for lease in leases]
        parent_receipt = {**input_receipt, 'laneClosureSHA256': [runner.tree_hash(root) for root in copied],
                          'parentSourceBuildReceiptSHA256': runner.sha256(Path(args.source_build_receipt)),
                          'snapshotDerivation': 'complete Products closure copied, owned xctestrun product/profile paths rebased only',
                          'simurghSHA256': SIMURGH_SHA256}
        runner.write_json(workspace / 'runner-build-receipt.json', parent_receipt)
        artifacts = workspace / 'artifacts'
        prepare = [sys.executable, str(repo / 'script/e2e/parallel-stub.py'), 'prepare', '--run-id', args.run_id,
                   '--simurgh', str(pinned), '--simurgh-sha256', SIMURGH_SHA256, '--simurgh-home', str(home),
                   '--daemon-pid', str(daemon.pid), '--daemon-identity', daemon_authority['daemonIdentity'],
                   '--lane-a-lease-json', str(workspace / 'phone-lease.json'), '--lane-b-lease-json', str(workspace / 'tablet-lease.json'),
                   '--lane-a-xctestrun', str(copied[0] / xctestrun.name), '--lane-b-xctestrun', str(copied[1] / xctestrun.name),
                   '--stub-app', str(snapshot_stub), '--artifact-dir', str(artifacts), '--build-receipt', str(workspace / 'runner-build-receipt.json')]
        for runtime_root in args.runtime_library_root: prepare.extend(['--runtime-library-root', runtime_root])
        run_child(runner, daemon_authority, args, prepare, leases, workspace, 'prepare.log', 120)
        run_manifest = runner.BASE / 'parallel' / args.run_id / 'run-manifest.json'
        for verb, limit in (('validate', 120), ('run', 510)):
            argv = [sys.executable, str(repo / 'script/e2e/parallel-stub.py'), verb, '--manifest', str(run_manifest)]
            if verb == 'run':
                settle_resources(runner, daemon_authority, args, leases, workspace, 'before-native-run', args.resource_budget)
                run_invoked = True
            run_child(runner, daemon_authority, args, argv, leases, workspace, verb + '.log', limit)
        result = runner.read_json(artifacts / 'receipt.json')
        check(result['status'] == 'passed' and result.get('overlapSeconds', 0) > 0, 'actual overlap receipt incomplete')
        outcome['runtimeReceipt'] = result; outcome['status'] = 'passed'
    except BaseException as error:
        errors.append(str(error))
    finally:
        # Independently bounded phases: export/runner cleanup failure cannot suppress lease cleanup.
        outcome['unresolvedChildren'] = args.unresolved_children
        if hasattr(args, 'resource_budget'):
            outcome['aggregateWarningSeconds'] = args.resource_budget.warning_seconds
        child_cleanup_complete = finish_child_cleanup(
            runner, run_manifest, workspace, run_invoked, args, outcome, errors)
        if daemon_authority is not None:
            try:
                check(child_cleanup_complete, 'unresolved child cleanup; preserve owned leases and daemon for recovery')
                # Recovers unknown acquire outcomes by exact run labels and owner/spec tuple only.
                candidates = protocol(runner, daemon_authority, 'lease.list', {'labels': {'project': 'farside-parallel-stub', 'run': args.run_id}})['leases']
                outcome['cleanupCandidates'] = candidates
                for lease in candidates:
                    lease_matches(lease, args, sessions)
                    fresh = protocol(runner, daemon_authority, 'lease.get', {'id': lease['id']})['lease']
                    lease_matches(fresh, args, sessions)
                    check(fresh['id'] == lease['id'] and fresh['owner'] == lease['owner'], 'lease ownership changed before release')
                    lease = fresh
                    if lease['state'] not in ('released', 'cancelled', 'failed', 'reclaimed'):
                        released = protocol(runner, daemon_authority, 'lease.release', {'id': lease['id']}, timeout=45)['lease']
                        check(released['id'] == lease['id'] and released['state'] in ('released', 'cancelled'), 'release result mismatch')
                owned_udids = {lease['device']['udid'] for lease in candidates if lease.get('device')}
                gone_deadline = time.monotonic() + 30
                remaining = devices()
                while owned_udids.intersection(remaining) and time.monotonic() < gone_deadline:
                    time.sleep(0.5); remaining = devices()
                check(not owned_udids.intersection(remaining), 'owned clone cleanup failed (reaper is best-effort)')
                check(not acquire_outcome_unknown, 'acquire outcome unknown; leave owned daemon for TTL/PID recovery')
                outcome['releasedOwnedUDIDs'] = sorted(owned_udids)
                runner.validate_daemon(daemon_authority)
                daemon.terminate()
                daemon.wait(timeout=15)
                outcome['ownedDaemonStopped'] = True
            except Exception as error:
                errors.append('lease/daemon cleanup: ' + str(error))
                # Keep verified owned daemon alive for TTL/reaper recovery; never stop a replacement.
                outcome['ownedDaemonStopped'] = daemon.poll() is not None if daemon else False
                outcome['recoveryAuthority'] = daemon_authority
        elif daemon is not None and daemon.poll() is None:
            # Only this unreaped Popen child; initial identity failure cannot authorize other signals.
            try: daemon.terminate(); daemon.wait(timeout=10)
            except Exception as error: errors.append('initial daemon cleanup: ' + str(error))
        outcome.update(finishedAt=time.time(), errors=errors, status='failed' if errors else outcome['status'])
        runner.write_json(workspace / 'parent-runtime-receipt.json', outcome)
    check(not errors, '; '.join(errors))
    print(workspace / 'parent-runtime-receipt.json')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repo', 'run-id', 'simurgh-source-binary', 'simurgh-parent', 'workspace-parent', 'products-root',
                 'xctestrun', 'stub-app', 'source-build-receipt', 'coordination-receipt'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--runtime', default='27.0')
    parser.add_argument('--runtime-library-root', action='append', default=[])
    parser.add_argument('--allow-foreign-booted', action='append', default=[])
    parser.add_argument('--execute', action='store_true')
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError('SIGTERM')))
    try: main(parser.parse_args())
    except (Exception, KeyboardInterrupt) as error:
        print('FAILED/REFUSED: ' + str(error), file=sys.stderr); sys.exit(1)
