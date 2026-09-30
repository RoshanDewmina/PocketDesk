import importlib.util
import json
from pathlib import Path
import types
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('parent_runtime', Path(__file__).with_name('parent-runtime.py'))
parent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parent)


class FakeSocket:
    def __init__(self, invalid=None): self.invalid = invalid; self.request = None
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def settimeout(self, seconds): pass
    def connect(self, path): pass
    def sendall(self, data): self.request = json.loads(data)
    def recv(self, size):
        response = {'v': 1, 'id': self.request['id'], 'ok': True, 'result': {'lease': {'id': 'owned'}}}
        if self.invalid == 'version': response['v'] = 2
        if self.invalid == 'id': response['id'] = 'foreign'
        if self.invalid == 'error': response.update(ok=False, error={'code': 'REFUSED'})
        if self.invalid == 'disconnect': return b''
        return json.dumps(response).encode() + b'\n'


class ParentRuntimeTests(unittest.TestCase):
    def lease(self):
        return {'labels': {'lane': 'phone', 'run': 'owned-run', 'project': 'farside-parallel-stub'},
                'owner': {'pid': parent.os.getpid(), 'agent': parent.AGENT, 'sessionId': 'owned-session'},
                'spec': {'platform': 'iOS', 'runtime': '27.0', 'model': 'iPhone 17'}}

    def test_exact_owner_and_run_admitted(self):
        self.assertEqual(parent.lease_matches(self.lease(), types.SimpleNamespace(run_id='owned-run', runtime='27.0'),
                                            {'phone': 'owned-session'}), 'phone')

    def test_each_foreign_authority_refused(self):
        for section, key, value in [('owner', 'pid', 1), ('owner', 'agent', 'foreign'),
                                    ('owner', 'sessionId', 'foreign'), ('labels', 'run', 'foreign'),
                                    ('labels', 'project', 'foreign'), ('labels', 'lane', 'foreign'),
                                    ('spec', 'model', 'iPad mini (A17 Pro)'), ('spec', 'runtime', '27.2'),
                                    ('spec', 'platform', 'macOS')]:
            with self.subTest(section=section, key=key):
                lease = self.lease(); lease[section][key] = value
                with self.assertRaises(parent.Refused):
                    parent.lease_matches(lease, types.SimpleNamespace(run_id='owned-run', runtime='27.0'), {'phone': 'owned-session'})

    def test_nested_snapshot_rewrite_only_owned_products_and_profile(self):
        source = {'TestHostPath': '/old/Products/Debug/Host.app',
                  'DependentProductPaths': ['/old/Products/Debug/Test.xctest', '__TESTROOT__/Debug/App.app'],
                  'EnvironmentVariables': {'LLVM_PROFILE_FILE': '/unrelated/profile', 'DYLD_INSERT_LIBRARIES': '/usr/lib/libRPAC.dylib'}}
        result = parent.rewrite_snapshot(source, Path('/old/Products'), Path('/owned/Products'), Path('/owned/ProfileData'))
        self.assertEqual(result['TestHostPath'], '/owned/Products/Debug/Host.app')
        self.assertEqual(result['DependentProductPaths'], ['/owned/Products/Debug/Test.xctest', '__TESTROOT__/Debug/App.app'])
        self.assertEqual(result['EnvironmentVariables']['LLVM_PROFILE_FILE'], '/owned/ProfileData/%p.profraw')
        self.assertEqual(result['EnvironmentVariables']['DYLD_INSERT_LIBRARIES'], '/usr/lib/libRPAC.dylib')
        self.assertNotIn('SIMULATOR_UDID', result['EnvironmentVariables'])
        self.assertEqual(source['TestHostPath'], '/old/Products/Debug/Host.app')

    def test_rpc_version_request_id_error_and_disconnect_refused(self):
        runner = types.SimpleNamespace(validate_daemon=lambda _: Path('/owned/socket'))
        for invalid in ('version', 'id', 'error', 'disconnect'):
            with self.subTest(invalid=invalid), patch.object(parent.socket, 'socket', return_value=FakeSocket(invalid)):
                with self.assertRaises(parent.Refused): parent.protocol(runner, {}, 'lease.get', {'id': 'owned'})

    def test_rpc_missing_socket_does_not_start_daemon(self):
        runner = types.SimpleNamespace(validate_daemon=lambda _: (_ for _ in ()).throw(FileNotFoundError('absent')))
        with patch.object(parent.socket, 'socket') as socket_mock, patch.object(parent.subprocess, 'Popen') as process_mock:
            with self.assertRaises(FileNotFoundError): parent.protocol(runner, {}, 'lease.get', {'id': 'owned'})
            socket_mock.assert_not_called(); process_mock.assert_not_called()

    def test_rpc_admitted_and_method_allowlist(self):
        runner = types.SimpleNamespace(validate_daemon=lambda _: Path('/owned/socket'))
        with patch.object(parent.socket, 'socket', return_value=FakeSocket()):
            self.assertEqual(parent.protocol(runner, {}, 'lease.get', {'id': 'owned'}), {'lease': {'id': 'owned'}})
        with self.assertRaises(parent.Refused): parent.protocol(runner, {}, 'daemon.stop', {})

    def test_failed_startup_stops_retained_direct_child(self):
        child = unittest.mock.Mock(); child.pid = 123; child.poll.side_effect = [None, 0]
        runner = types.SimpleNamespace(settle_child=unittest.mock.Mock(side_effect=parent.Refused('startup failed')),
            group_members=unittest.mock.Mock(return_value={}), stop_group=unittest.mock.Mock())
        args = types.SimpleNamespace(unresolved_children=[], completed_children=[])
        with tempfile.TemporaryDirectory() as folder, patch.object(parent.subprocess, 'Popen', return_value=child):
            with self.assertRaisesRegex(parent.Refused, 'startup failed'):
                parent.run_child(runner, {'developerDir': '/Applications/Xcode.app/Contents/Developer'}, args, ['/owned/probe'], [], Path(folder), 'probe.log', 5, monitor=False)
        child.terminate.assert_called_once(); child.wait.assert_called_once()
        runner.stop_group.assert_not_called(); self.assertEqual(args.unresolved_children, [])
        self.assertEqual(args.completed_children, [{'pid': 123, 'role': 'probe.log', 'groupVerifiedAbsent': True}])

    def test_unresolved_startup_descendants_preserve_authority(self):
        child = unittest.mock.Mock(); child.pid = 123; child.poll.return_value = None
        writes = unittest.mock.Mock()
        runner = types.SimpleNamespace(settle_child=unittest.mock.Mock(side_effect=parent.Refused('startup failed')),
            group_members=unittest.mock.Mock(return_value={'456': {'identity': 'unresolved'}}),
            stop_group=unittest.mock.Mock(), write_json=writes)
        args = types.SimpleNamespace(unresolved_children=[], completed_children=[])
        with tempfile.TemporaryDirectory() as folder, patch.object(parent.subprocess, 'Popen', return_value=child):
            with self.assertRaisesRegex(parent.Refused, 'preserve lease/daemon'):
                parent.run_child(runner, {'developerDir': '/Applications/Xcode.app/Contents/Developer'}, args, ['/owned/probe'], [], Path(folder), 'probe.log', 5, monitor=False)
        self.assertEqual(args.unresolved_children[0]['pid'], 123)
        writes.assert_called_once(); child.terminate.assert_called_once()

    def test_failed_final_census_retains_authority_before_persistence(self):
        child = unittest.mock.Mock(); child.pid = 123; child.poll.side_effect = [None, 0]
        runner = types.SimpleNamespace(settle_child=unittest.mock.Mock(side_effect=parent.Refused('startup failed')),
            group_members=unittest.mock.Mock(side_effect=OSError('census failed')), stop_group=unittest.mock.Mock(),
            write_json=unittest.mock.Mock(side_effect=OSError('persist failed')))
        args = types.SimpleNamespace(unresolved_children=[], completed_children=[])
        with tempfile.TemporaryDirectory() as folder, patch.object(parent.subprocess, 'Popen', return_value=child):
            with self.assertRaisesRegex(OSError, 'persist failed'):
                parent.run_child(runner, {'developerDir': '/Applications/Xcode.app/Contents/Developer'}, args,
                                 ['/owned/probe'], [], Path(folder), 'probe.log', 5, monitor=False)
        self.assertEqual(args.unresolved_children[0]['pid'], 123)
        child.terminate.assert_called_once(); child.wait.assert_called_once()

    def test_pre_run_cleanup_requires_fresh_absent_readonly_groups(self):
        args = types.SimpleNamespace(unresolved_children=[], completed_children=[
            {'pid': 123, 'role': 'validate.log', 'groupVerifiedAbsent': True}])
        runner = types.SimpleNamespace(group_members=unittest.mock.Mock(return_value={}), cleanup=unittest.mock.Mock())
        with tempfile.TemporaryDirectory() as folder:
            self.assertTrue(parent.cleanup_native_authority(runner, Path(folder) / 'manifest', Path(folder), False, args))
            runner.group_members.assert_called_once_with(123); runner.cleanup.assert_not_called()
            for result in ({'456': {'identity': 'present'}}, OSError('census failed')):
                runner.group_members.reset_mock()
                if isinstance(result, Exception): runner.group_members.side_effect = result
                else: runner.group_members.return_value = result
                with self.assertRaises((parent.Refused, OSError)):
                    parent.cleanup_native_authority(runner, Path(folder) / 'manifest', Path(folder), False, args)
                runner.cleanup.assert_not_called()

    def test_run_invoked_or_existing_authority_never_skips_strict_cleanup(self):
        args = types.SimpleNamespace(unresolved_children=[], completed_children=[])
        runner = types.SimpleNamespace(group_members=unittest.mock.Mock(),
            cleanup=unittest.mock.Mock(side_effect=parent.Refused('ownership absent or corrupt')))
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaisesRegex(parent.Refused, 'ownership absent or corrupt'):
                parent.cleanup_native_authority(runner, root / 'manifest', root, True, args)
            (root / 'ownership.json').write_text('{}')
            with self.assertRaisesRegex(parent.Refused, 'ownership absent or corrupt'):
                parent.cleanup_native_authority(runner, root / 'manifest', root, False, args)
        self.assertEqual(runner.cleanup.call_count, 2); runner.group_members.assert_not_called()

    def test_unresolved_readonly_children_refuse_missing_authority_exception(self):
        args = types.SimpleNamespace(unresolved_children=[{'pid': 123}], completed_children=[])
        runner = types.SimpleNamespace(group_members=unittest.mock.Mock(), cleanup=unittest.mock.Mock())
        with tempfile.TemporaryDirectory() as folder, self.assertRaisesRegex(parent.Refused, 'readonly child cleanup unresolved'):
            parent.cleanup_native_authority(runner, Path(folder) / 'manifest', Path(folder), False, args)
        runner.group_members.assert_not_called(); runner.cleanup.assert_not_called()

    def test_final_cleanup_missing_manifest_after_run_blocks_release_gate(self):
        args = types.SimpleNamespace(unresolved_children=[], completed_children=[])
        runner = types.SimpleNamespace(cleanup=unittest.mock.Mock(side_effect=parent.Refused('manifest missing')))
        errors, outcome = [], {}
        with tempfile.TemporaryDirectory() as folder, patch.object(parent.shutil, 'copytree') as export:
            root = Path(folder); missing = root / 'missing-manifest.json'
            complete = parent.finish_child_cleanup(runner, missing, root, True, args, outcome, errors)
            self.assertFalse(complete)
            with self.assertRaisesRegex(parent.Refused, 'preserve owned leases'):
                parent.check(complete, 'unresolved child cleanup; preserve owned leases and daemon for recovery')
            runner.cleanup.assert_called_once_with(str(missing)); export.assert_not_called()
        self.assertIn('manifest missing', errors[0]); self.assertNotIn('noNativeBatchInvoked', outcome)

    def test_final_cleanup_run_without_manifest_authority_blocks_release(self):
        args = types.SimpleNamespace(unresolved_children=[], completed_children=[])
        runner = types.SimpleNamespace(cleanup=unittest.mock.Mock())
        errors = []
        with tempfile.TemporaryDirectory() as folder:
            self.assertFalse(parent.finish_child_cleanup(runner, None, Path(folder), True, args, {}, errors))
        self.assertIn('without manifest authority', errors[0]); runner.cleanup.assert_not_called()



class ResourcePolicyTests(unittest.TestCase):
    def test_continuous_warning_deadline_and_unknown_pressure(self):
        budget = parent.FunctionalWarningBudget(); budget.observe(2, 0)
        budget.observe(2, 30)
        with self.assertRaisesRegex(parent.Refused, 'budget exceeded'): budget.observe(2, 30.01)
        for value in (0, 3, 4, 8, None):
            with self.subTest(value=value), self.assertRaisesRegex(parent.Refused, 'critical or unknown'):
                parent.FunctionalWarningBudget().observe(value, 0)

    def test_budget_spans_phases_and_multiple_warning_windows(self):
        budget = parent.FunctionalWarningBudget(); budget.observe(2, 0)
        for now in (10, 12, 14): budget.observe(1, now)
        self.assertIsNone(budget.warning_start); self.assertEqual(budget.warning_seconds, 14)
        budget.observe(2, 20)
        with self.assertRaisesRegex(parent.Refused, 'aggregate'): budget.observe(2, 37)

    def test_brief_normal_flapping_cannot_clear_warning(self):
        budget = parent.FunctionalWarningBudget(); budget.observe(2, 0)
        for now, value in ((10, 1), (11, 2), (20, 1), (21, 1), (22, 2), (29, 1)):
            budget.observe(value, now)
        self.assertEqual(budget.warning_start, 0)
        with self.assertRaisesRegex(parent.Refused, 'budget exceeded'): budget.observe(1, 31)

    def test_stable_three_normals_require_two_second_spacing_and_four_second_span(self):
        budget = parent.FunctionalWarningBudget(); budget.observe(2, 0)
        for now in (1, 1.1, 1.2, 2, 3): budget.observe(1, now)
        self.assertIsNotNone(budget.warning_start)
        budget.observe(1, 5); self.assertIsNone(budget.warning_start)
        self.assertEqual(budget.normal_count, 3)

    def test_active_sampling_gap_refuses_and_normal_does_not_spend_warning_budget(self):
        budget = parent.FunctionalWarningBudget(); budget.observe(1, 0)
        budget.observe(1, 2, enforce_gap=True)
        self.assertEqual(budget.warning_seconds, 0)
        with self.assertRaisesRegex(parent.Refused, 'sample gap'): budget.observe(1, 4.01, enforce_gap=True)

    def args(self, deadline=200):
        return types.SimpleNamespace(simurgh_parent='/private/tmp', total_deadline=deadline)

    def test_warning_or_critical_trace_is_written_before_policy_refusal(self):
        runner = types.SimpleNamespace(write_json=unittest.mock.Mock())
        with tempfile.TemporaryDirectory() as folder:
            workspace = Path(folder)
            for level in (4, 7):
                with self.subTest(level=level), patch.object(parent, 'resource_snapshot', return_value={'memoryPressure': level}), self.assertRaises(parent.Refused):
                    parent.sample_resources(runner, self.args(), workspace, 'run', parent.FunctionalWarningBudget())
                self.assertEqual(runner.write_json.call_args.args[1]['memoryPressure'], level)
            trace = [json.loads(line) for line in (workspace / 'resource-samples.jsonl').read_text().splitlines()]
            self.assertEqual([x['memoryPressure'] for x in trace], [4, 7])

    def test_missing_resource_signal_refuses_without_fallback(self):
        runner = types.SimpleNamespace(write_json=unittest.mock.Mock())
        with tempfile.TemporaryDirectory() as folder, patch.object(parent, 'resource_snapshot', side_effect=OSError('missing sysctl')), self.assertRaisesRegex(OSError, 'missing sysctl'):
            parent.sample_resources(runner, self.args(), Path(folder), 'run', parent.FunctionalWarningBudget())
        self.assertIn('missing sysctl', runner.write_json.call_args.args[1]['error'])

    def test_snapshot_failure_preserves_pressure_read_before_thermal_or_disk_error(self):
        runner = types.SimpleNamespace(write_json=unittest.mock.Mock())
        for outputs, disk_error in ((['4', OSError('thermal unreadable')], None),
                (['2', 'No thermal warning level has been recorded'], OSError('disk unreadable'))):
            with self.subTest(outputs=outputs), tempfile.TemporaryDirectory() as folder, patch.object(parent, 'command', side_effect=outputs), patch.object(parent.os, 'statvfs', side_effect=disk_error), self.assertRaises(parent.ResourceSnapshotFailure):
                parent.sample_resources(runner, self.args(), Path(folder), 'run', parent.FunctionalWarningBudget())
            self.assertIn(runner.write_json.call_args.args[1]['memoryPressure'], (2, 4))
            self.assertIn('unreadable', runner.write_json.call_args.args[1]['error'])

    def test_settling_waits_for_stable_normal_and_renews_exact_leases_without_child(self):
        clock = [0.0]; levels = iter((2, 1, 1, 1, 1, 1))
        leases = [{'id': 'phone'}, {'id': 'tablet'}]
        runner = types.SimpleNamespace(validate_lease=unittest.mock.Mock())
        def renewal(*args, **kwargs): return {'lease': next(item for item in leases if item['id'] == args[3]['id'])}
        with tempfile.TemporaryDirectory() as folder, patch.object(parent.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(parent.time, 'sleep', side_effect=lambda duration: clock.__setitem__(0, clock[0] + duration)), patch.object(parent, 'sample_resources', side_effect=lambda *args: {'memoryPressure': next(levels)}), patch.object(parent, 'protocol', side_effect=renewal) as rpc, patch.object(parent.subprocess, 'Popen') as spawn:
            parent.settle_resources(runner, {}, self.args(), leases, Path(folder), 'after-acquire')
        self.assertEqual(clock[0], 5); spawn.assert_not_called()
        self.assertEqual([call.args[3]['id'] for call in rpc.call_args_list], ['phone', 'tablet'])
        self.assertEqual(runner.validate_lease.call_count, 2)

    def test_settling_deadline_and_lease_expiry_stop_before_new_load(self):
        clock = [0.0]
        runner = types.SimpleNamespace(validate_lease=unittest.mock.Mock())
        with tempfile.TemporaryDirectory() as folder, patch.object(parent.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(parent.time, 'sleep', side_effect=lambda duration: clock.__setitem__(0, clock[0] + duration)), patch.object(parent, 'sample_resources', return_value={'memoryPressure': 2}), patch.object(parent.subprocess, 'Popen') as spawn:
            with self.assertRaisesRegex(parent.Refused, 'settling deadline'):
                parent.settle_resources(runner, {}, self.args(deadline=3), [], Path(folder), 'after-acquire')
            self.assertEqual(clock[0], 3); spawn.assert_not_called()
            clock[0] = 0
            with patch.object(parent, 'protocol', side_effect=parent.Refused('lease expired')), self.assertRaisesRegex(parent.Refused, 'lease expired'):
                parent.settle_resources(runner, {}, self.args(), [{'id': 'phone'}], Path(folder), 'after-acquire')
            spawn.assert_not_called()

    def test_critical_snapshot_before_run_child_does_not_spawn(self):
        runner = types.SimpleNamespace(); args = self.args(); args.resource_budget = parent.FunctionalWarningBudget()
        with tempfile.TemporaryDirectory() as folder, patch.object(parent, 'sample_resources', side_effect=parent.Refused('critical')), patch.object(parent.subprocess, 'Popen') as spawn, self.assertRaisesRegex(parent.Refused, 'critical'):
            parent.run_child(runner, {}, args, ['/owned/probe'], [], Path(folder), 'run.log', 5)
        spawn.assert_not_called()

if __name__ == '__main__': unittest.main()
