#!/usr/bin/env python3
"""Parent-provisioned, DEBUG native stub lanes. No build/device/daemon lifecycle CLI."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid

BASE = Path('/private/tmp/farside-e2e')
REPO = Path(__file__).resolve().parents[2]
BATCH_SECONDS = 420
CLEANUP_SECONDS = 60
SELECTOR = 'RemoteE2ETests/ParallelStubE2ETests/test_parallel_IsolatedStubSmoke'
IDENTIFIER = re.compile(r'[A-Za-z0-9_-]{1,64}\Z')


class Refused(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def absolute(path):
    value = Path(path)
    require(value.is_absolute() and str(value) == os.path.normpath(str(value)), 'exact absolute path required')
    return value


def owned(path, kind, mode=None):
    info = path.lstat()
    require(info.st_uid == os.getuid() and kind(info.st_mode), f'wrong owner/type: {path}')
    if mode is not None:
        require(stat.S_IMODE(info.st_mode) == mode, f'wrong private mode: {path}')
    return info


def private_chain(path):
    path = absolute(path)
    for item in reversed((path, *path.parents)):
        require(not item.is_symlink(), f'symlink ancestry: {item}')
        info = item.lstat()
        require(stat.S_ISDIR(info.st_mode), f'not a directory: {item}')
        if item == path or item == BASE or BASE in item.parents:
            owned(item, stat.S_ISDIR, 0o700)
        elif item not in (Path('/private/tmp'),):
            require(stat.S_IMODE(info.st_mode) & 0o022 == 0, f'writable ancestry: {item}')
    return path


def read_json(path):
    path = absolute(path)
    flags = os.O_RDONLY | os.O_NOFOLLOW
    fd = os.open(path, flags)
    with os.fdopen(fd, 'rb') as handle:
        info = os.fstat(handle.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and 0 < info.st_size <= 1024 * 1024,
                f'unsafe JSON file: {path}')
        return json.load(handle)


def write_json(path, value):
    private_chain(path.parent)
    temporary = path.parent / ('.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, sort_keys=True)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def mkdir_private(path):
    require(not path.exists() and not path.is_symlink(), f'new directory required: {path}')
    path.mkdir(mode=0o700)
    private_chain(path)


def sha256(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def tree_hash(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        digest.update(str(path.relative_to(root)).encode() + b'\0')
        if path.is_symlink():
            require(inside(path, root), f'bundle link escaped product: {path}')
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            digest.update(sha256(path).encode())
    return digest.hexdigest()


def admit_bundle(bundle, expected_id, platform, hooks=False):
    info_path = bundle / ('Contents/Info.plist' if platform == 'MACOS' else 'Info.plist')
    with info_path.open('rb') as handle:
        info = plistlib.load(handle)
    require(info['CFBundleIdentifier'] == expected_id, f'unexpected bundle ID: {bundle}')
    executable = bundle / ('Contents/MacOS' if platform == 'MACOS' else '') / info['CFBundleExecutable']
    require(executable.is_file() and inside(executable, bundle), 'missing/escaped executable')
    architectures = subprocess.check_output(['/usr/bin/xcrun', 'lipo', '-archs', str(executable)], text=True).split()
    require('arm64' in architectures, 'arm64 executable required')
    build = subprocess.check_output(['/usr/bin/xcrun', 'vtool', '-show-build', str(executable)], text=True)
    platforms = re.findall(r'^\s*platform\s+(\S+)', build, re.MULTILINE)
    require(platforms and all(value == platform for value in platforms), 'wrong Mach-O platform')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)], check=True, capture_output=True)
    if hooks:
        require(any(b'FARSIDE_E2E_LANE_MANIFEST' in file.read_bytes() for file in
                    (executable, Path(str(executable) + '.debug.dylib')) if file.is_file()), 'DEBUG lane admission hook missing')
    return {'bundleID': info['CFBundleIdentifier'], 'executable': str(executable), 'platform': platform, 'arm64': True}


def inside(path, root):
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def validate_lane(value, now=None):
    now = time.time() if now is None else now
    run, lane = value['runID'], value['laneID']
    require(IDENTIFIER.fullmatch(run) and lane in ('phone', 'tablet'), 'invalid run/lane identifiers')
    root = BASE / 'parallel' / run / lane
    require(value['schemaVersion'] == 1 and value['mode'] == 'stub' and value['root'] == str(root)
            and value['ownerUID'] == os.getuid(), 'lane schema/identity mismatch')
    private_chain(root)
    require(IDENTIFIER.fullmatch(value['leaseID']) and IDENTIFIER.fullmatch(value['sessionID']), 'invalid lease/session')
    uuid.UUID(value['udid'])
    require(value['createdAt'] <= now + 5 < value['expiresAt']
            and 0 < value['expiresAt'] - value['createdAt'] <= 3600, 'lane manifest expired or invalid')
    require(re.fullmatch(r'ws://127\.0\.0\.1:18(?:79\d|8\d\d)/signal', value['signalURL']), 'invalid loopback lane URL')
    for suffix in ('run', 'host', 'phone', 'stubhost', 'secrets', 'run/requests', 'run/responses', 'run/results'):
        private_chain(root / suffix)
    return root


def process_identity(pid):
    completed = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=', '-o', 'command='],
                               check=True, capture_output=True, text=True)
    require(completed.stdout.strip(), f'process {pid} absent')
    return ' '.join(completed.stdout.split())


def validate_daemon(manifest):
    home = private_chain(Path(manifest['simurghHome']))
    require(process_identity(manifest['daemonPID']) == manifest['daemonIdentity'], 'daemon identity changed')
    images = subprocess.check_output(['/usr/sbin/lsof', '-a', '-p', str(manifest['daemonPID']), '-d', 'txt', '-Fn'], text=True)
    actual_images = [line[1:] for line in images.splitlines() if line.startswith('n')]
    require(actual_images and actual_images[0] == manifest['simurghBinary'], 'daemon main executable differs from pinned binary')
    pinned_binary(manifest)
    sock = home / 'simurghd.sock'
    info = owned(sock, stat.S_ISSOCK, 0o600)
    if 'socketIdentity' in manifest:
        require(manifest['socketIdentity'] == {'dev': info.st_dev, 'ino': info.st_ino, 'uid': info.st_uid}, 'daemon socket replaced')
    return sock


def rpc(manifest, method, parameters):
    """Direct protocol-v1 only. A dead daemon is an error, never an autostart opportunity."""
    require(method in ('lease.get', 'lease.renew'), 'non-allowlisted lease RPC')
    sock = validate_daemon(manifest)
    request_id = uuid.uuid4().hex
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(3)
        client.connect(str(sock))
        client.sendall(json.dumps({'v': 1, 'id': request_id, 'method': method, 'params': parameters}).encode() + b'\n')
        response = bytearray()
        while b'\n' not in response:
            chunk = client.recv(65536)
            require(chunk, 'daemon disconnected')
            response.extend(chunk)
            require(len(response) <= 1024 * 1024, 'oversized daemon response')
    result = json.loads(response.split(b'\n', 1)[0])
    require(result.get('v') == 1 and result.get('id') == request_id and result.get('ok') is True,
            f'lease RPC failed: {result.get("error", {}).get("code", "invalid response")}')
    return result['result']['lease']


def expiry(lease):
    return dt.datetime.fromisoformat(lease['expiresAt'].replace('Z', '+00:00')).timestamp()


def validate_lease(lease, expected=None):
    require(lease['state'] == 'active' and lease['device']['booted'] is True, 'lease must be active and booted')
    require(IDENTIFIER.fullmatch(lease['id']) and IDENTIFIER.fullmatch(lease['owner']['sessionId']), 'lease identity invalid')
    uuid.UUID(lease['device']['udid'])
    env = lease['env']['env']
    require(env['SIMURGH_LEASE_ID'] == lease['id'] and env['SIMURGH_UDID'] == lease['device']['udid'], 'lease env identity')
    roots = [absolute(env[key]) for key in ('SIMURGH_DERIVED_DATA', 'SIMURGH_SWIFTPM_DIR',
                                           'SIMURGH_RESULT_BUNDLE_DIR', 'CLANG_MODULE_CACHE_PATH')]
    root = roots[0].parent
    private_chain(root)
    for path in roots:
        private_chain(path)
        require(inside(path, root) and path != root, 'cache escaped lease')
    require(len(set(roots)) == len(roots), 'shared cache paths')
    if expected:
        require(lease['id'] == expected['id'] and lease['owner'] == expected['owner']
                and lease['spec'] == expected['spec'] and lease['device'] == expected['device']
                and lease['env'] == expected['env'] and lease['acquiredAt'] == expected['acquiredAt']
                and lease['releaseOnPIDExit'] == expected['releaseOnPIDExit'],
                'live lease ownership/env drift')
        # Only expiry/heartbeat and the documented 15-minute renewal TTL may change.
        require(lease['ttl'] in (expected['ttl'], '15m0s', '15m'), 'unexpected renewal TTL')
        require(expiry(lease) <= time.time() + 3605, 'lease expiry exceeds one-hour policy')
    return root


def test_targets(value):
    version = value.get('__xctestrun_metadata__', {}).get('FormatVersion', 1)
    if version == 1:
        return [target for name, target in value.items() if not name.startswith('__') and isinstance(target, dict)]
    require(version == 2, 'unsupported xctestrun format')
    return [target for configuration in value['TestConfigurations'] for target in configuration['TestTargets']]


def validate_products(path, derived, developer, runtime_roots=()):
    path, derived, developer = absolute(path), absolute(derived), absolute(developer)
    root = derived / 'Build' / 'Products'
    require(inside(path, root) and path.is_file() and not path.is_symlink(), 'xctestrun outside lane products')
    with path.open('rb') as handle:
        value = plistlib.load(handle)
    targets = test_targets(value)
    require(len(targets) == 1, 'one UI target required')
    target = targets[0]
    require(target.get('BlueprintName', 'RemoteE2ETests') == 'RemoteE2ETests', 'unexpected UI target')
    host = target['TestHostPath'].replace('__TESTROOT__', str(root))
    bundle = target['TestBundlePath'].replace('__TESTROOT__', str(root)).replace('__TESTHOST__', host)
    replacements = {'__TESTROOT__': str(root), '__TESTHOST__': host, '__TESTBUNDLE__': bundle,
                    '__PLATFORMS__': str(developer / 'Platforms'), '__DEVELOPER_DIR__': str(developer)}

    def expand(raw):
        for _ in range(4):
            old = raw
            for key, replacement in replacements.items():
                raw = raw.replace(key, replacement)
            if raw == old:
                break
        require('__' not in raw, f'unresolved product placeholder: {raw}')
        return raw

    references = []
    for key in ('TestHostPath', 'TestBundlePath', 'UITargetAppPath', 'DependentProductPaths'):
        raw = target.get(key, [])
        for item in raw if isinstance(raw, list) else [raw]:
            resolved = absolute(expand(item))
            require(resolved.exists() and inside(resolved, root), f'product escaped/missing: {resolved}')
            references.append(str(resolved))
    require(all(key in target for key in ('TestHostPath', 'TestBundlePath', 'UITargetAppPath')), 'incomplete UI products')
    # Xcode library paths are read-only platform references; application/test products cannot use this exception.
    for section in ('EnvironmentVariables', 'TestingEnvironmentVariables'):
        for key, raw in target.get(section, {}).items():
            if key.startswith('DYLD_'):
                for item in expand(raw).split(':'):
                    resolved = absolute(item)
                    require(resolved.exists() and (inside(resolved, root) or inside(resolved, developer)
                            or inside(resolved, Path('/usr/lib'))
                            or any(inside(resolved, Path(runtime)) for runtime in runtime_roots)),
                            f'untrusted library path: {resolved}')
            require(not key.startswith('FARSIDE_') and key != 'SIMULATOR_UDID', 'xctestrun cannot inject lane/OS identity')
    admission = [admit_bundle(Path(expand(target['UITargetAppPath'])), 'com.roshan.PocketDesk.Remote', 'IOSSIMULATOR', hooks=True),
                 admit_bundle(Path(expand(target['TestHostPath'])), 'com.roshan.RemoteE2ETests.xctrunner', 'IOSSIMULATOR'),
                 admit_bundle(Path(expand(target['TestBundlePath'])), 'com.roshan.RemoteE2ETests', 'IOSSIMULATOR', hooks=True)]
    return {'sha256': sha256(path), 'products': references, 'closureSHA256': tree_hash(root), 'admission': admission}


def pinned_binary(manifest):
    binary = absolute(manifest['simurghBinary'])
    owned(binary, stat.S_ISREG)
    require(not binary.is_symlink() and sha256(binary) == manifest['simurghSHA256'], 'pinned binary changed')


def validate_run(path, live=False):
    path = absolute(path)
    private_chain(path.parent)
    manifest = read_json(path)
    require(path == BASE / 'parallel' / manifest['runID'] / 'run-manifest.json', 'run manifest path mismatch')
    require(manifest['schemaVersion'] == 1 and manifest['ownerUID'] == os.getuid(), 'run schema/owner')
    actual_revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
    require(actual_revision == manifest['sourceRevision'], 'source revision changed since preparation')
    require(sha256(Path(manifest['buildReceipt'])) == manifest['buildReceiptSHA256'], 'external build receipt changed')
    for runtime in manifest.get('runtimeRoots', []):
        runtime = absolute(runtime)
        require(str(runtime).startswith('/Library/Developer/CoreSimulator/Volumes/')
                and runtime.is_dir() and not runtime.is_symlink(), 'invalid pinned runtime library root')
    pinned_binary(manifest)
    roots, udids, leases, sessions, ports, cache_roots = set(), set(), set(), set(), set(), set()
    require(len(manifest['lanes']) == 2, 'exactly two lanes required')
    for lane in manifest['lanes']:
        value = read_json(Path(lane['manifest']))
        root = validate_lane(value)
        require(value['runID'] == manifest['runID'], 'foreign lane run')
        roots.add(root); udids.add(value['udid']); leases.add(value['leaseID']); sessions.add(value['sessionID']); ports.add(value['signalURL'])
        lease_root = validate_lease(lane['lease'])
        cache_roots.add(lease_root)
        require(inside(lease_root, Path(manifest['simurghHome']) / 'leases') and lease_root.name == value['leaseID'], 'foreign lease path')
        require(lane['lease']['id'] == value['leaseID'] and lane['lease']['device']['udid'] == value['udid']
                and lane['lease']['owner']['sessionId'] == value['sessionID'], 'lane/lease identity mismatch')
        proof = validate_products(lane['xctestrun'], lane['lease']['env']['env']['SIMURGH_DERIVED_DATA'], manifest['developerDir'], manifest.get('runtimeRoots', []))
        require(proof == lane['products'], 'product provenance drift')
        if live:
            fresh = rpc(manifest, 'lease.get', {'id': value['leaseID']})
            validate_lease(fresh, lane['lease'])
            require(expiry(fresh) > time.time() + BATCH_SECONDS + CLEANUP_SECONDS, 'insufficient lease TTL for full batch')
    require(all(len(values) == 2 for values in (roots, udids, leases, sessions, ports, cache_roots)), 'lanes share resources')
    require(sha256(Path(manifest['stubExecutable'])) == manifest['stubSHA256'], 'stub executable changed')
    require(tree_hash(Path(manifest['stubApp'])) == manifest['stubClosureSHA256'], 'stub bundle changed')
    admit_bundle(Path(manifest['stubApp']), 'com.roshan.PocketDesk.E2EStubHost', 'MACOS', hooks=True)
    private_chain(Path(manifest['artifactDir']))
    return manifest


def prepare(args):
    require(IDENTIFIER.fullmatch(args.run_id), 'invalid run ID')
    for path in (BASE, BASE / 'parallel'):
        if not path.exists():
            path.mkdir(mode=0o700)
        private_chain(path)
    run_root = BASE / 'parallel' / args.run_id
    mkdir_private(run_root)
    artifact = absolute(args.artifact_dir)
    # Parent creates the private artifact parent; never chmod/reuse a supplied folder.
    private_chain(artifact.parent)
    mkdir_private(artifact)
    stub_app = absolute(args.stub_app)
    with (stub_app / 'Contents' / 'Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    require(info['CFBundleIdentifier'] == 'com.roshan.PocketDesk.E2EStubHost', 'only stub app permitted')
    stub = stub_app / 'Contents' / 'MacOS' / info['CFBundleExecutable']
    require(stub.is_file() and not stub.is_symlink(), 'stub executable required')
    hook_binaries = [stub, Path(str(stub) + '.debug.dylib')]
    require(any(b'FARSIDE_E2E_LANE_MANIFEST' in p.read_bytes() for p in hook_binaries if p.is_file()), 'DEBUG lane hook absent')
    developer = subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip()
    manifest = {'schemaVersion': 1, 'ownerUID': os.getuid(), 'runID': args.run_id,
                'simurghBinary': str(absolute(args.simurgh)), 'simurghSHA256': args.simurgh_sha256,
                'simurghHome': str(absolute(args.simurgh_home)), 'daemonPID': args.daemon_pid,
                'daemonIdentity': args.daemon_identity, 'developerDir': developer,
                'stubExecutable': str(stub), 'stubSHA256': sha256(stub), 'stubApp': str(stub_app),
                'stubClosureSHA256': tree_hash(stub_app), 'artifactDir': str(artifact),
                'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
                'runtimeRoots': args.runtime_library_root,
                'lanes': []}
    pinned_binary(manifest)
    socket_info = validate_daemon(manifest).lstat()
    manifest['socketIdentity'] = {'dev': socket_info.st_dev, 'ino': socket_info.st_ino, 'uid': socket_info.st_uid}
    available_ports = []
    for port in range(18790, 18900):
        with socket.socket() as probe:
            try:
                probe.bind(('127.0.0.1', port))
                available_ports.append(port)
            except OSError:
                continue
        if len(available_ports) == 2:
            break
    require(len(available_ports) == 2, 'no free lane ports')
    now = time.time()
    for index, (lane_id, receipt, xctestrun) in enumerate((('phone', args.lane_a_lease_json, args.lane_a_xctestrun),
                                                        ('tablet', args.lane_b_lease_json, args.lane_b_xctestrun))):
        supplied = read_json(absolute(receipt))
        lease = supplied.get('lease', supplied)
        validate_lease(lease)
        fresh = rpc(manifest, 'lease.get', {'id': lease['id']})
        validate_lease(fresh, lease)
        require(expiry(fresh) > now + BATCH_SECONDS + CLEANUP_SECONDS, 'lease TTL too short')
        root = run_root / lane_id
        mkdir_private(root)
        for suffix in ('host', 'phone', 'stubhost', 'secrets', 'run', 'run/requests', 'run/responses', 'run/results', 'run/requests-done'):
            mkdir_private(root / suffix)
        value = {'schemaVersion': 1, 'mode': 'stub', 'runID': args.run_id, 'laneID': lane_id,
                 'root': str(root), 'ownerUID': os.getuid(), 'leaseID': lease['id'], 'udid': lease['device']['udid'],
                 'sessionID': lease['owner']['sessionId'], 'signalURL': f'ws://127.0.0.1:{available_ports[index]}/signal',
                 'createdAt': now, 'expiresAt': now + 1800}
        write_json(root / 'lane.json', value)
        write_json(root / 'run/config.json', {**value, 'soakSeconds': 10})
        write_json(root / 'testpad-state.json', {'synthetic': True, 'run': args.run_id, 'lane': lane_id,
                   'contentFrame': {'x': 0, 'y': 0, 'width': 1280, 'height': 720},
                   'elements': {'A': {'x': 600, 'y': 320, 'width': 80, 'height': 80}}})
        products = validate_products(xctestrun, lease['env']['env']['SIMURGH_DERIVED_DATA'], developer, manifest['runtimeRoots'])
        manifest['lanes'].append({'manifest': str(root / 'lane.json'), 'lease': lease,
                                  'xctestrun': str(absolute(xctestrun)), 'products': products})
    path = run_root / 'run-manifest.json'
    build_receipt_path = absolute(args.build_receipt)
    build_receipt = read_json(build_receipt_path)
    require(build_receipt['sourceRevision'] == manifest['sourceRevision']
            and build_receipt['stubClosureSHA256'] == manifest['stubClosureSHA256']
            and build_receipt['laneClosureSHA256'] == [lane['products']['closureSHA256'] for lane in manifest['lanes']],
            'external parent build receipt does not match source/product closure')
    require(build_receipt.get('buildsPassed') is True and build_receipt.get('xcodeVersion'), 'parent build evidence incomplete')
    manifest['buildReceipt'] = str(build_receipt_path)
    manifest['buildReceiptSHA256'] = sha256(build_receipt_path)
    write_json(path, manifest)
    validate_run(path, live=True)
    print(path)


def test_command(manifest, lane, result):
    env = lane['lease']['env']['env']
    return ['/usr/bin/xcodebuild', 'test-without-building', '-xctestrun', lane['xctestrun'],
            '-destination', 'id=' + lane['lease']['device']['udid'],
            '-derivedDataPath', env['SIMURGH_DERIVED_DATA'], '-clonedSourcePackagesDirPath', env['SIMURGH_SWIFTPM_DIR'],
            '-resultBundlePath', str(result), '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
            '-only-testing:' + SELECTOR]


def lane_environment(lane):
    value = read_json(Path(lane['manifest']))
    # Deliberately no SIMULATOR_UDID; CoreSimulator must provide it inside each runner/AUT.
    env = {key: val for key, val in os.environ.items() if key in ('PATH', 'HOME', 'USER', 'LOGNAME', 'LANG')}
    env.update(lane['lease']['env']['env'])
    env['SIMURGH_SESSION_ID'] = value['sessionID']
    env['TMPDIR'] = str(Path(env['SIMURGH_DERIVED_DATA']).parent / 'tmp')
    env['SWIFT_MODULE_CACHE_PATH'] = str(Path(env['SIMURGH_DERIVED_DATA']).parent / 'ModuleCache')
    for key, val in {'FARSIDE_E2E': '1', 'FARSIDE_E2E_DIR': value['root'], 'FARSIDE_E2E_RUN_ID': value['runID'],
                     'FARSIDE_E2E_SIGNAL_URL': value['signalURL'], 'FARSIDE_E2E_LANE_MANIFEST': lane['manifest'],
                     'FARSIDE_E2E_CONFIG': value['root'] + '/run/config.json'}.items():
        env['TEST_RUNNER_' + key] = val
    require('SIMULATOR_UDID' not in env, 'OS identity injection prohibited')
    return env


class Children:
    def __init__(self, record, authority_path=None, authority=None):
        self.record, self.items = record, []
        self.authority_path, self.authority = authority_path, authority

    def persist(self):
        write_json(self.record, [value for _, value in self.items])
        if self.authority_path is not None:
            self.authority['ownershipSHA256'] = sha256(self.record)
            write_json(self.authority_path, self.authority)

    def start(self, role, command, environment, log):
        handle = open(log, 'xb')
        os.chmod(log, 0o600)
        child = subprocess.Popen(command, env=environment, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        handle.close()
        item = {'role': role, 'pid': child.pid, 'identity': None, 'command': command, 'startedAt': time.time(), 'members': {}}
        self.items.append((child, item))
        try:
            item['identity'] = process_identity(child.pid)
            self.observe()
        except BaseException:
            # An unreaped live Popen child cannot have its PID reused. Track it first, then
            # stop this direct child through its Popen handle if initial identity capture fails.
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=10)
            raise
        self.persist()
        return child

    def observe(self):
        for _, item in self.items:
            members = group_members(item['pid'])
            validate_members(item, members, discover=True)
        self.persist()

    def stop(self):
        results = []
        for child, value in reversed(self.items):
            try:
                stop_group(value)
                child.poll()
                results.append({'role': value['role'], 'stopped': not group_members(value['pid'])})
            except Exception as error:
                results.append({'role': value['role'], 'stopped': False, 'failure': str(error)})
        return results


def group_members(group):
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat=,lstart=,command='], text=True)
    members = {}
    for line in output.splitlines():
        fields = line.split(maxsplit=9)
        if len(fields) == 10 and int(fields[2]) == group and not fields[3].startswith('Z'):
            members[str(int(fields[0]))] = {'ppid': int(fields[1]), 'identity': ' '.join(' '.join(fields[4:]).split()), 'group': group}
    return members


def validate_members(item, members, discover=False):
    known = item.setdefault('members', {})
    pending = dict(members)
    for pid, current in list(pending.items()):
        if pid in known:
            require(current['identity'] == known[pid]['identity'], 'group member PID reused/drifted')
            pending.pop(pid)
    if str(item['pid']) in pending:
        leader = pending.pop(str(item['pid']))
        require(leader['identity'] == item['identity'], 'group leader identity drift')
        known[str(item['pid'])] = leader
    if discover:
        while pending:
            progress = False
            for pid, current in list(pending.items()):
                if str(current['ppid']) in known:
                    known[pid] = current; pending.pop(pid); progress = True
            require(progress, 'unproven process-group member ancestry; refusing signal')
    require(not pending, 'unrecorded group member; refusing signal')


def stop_group(item):
    members = group_members(item['pid'])
    validate_members(item, members, discover=True)
    if not members:
        return
    os.killpg(item['pid'], signal.SIGTERM)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and group_members(item['pid']):
        time.sleep(0.1)
    remaining = group_members(item['pid'])
    if remaining:
        validate_members(item, remaining)
        os.killpg(item['pid'], signal.SIGKILL)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and group_members(item['pid']):
            time.sleep(0.1)
    require(not group_members(item['pid']), 'owned process descendants remain after bounded cleanup')


def counters(root):
    state = read_json(root / 'host/state.json')
    return tuple(state.get('inputAccepted', {}).get(name, 0) for name in ('click', 'key'))


class Barrier:
    def __init__(self, roots):
        self.roots, self.ready, self.done, self.baseline = roots, {}, {}, None
        self.controls = []

    def reply(self, lane, request, **extra):
        write_json(self.roots[lane] / 'run/responses' / (request['id'] + '.json'),
                   {'ok': True, 'id': request['id'], **extra})

    def accept(self, lane, request):
        require(request.get('laneID') == lane, 'request lane mismatch')
        if request['action'] == 'parallel.ready':
            require(lane not in self.ready, 'duplicate ready')
            self.ready[lane] = request
            if len(self.ready) == 2:
                self.baseline = {name: counters(root) for name, root in self.roots.items()}
                self.reply('phone', self.ready['phone'])
        elif request['action'] == 'parallel.actionDone':
            require(self.baseline is not None and lane not in self.done, 'unexpected actionDone')
            require(lane == ('phone' if not self.done else 'tablet'), 'out-of-order virtual input')
            other = 'tablet' if lane == 'phone' else 'phone'
            active, idle = counters(self.roots[lane]), counters(self.roots[other])
            require(all(after > before for after, before in zip(active, self.baseline[lane])), 'active lane input did not advance')
            require(idle == self.baseline[other], 'cross-lane input contamination')
            self.controls.append({'activeLane': lane, 'idleLane': other, 'before': self.baseline,
                                  'after': {lane: active, other: idle}, 'passed': True})
            self.done[lane] = request
            self.baseline = {name: counters(root) for name, root in self.roots.items()}
            if lane == 'phone':
                self.reply('tablet', self.ready['tablet'])
            else:
                for name, pending in self.done.items():
                    self.reply(name, pending, negativeControlsPassed=True)
        else:
            raise Refused('non-allowlisted parallel harness action')


def service_owns_port(pid, port):
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-iTCP:' + str(port), '-sTCP:LISTEN'],
                            capture_output=True, text=True)
    return result.returncode == 0 and '127.0.0.1:' + str(port) in result.stdout


def create_pairing_token(root):
    private_chain(root / 'secrets')
    fd = os.open(root / 'secrets/pairing-token', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as handle:
        handle.write(secrets.token_hex(32) + '\n')


def run_batch(path):
    manifest = validate_run(path, live=True)
    roots = {read_json(Path(lane['manifest']))['laneID']: Path(lane['manifest']).parent for lane in manifest['lanes']}
    artifact = Path(manifest['artifactDir'])
    require(not (artifact / 'ownership.json').exists(), 'run cannot reuse an artifact/process record')
    children = Children(artifact / 'ownership.json', Path(path), manifest)
    barrier = Barrier(roots)
    tests, locks, results, failure = [], [], [], None
    deadline, next_renewal = time.monotonic() + BATCH_SECONDS, time.monotonic()
    bun = shutil.which('bun')
    require(bun is not None, 'bun unavailable')
    source_dirty = subprocess.check_output(['git', 'status', '--porcelain'], cwd=REPO, text=True)
    require(not source_dirty.strip(), 'commit source before a runtime receipt')
    receipt = {'runID': manifest['runID'], 'sourceRevision': manifest['sourceRevision'], 'startedAt': time.time(), 'status': 'failed'}
    try:
        # No pairing secrets exist during preparation. Allocation is guarded by this run's
        # finally, including a failure while allocating the second lane before any launch.
        for root in roots.values():
            create_pairing_token(root)
        for lane in manifest['lanes']:
            value = read_json(Path(lane['manifest'])); lane_id = value['laneID']; root = roots[lane_id]
            lock = open(root / 'run/execution.lock', 'x'); os.chmod(lock.name, 0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB); locks.append(lock)
            port = int(value['signalURL'].split(':')[2].split('/')[0])
            service_env = {'PATH': '/usr/bin:/bin', 'HOME': os.environ['HOME'], 'PORT': str(port), 'BIND': '127.0.0.1',
                           'CONNECTION_ATTEMPTS_PER_MINUTE': '600'}
            service = children.start(lane_id + '.service', [bun, str(REPO / 'Server/src/index.ts'), '--farside-lane', manifest['runID'], lane_id],
                                     service_env, artifact / (lane_id + '-service.log'))
            ready_deadline = time.monotonic() + 20
            while service.poll() is None and time.monotonic() < ready_deadline and not service_owns_port(service.pid, port):
                time.sleep(0.2)
            require(service.poll() is None and service_owns_port(service.pid, port), 'owned loopback service did not bind')
            env = {key: val for key, val in os.environ.items() if key in ('PATH', 'HOME', 'USER', 'LOGNAME', 'LANG')}
            env.update({'FARSIDE_E2E': '1', 'FARSIDE_E2E_DIR': str(root), 'FARSIDE_E2E_RUN_ID': value['runID'],
                        'FARSIDE_E2E_SIGNAL_URL': value['signalURL'], 'FARSIDE_E2E_LANE_MANIFEST': lane['manifest'],
                        'FARSIDE_E2E_LAUNCH_ID': value['runID'] + '-' + lane_id})
            children.start(lane_id + '.stub', [manifest['stubExecutable'], '--farside-e2e'], env, artifact / (lane_id + '-stub.log'))
        # Start both no-build jobs before waiting for either. Inner Xcode parallelism is disabled.
        for lane in manifest['lanes']:
            lane_id = read_json(Path(lane['manifest']))['laneID']
            result = Path(lane['lease']['env']['env']['SIMURGH_RESULT_BUNDLE_DIR']) / ('farside-' + manifest['runID'] + '.xcresult')
            require(not result.exists(), 'result bundle must be new')
            results.append((lane_id, result))
            tests.append(children.start(lane_id + '.test', test_command(manifest, lane, result), lane_environment(lane),
                                         artifact / (lane_id + '-xcodebuild.log')))
        seen = set()
        while any(child.poll() is None for child in tests):
            require(time.monotonic() < deadline, 'bounded batch deadline exceeded')
            validate_daemon(manifest)
            children.observe()
            if time.monotonic() >= next_renewal:
                for lane in manifest['lanes']:
                    fresh = rpc(manifest, 'lease.renew', {'id': lane['lease']['id'], 'ttl': '15m'})
                    validate_lease(fresh, lane['lease'])
                    require(expiry(fresh) > time.time() + BATCH_SECONDS + CLEANUP_SECONDS, 'renewed lease TTL insufficient')
                next_renewal = time.monotonic() + 30
            for lane_id, root in roots.items():
                for request_path in sorted((root / 'run/requests').glob('*.json')):
                    if request_path in seen:
                        continue
                    request = read_json(request_path)
                    require(re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', request['id']) and request_path.name == request['id'] + '.json', 'unsafe request identity')
                    if request['action'] == 'phone.terminate':
                        # UI launchPhone requests this before launch; target only this owned clone.
                        lane = next(item for item in manifest['lanes'] if Path(item['manifest']).parent == root)
                        subprocess.run(['/usr/bin/xcrun', 'simctl', 'terminate', lane['lease']['device']['udid'], 'com.roshan.PocketDesk.Remote'],
                                       capture_output=True, timeout=10)
                        write_json(root / 'run/responses' / request_path.name, {'ok': True, 'id': request['id']})
                    else:
                        barrier.accept(lane_id, request)
                    seen.add(request_path)
            for child in tests:
                require(child.poll() in (None, 0), 'a lane XCTest failed')
            time.sleep(0.2)
        require(all(child.returncode == 0 for child in tests) and len(barrier.controls) == 2, 'two lanes/controls did not pass')
        summaries = {}
        for lane_id, root in roots.items():
            summary = read_json(root / 'run/results/parallel.json')
            require(summary['status'] == 'passed' and summary['checks'] and all(check['ok'] for check in summary['checks']), 'lane assertion receipt failed')
            summaries[lane_id] = summary
        intervals = [(summary['startedAt'], summary['startedAt'] + summary['durationSeconds']) for summary in summaries.values()]
        overlap = min(end for _, end in intervals) - max(start for start, _ in intervals)
        require(overlap > 0, 'actual XCTest intervals did not overlap')
        receipt.update(status='passed', overlapSeconds=overlap, laneResults=summaries, negativeControls=barrier.controls)
    except BaseException as error:
        failure = error
        receipt['failure'] = str(error)
    finally:
        receipt['finishedAt'] = time.time()
        # Cleanup cannot be skipped by an artifact export failure. Every phase is guarded.
        try:
            receipt['cleanup'] = children.stop()
            require(all(item['stopped'] for item in receipt['cleanup']), 'owned group cleanup incomplete')
        except Exception as error:
            receipt['cleanupFailure'] = str(error); failure = failure or error; receipt['status'] = 'failed'
        for lane_id, result in results:
            try:
                if result.exists():
                    shutil.copytree(result, artifact / (lane_id + '.xcresult'), symlinks=True)
            except Exception as error:
                receipt.setdefault('artifactFailures', []).append(str(error))
                failure = failure or error; receipt['status'] = 'failed'
        for root in roots.values():
            try:
                private_chain(root / 'secrets')
                for leaf in ('pairing-token', 'invitation.code'):
                    (root / 'secrets' / leaf).unlink(missing_ok=True)
            except Exception as error:
                receipt.setdefault('secretCleanupFailures', []).append(str(error)); failure = failure or error
                receipt['status'] = 'failed'
        for lock in locks:
            try: lock.close()
            except Exception as error:
                receipt.setdefault('lockCleanupFailures', []).append(str(error)); failure = failure or error
                receipt['status'] = 'failed'
        write_json(artifact / 'receipt.json', receipt)
    if failure:
        raise failure
    print(artifact / 'receipt.json')


def cleanup(path):
    # Stable ownership authority, deliberately independent of source/build/TTL freshness.
    path = absolute(path)
    private_chain(path.parent)
    manifest = read_json(path)
    require(manifest['schemaVersion'] == 1 and manifest['ownerUID'] == os.getuid()
            and IDENTIFIER.fullmatch(manifest['runID'])
            and path == BASE / 'parallel' / manifest['runID'] / 'run-manifest.json', 'unsafe cleanup authority')
    artifact = Path(manifest['artifactDir'])
    private_chain(artifact)
    record_path = artifact / 'ownership.json'
    require(sha256(record_path) == manifest['ownershipSHA256'], 'ownership record hash differs; refusing cleanup')
    records = read_json(record_path)
    failures = []
    for item in reversed(records):
        require(item['command'][0] in (manifest['stubExecutable'], '/usr/bin/xcodebuild')
                or (item['role'].endswith('.service') and len(item['command']) > 4
                    and item['command'][1] == str(REPO / 'Server/src/index.ts')
                    and item['command'][2:4] == ['--farside-lane', manifest['runID']]), 'foreign command in cleanup authority')
        try: stop_group(item)
        except Exception as error: failures.append(str(error))
    require(not failures, '; '.join(failures))
    print('Only verified owned process groups stopped; leases/devices/daemon retained for parent cleanup.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare')
    for key in ('run-id', 'simurgh', 'simurgh-sha256', 'simurgh-home', 'daemon-identity',
                'lane-a-lease-json', 'lane-b-lease-json', 'lane-a-xctestrun', 'lane-b-xctestrun', 'stub-app', 'artifact-dir', 'build-receipt'):
        prep.add_argument('--' + key, required=True)
    prep.add_argument('--daemon-pid', required=True, type=int)
    prep.add_argument('--runtime-library-root', action='append', default=[])
    for command in ('validate', 'run', 'cleanup'):
        commands.add_parser(command).add_argument('--manifest', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError('SIGTERM')))
    try:
        if args.command == 'prepare': prepare(args)
        elif args.command == 'validate': validate_run(args.manifest); print('Manifest/products validated; no processes started.')
        elif args.command == 'run': run_batch(args.manifest)
        else: cleanup(args.manifest)
    except (Exception, KeyboardInterrupt) as error:
        print('REFUSED/FAILED: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
