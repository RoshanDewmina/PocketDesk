"""Lightweight fixtures only: no simulator, real daemon, app or Xcode launch."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import socket
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('parallel_stub', Path(__file__).with_name('parallel-stub.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        os.chmod(self.root, 0o700)
        self.real_admit = runner.admit_bundle
        self.admission_patch = patch.object(runner, 'admit_bundle', return_value={'fixture': True})
        self.admission_patch.start()

    def tearDown(self):
        self.admission_patch.stop()
        self.temporary.cleanup()

    def products(self, version=1):
        derived = self.root / 'DerivedData'
        products = derived / 'Build/Products'
        host = products / 'Debug-iphonesimulator/Runner.app'
        (host / 'PlugIns/RemoteE2ETests.xctest').mkdir(parents=True)
        (products / 'Debug-iphonesimulator/Phone.app').mkdir()
        developer = self.root / 'Xcode/Contents/Developer'
        (developer / 'Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks').mkdir(parents=True)
        target = {'BlueprintName': 'RemoteE2ETests', 'TestHostPath': '__TESTROOT__/Debug-iphonesimulator/Runner.app',
                  'TestBundlePath': '__TESTHOST__/PlugIns/RemoteE2ETests.xctest',
                  'UITargetAppPath': '__TESTROOT__/Debug-iphonesimulator/Phone.app',
                  'TestingEnvironmentVariables': {'DYLD_FRAMEWORK_PATH': '__TESTROOT__/Debug-iphonesimulator:__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks'}}
        value = {'RemoteE2ETests': target} if version == 1 else {'TestConfigurations': [{'TestTargets': [target]}]}
        value['__xctestrun_metadata__'] = {'FormatVersion': version}
        path = products / 'Farside.xctestrun'
        path.write_bytes(plistlib.dumps(value))
        return path, derived, developer, target, value

    def testV1HostRelativeAndMixedLibraryPlaceholders(self):
        path, derived, developer, _, _ = self.products()
        proof = runner.validate_products(str(path), str(derived), str(developer))
        self.assertTrue(any('/Runner.app/PlugIns/' in product for product in proof['products']))
        self.assertEqual(len(proof['closureSHA256']), 64)

    def testV2ProductsAndSiblingEscape(self):
        path, derived, developer, target, value = self.products(2)
        runner.validate_products(str(path), str(derived), str(developer))
        foreign = self.root / 'Sibling.app'; foreign.mkdir()
        target['UITargetAppPath'] = str(foreign)
        path.write_bytes(plistlib.dumps(value))
        with self.assertRaises(runner.Refused):
            runner.validate_products(str(path), str(derived), str(developer))

    def testBundleHashIncludesDebugDylibChanges(self):
        bundle = self.root / 'Stub.app'; bundle.mkdir()
        dylib = bundle / 'Stub.debug.dylib'; dylib.write_bytes(b'old')
        before = runner.tree_hash(bundle); dylib.write_bytes(b'new')
        self.assertNotEqual(before, runner.tree_hash(bundle))

    def testBinaryAdmissionRejectsDevicePlatform(self):
        bundle = self.root / 'Phone.app'; bundle.mkdir()
        (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.roshan.PocketDesk.Remote', 'CFBundleExecutable': 'Phone'}))
        (bundle / 'Phone').write_bytes(b'FARSIDE_E2E_LANE_MANIFEST')
        with patch.object(runner.subprocess, 'check_output', side_effect=['arm64\n', 'platform IOS\n']):
            with self.assertRaisesRegex(runner.Refused, 'Mach-O'):
                self.real_admit(bundle, 'com.roshan.PocketDesk.Remote', 'IOSSIMULATOR', hooks=True)

    def testSymlinkAndPublicJSONFailClosed(self):
        path = self.root / 'lane.json'; runner.write_json(path, {'test': True})
        path.chmod(0o644)
        with self.assertRaises(runner.Refused): runner.read_json(path)
        path.chmod(0o600)
        link = self.root / 'link.json'; link.symlink_to(path)
        with self.assertRaises(OSError): runner.read_json(link)

    def testCommandIsNoBuildAndDoesNotInjectOSIdentity(self):
        root = self.root / 'lane'; root.mkdir(mode=0o700)
        manifest = root / 'lane.json'
        runner.write_json(manifest, {'sessionID': 'session-a', 'root': str(root), 'runID': 'run-a', 'signalURL': 'ws://127.0.0.1:18790/signal'})
        lane = {'manifest': str(manifest), 'xctestrun': '/owned/Products/Farside.xctestrun',
                'lease': {'device': {'udid': 'owned-udid'}, 'env': {'env': {
                    'SIMURGH_DERIVED_DATA': '/owned/DerivedData', 'SIMURGH_SWIFTPM_DIR': '/owned/SwiftPM'}}}}
        command = runner.test_command({}, lane, Path('/owned/Results/fresh.xcresult'))
        self.assertEqual(command[1], 'test-without-building')
        self.assertNotIn('build', command)
        env = runner.lane_environment(lane)
        self.assertNotIn('SIMULATOR_UDID', env)
        self.assertEqual(env['TEST_RUNNER_FARSIDE_E2E_LANE_MANIFEST'], str(manifest))

    def testBothDirectionNegativeControlsAndContamination(self):
        roots = {name: self.root / name for name in ('phone', 'tablet')}
        counts = {'phone': (0, 0), 'tablet': (0, 0)}
        barrier = runner.Barrier(roots)
        replies = []
        with patch.object(runner, 'counters', side_effect=lambda root: counts[root.name]), patch.object(barrier, 'reply', side_effect=lambda *a, **k: replies.append((a, k))):
            for name in roots: barrier.accept(name, {'id': name + '-ready', 'action': 'parallel.ready', 'laneID': name})
            self.assertEqual(replies[0][0][0], 'phone')
            counts['phone'] = (1, 1)
            barrier.accept('phone', {'id': 'phone-done', 'action': 'parallel.actionDone', 'laneID': 'phone'})
            counts['tablet'] = (1, 1)
            barrier.accept('tablet', {'id': 'tablet-done', 'action': 'parallel.actionDone', 'laneID': 'tablet'})
            self.assertEqual(len(barrier.controls), 2)
            self.assertTrue(replies[-1][1]['negativeControlsPassed'])
        barrier = runner.Barrier(roots)
        counts = {'phone': (0, 0), 'tablet': (0, 0)}
        with patch.object(runner, 'counters', side_effect=lambda root: counts[root.name]), patch.object(barrier, 'reply'):
            for name in roots: barrier.accept(name, {'id': name, 'action': 'parallel.ready', 'laneID': name})
            counts.update(phone=(1, 1), tablet=(1, 0))
            with self.assertRaisesRegex(runner.Refused, 'contamination'):
                barrier.accept('phone', {'id': 'done', 'action': 'parallel.actionDone', 'laneID': 'phone'})

    def testNoAutostartOnMissingSocketAndBoundedRPC(self):
        absent = self.root / 'absent.sock'
        with patch.object(runner, 'validate_daemon', return_value=absent), patch.object(runner.subprocess, 'Popen') as start:
            with self.assertRaises(OSError): runner.rpc({}, 'lease.get', {'id': 'ours'})
            start.assert_not_called()
        path = self.root / 'fake.sock'
        server = socket.socket(socket.AF_UNIX); server.bind(str(path)); server.listen(1)
        def respond():
            connection, _ = server.accept()
            with connection:
                request = json.loads(connection.recv(4096))
                connection.sendall(json.dumps({'v': 1, 'id': request['id'], 'ok': True, 'result': {'lease': {'id': 'ours'}}}).encode() + b'\n')
        thread = threading.Thread(target=respond); thread.start()
        try:
            with patch.object(runner, 'validate_daemon', return_value=path):
                self.assertEqual(runner.rpc({}, 'lease.get', {'id': 'ours'}), {'id': 'ours'})
        finally:
            thread.join(timeout=3); server.close()

    def testCleanupRefusesPIDDriftBeforeSignal(self):
        child = unittest.mock.Mock(); child.pid = 123; child.poll.return_value = None
        children = runner.Children(self.root / 'record.json')
        children.items = [(child, {'pid': 123, 'identity': 'original', 'role': 'owned', 'members': {}})]
        with patch.object(runner, 'group_members', return_value={'123': {'identity': 'different', 'ppid': 1, 'group': 123}}), patch.object(runner.os, 'killpg') as kill:
            self.assertFalse(children.stop()[0]['stopped'])
            kill.assert_not_called()
        child.terminate.assert_not_called()

    def testGroupCleanupIncludesProvenDescendant(self):
        item = {'pid': 123, 'identity': 'leader', 'members': {}}
        members = {'123': {'identity': 'leader', 'ppid': 1, 'group': 123},
                   '456': {'identity': 'child', 'ppid': 123, 'group': 123}}
        with patch.object(runner, 'group_members', side_effect=[members, {}, {}, {}]), patch.object(runner.os, 'killpg') as kill:
            runner.stop_group(item)
            kill.assert_called_once_with(123, runner.signal.SIGTERM)
            self.assertIn('456', item['members'])

    def testFastExitIsTrackedBeforeIdentityFailure(self):
        child = unittest.mock.Mock(); child.pid = 123; child.poll.return_value = 1
        children = runner.Children(self.root / 'ownership.json')
        with patch.object(runner.subprocess, 'Popen', return_value=child), patch.object(runner, 'process_identity', side_effect=RuntimeError('ps failed')):
            with self.assertRaises(RuntimeError): children.start('test', ['/owned/test'], {}, self.root / 'test.log')
        self.assertEqual(children.items[0][0], child)

    def testCopyFailureDoesNotSkipCleanupOrReceipt(self):
        artifact = self.root / 'artifacts'; artifact.mkdir(mode=0o700)
        roots = {name: self.root / name for name in ('phone', 'tablet')}
        lanes = []
        for name, root in roots.items():
            (root / 'run/requests').mkdir(parents=True)
            (root / 'secrets').mkdir()
            result_root = self.root / (name + '-results'); result_root.mkdir()
            lanes.append({'manifest': str(root / 'lane.json'), 'lease': {'device': {'udid': name}, 'env': {'env': {'SIMURGH_RESULT_BUNDLE_DIR': str(result_root)}}}})
        manifest = {'runID': 'run', 'sourceRevision': 'source', 'artifactDir': str(artifact), 'stubExecutable': '/owned/stub', 'lanes': lanes}
        def read(path):
            if path.name == 'lane.json': return {'laneID': path.parent.name, 'signalURL': 'ws://127.0.0.1:18790/signal', 'runID': 'run'}
            return {'status': 'passed', 'checks': [{'ok': True}], 'startedAt': 100, 'durationSeconds': 10}
        service = unittest.mock.Mock(); service.pid = 123; service.poll.return_value = None
        test = unittest.mock.Mock(); test.pid = 456; test.poll.return_value = 0; test.returncode = 0
        owned = unittest.mock.Mock()
        def start(role, *_):
            if role.endswith('.test'):
                (self.root / (role.split('.')[0] + '-results') / 'farside-run.xcresult').mkdir()
                return test
            return service
        owned.start.side_effect = start; owned.stop.return_value = [{'stopped': True}]
        barrier = unittest.mock.Mock(); barrier.controls = [{'passed': True}, {'passed': True}]
        with patch.object(runner, 'validate_run', return_value=manifest), patch.object(runner, 'read_json', side_effect=read), patch.object(runner, 'Children', return_value=owned), patch.object(runner, 'Barrier', return_value=barrier), patch.object(runner, 'private_chain'), patch.object(runner, 'write_json') as write, patch.object(runner, 'test_command', return_value=['no-build']), patch.object(runner, 'lane_environment', return_value={}), patch.object(runner, 'service_owns_port', return_value=True), patch.object(runner.subprocess, 'check_output', return_value=''), patch.object(runner.shutil, 'which', return_value='/owned/bun'), patch.object(runner.shutil, 'copytree', side_effect=OSError('copy failed')):
            with self.assertRaisesRegex(OSError, 'copy failed'): runner.run_batch('manifest')
        owned.stop.assert_called_once()
        self.assertEqual(write.call_args[0][0], artifact / 'receipt.json')
        self.assertEqual(write.call_args[0][1]['status'], 'failed')

    def testCleanupAuthoritySurvivesExpiryAndSourceChangeButRejectsCorruption(self):
        base = self.root / 'e2e'; (base / 'parallel/run').mkdir(parents=True)
        for path in (base, base / 'parallel', base / 'parallel/run'): path.chmod(0o700)
        artifact = self.root / 'artifacts'; artifact.mkdir(mode=0o700)
        record = artifact / 'ownership.json'
        item = {'pid': 123, 'identity': 'owned-old-process', 'role': 'phone.test', 'command': ['/usr/bin/xcodebuild'], 'members': {}}
        runner.write_json(record, [item])
        authority = {'schemaVersion': 1, 'ownerUID': os.getuid(), 'runID': 'run', 'artifactDir': str(artifact),
                     'stubExecutable': '/owned/stub', 'ownershipSHA256': runner.sha256(record),
                     'sourceRevision': 'old-source', 'expiresAt': 1}
        path = base / 'parallel/run/run-manifest.json'; runner.write_json(path, authority)
        with patch.object(runner, 'BASE', base), patch.object(runner, 'stop_group') as stop, patch.object(runner.subprocess, 'check_output', side_effect=AssertionError('must not inspect current source')):
            runner.cleanup(str(path))
            stop.assert_called_once_with(item)
            runner.write_json(record, [dict(item, pid=999)])
            with self.assertRaisesRegex(runner.Refused, 'hash differs'): runner.cleanup(str(path))
            self.assertEqual(stop.call_count, 1)

    def testPrepareProductRefusalCreatesNoPairingSecret(self):
        base = self.root / 'e2e'
        stub = self.root / 'Stub.app'
        (stub / 'Contents/MacOS').mkdir(parents=True)
        (stub / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.roshan.PocketDesk.E2EStubHost', 'CFBundleExecutable': 'Stub'}))
        (stub / 'Contents/MacOS/Stub').write_bytes(b'FARSIDE_E2E_LANE_MANIFEST')
        lease = {'id': 'owned', 'device': {'udid': '00000000-0000-0000-0000-000000000001'},
                 'owner': {'sessionId': 'owned-session'}, 'env': {'env': {'SIMURGH_DERIVED_DATA': '/owned/DerivedData'}}}
        args = types.SimpleNamespace(run_id='refused', artifact_dir=str(self.root / 'artifacts'), stub_app=str(stub),
            simurgh='/owned/simurgh', simurgh_sha256='hash', simurgh_home='/owned/home', daemon_pid=123, daemon_identity='owned',
            runtime_library_root=[], lane_a_lease_json='/owned/a.json', lane_b_lease_json='/owned/b.json',
            lane_a_xctestrun='/owned/a.xctestrun', lane_b_xctestrun='/owned/b.xctestrun')
        authority = types.SimpleNamespace(lstat=lambda: types.SimpleNamespace(st_dev=1, st_ino=2, st_uid=os.getuid()))
        read = runner.read_json
        def input_json(path): return {'lease': lease} if str(path).startswith('/owned/') else read(path)
        with patch.object(runner, 'BASE', base), patch.object(runner, 'pinned_binary'), patch.object(runner, 'validate_daemon', return_value=authority), patch.object(runner, 'read_json', side_effect=input_json), patch.object(runner, 'validate_lease'), patch.object(runner, 'rpc', return_value=lease), patch.object(runner, 'expiry', return_value=time.time() + 900), patch.object(runner.socket, 'socket'), patch.object(runner.subprocess, 'check_output', return_value='/owned/developer'), patch.object(runner, 'validate_products', side_effect=runner.Refused('unsigned product')):
            with self.assertRaisesRegex(runner.Refused, 'unsigned product'): runner.prepare(args)
        self.assertTrue((base / 'parallel/refused/phone/lane.json').is_file())
        self.assertEqual(list(base.rglob('pairing-token')), [])

    def testEitherTokenAllocationFailureCleansSecretsBeforeChildLaunch(self):
        for fail_at in (1, 2):
            with self.subTest(fail_at=fail_at):
                batch = self.root / ('allocation-' + str(fail_at)); batch.mkdir(mode=0o700)
                artifact = batch / 'artifacts'; artifact.mkdir(mode=0o700)
                roots = {name: batch / name for name in ('phone', 'tablet')}
                for root in roots.values():
                    root.mkdir(mode=0o700); (root / 'secrets').mkdir(mode=0o700)
                manifest = {'runID': 'run', 'sourceRevision': 'source', 'artifactDir': str(artifact),
                            'lanes': [{'manifest': str(root / 'lane.json')} for root in roots.values()]}
                child = unittest.mock.Mock(); child.stop.return_value = []
                actual_create = runner.create_pairing_token
                count = 0
                def allocate(root):
                    nonlocal count
                    count += 1
                    if count == fail_at: raise OSError('token allocation failed')
                    actual_create(root)
                with patch.object(runner, 'validate_run', return_value=manifest), patch.object(runner, 'read_json', side_effect=lambda path: {'laneID': path.parent.name}), patch.object(runner, 'Children', return_value=child), patch.object(runner.shutil, 'which', return_value='/owned/bun'), patch.object(runner.subprocess, 'check_output', return_value=''), patch.object(runner, 'create_pairing_token', side_effect=allocate):
                    with self.assertRaisesRegex(OSError, 'token allocation failed'): runner.run_batch('manifest')
                child.start.assert_not_called(); child.stop.assert_called_once()
                self.assertTrue(all(not (root / 'secrets/pairing-token').exists() for root in roots.values()))
                self.assertEqual(runner.read_json(artifact / 'receipt.json')['status'], 'failed')

    def testStartupSettlesFinalImageAndExactArgvBeforeFreezing(self):
        child = unittest.mock.Mock(); child.pid = 123; child.poll.return_value = None
        before = 'Wed Sep 30 17:00:00 2026 /owned/launcher arg'
        final = 'Wed Sep 30 17:00:00 2026 /owned/final arg'
        def census(identity): return {'123': {'identity': identity, 'ppid': os.getpid(), 'group': 123}}
        with patch.object(runner, 'process_identity', side_effect=[before, final, final]), patch.object(runner, 'main_image', side_effect=['/owned/launcher', '/owned/final', '/owned/final']), patch.object(runner, 'group_members', side_effect=[census(before), census(final), census(final)]), patch.object(runner.time, 'sleep'):
            result = runner.settle_child(child, ['/owned/final', 'arg'])
        self.assertEqual(result['identity'], final)
        self.assertEqual(result['members']['123']['identity'], final)

    def testStartupRefusesChangedStartAndUnintendedArgv(self):
        child = unittest.mock.Mock(); child.pid = 123; child.poll.return_value = None
        before = 'Wed Sep 30 17:00:00 2026 /owned/final foreign'
        after = 'Wed Sep 30 17:00:01 2026 /owned/final arg'
        census = {'123': {'identity': before, 'ppid': os.getpid(), 'group': 123}}
        with patch.object(runner, 'process_identity', side_effect=[before, after]), patch.object(runner, 'main_image', return_value='/owned/final'), patch.object(runner, 'group_members', return_value=census), patch.object(runner.time, 'sleep'):
            with self.assertRaisesRegex(runner.Refused, 'start changed'):
                runner.settle_child(child, ['/owned/final', 'arg'])

    def testSettledChildDriftNeverUsesBootstrapDirectSignalFallback(self):
        child = unittest.mock.Mock(); child.pid = 123; child.poll.return_value = None
        children = runner.Children(self.root / 'settled-ownership.json')
        with patch.object(runner.subprocess, 'Popen', return_value=child), patch.object(runner, 'settle_child', return_value={'identity': 'settled', 'members': {}}), patch.object(children, 'observe', side_effect=runner.Refused('post-admission drift')):
            with self.assertRaisesRegex(runner.Refused, 'post-admission drift'):
                children.start('owned', ['/owned/final'], {}, self.root / 'settled.log')
        child.terminate.assert_not_called()
        self.assertEqual(runner.read_json(self.root / 'settled-ownership.json')[0]['identity'], 'settled')

    def testDescendantExecPreservesLifetimeButReusedBirthUidOrGroupRefuses(self):
        leader = {'identity': 'leader', 'ppid': 1, 'group': 123, 'birth': [100, 1], 'uid': os.getuid(), 'ruid': os.getuid()}
        descendant = {'identity': 'xcrun', 'ppid': 123, 'group': 123, 'birth': [100, 2], 'uid': os.getuid(), 'ruid': os.getuid()}
        item = {'pid': 123, 'identity': 'leader', 'members': {'123': leader, '456': descendant}}
        transitioned = dict(descendant, identity='pinned-tool')
        runner.validate_members(item, {'123': leader, '456': transitioned})
        for key, value in [('birth', [100, 3]), ('uid', os.getuid() + 1), ('ruid', os.getuid() + 1), ('group', 999)]:
            with self.subTest(key=key), patch.object(runner.os, 'killpg') as kill:
                changed = dict(transitioned); changed[key] = value
                with patch.object(runner, 'group_members', return_value={'123': leader, '456': changed}):
                    with self.assertRaises(runner.Refused): runner.stop_group(item)
                kill.assert_not_called()
        with self.assertRaises(runner.Refused):
            runner.validate_members(item, {'123': dict(leader, identity='unexpected-leader-exec'), '456': transitioned})

    def testLegacyIdentityAndCurrentAncestryRemainStrict(self):
        leader = {'identity': 'leader', 'ppid': 1, 'group': 123}
        legacy = {'identity': 'old', 'ppid': 123, 'group': 123}
        item = {'pid': 123, 'identity': 'leader', 'members': {'123': leader, '456': legacy}}
        with self.assertRaises(runner.Refused): runner.validate_members(item, {'123': leader, '456': dict(legacy, identity='changed')})
        # A historical parent PID is insufficient: its lifetime is not in this census.
        unknown = {'identity': 'new', 'ppid': 456, 'group': 123}
        with self.assertRaises(runner.Refused): runner.validate_members(item, {'123': leader, '789': unknown}, discover=True)

    def testBirthQueryRequiresFullSizeOwnedIdentityAndPositiveAbsence(self):
        function = unittest.mock.Mock(); library = types.SimpleNamespace(proc_pidinfo=function)
        with patch.object(runner.ctypes, 'CDLL', return_value=library), patch.object(runner.ctypes, 'get_errno', return_value=runner.errno.ESRCH), patch.object(runner.os, 'kill') as kill:
            function.return_value = 0
            self.assertIsNone(runner.process_birth(123)); kill.assert_not_called()
        for size in (0, 128):
            with patch.object(runner.ctypes, 'CDLL', return_value=library), patch.object(runner.ctypes, 'get_errno', return_value=runner.errno.EPERM), patch.object(runner.os, 'kill', return_value=None) as kill:
                function.return_value = size
                with self.assertRaisesRegex(runner.Refused, 'live process'): runner.process_birth(123)
                kill.assert_called_once_with(123, 0)
        def fill(pid, flavor, arg, buffer, size):
            self.assertEqual((pid, flavor, arg, size), (123, 3, 0, 136))
            info = runner.ctypes.cast(buffer, runner.ctypes.POINTER(runner.ProcBSDInfo)).contents
            info.pid = 123; info.uid = info.ruid = os.getuid(); info.pgid = 123; info.ppid = 10
            info.startSeconds = 100; info.startMicroseconds = 200
            return size
        function.side_effect = fill
        with patch.object(runner.ctypes, 'CDLL', return_value=library):
            self.assertEqual(runner.process_birth(123)['birth'], [100, 200])
        def foreign(*args):
            result = fill(*args)
            runner.ctypes.cast(args[3], runner.ctypes.POINTER(runner.ProcBSDInfo)).contents.uid = os.getuid() + 1
            return result
        function.side_effect = foreign
        with patch.object(runner.ctypes, 'CDLL', return_value=library):
            with self.assertRaisesRegex(runner.Refused, 'owner'): runner.process_birth(123)


if __name__ == '__main__':
    unittest.main()
