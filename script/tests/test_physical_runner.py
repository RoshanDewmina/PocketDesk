"""script/physical/run.sh against fake devicectl, ioreg and xcodebuild: no iPhone, no Mac input."""
import json
import os
import pty
import select
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / 'physical' / 'run.sh'
TARGET = 'FarsidePhysicalLifecycleUITests'

FAKE_DEVICECTL = r'''#!/usr/bin/env python3
import json, os, sys, time
d = os.environ['FAKE_DIR']; state = json.load(open(f'{d}/state.json')); a = sys.argv[1:]
out = a[a.index('--json-output') + 1] if '--json-output' in a else None
open(f'{d}/devicectl-calls', 'a').write(' '.join(a) + '\n')
def write(result):
    json.dump({'info': {'outcome': 'success'}, 'result': result}, open(out, 'w'))
if a[:2] == ['list', 'devices']:
    if state.get('listHang'): time.sleep(100)
    write({'devices': state['devices']})
elif a[:3] == ['device', 'info', 'lockState']:
    if state.get('lockHang'): time.sleep(100)
    calls = open(f'{d}/devicectl-calls').read().count('lockState')
    locked_from = state.get('lockedFromCall')
    write({'passcodeRequired': True} if locked_from and calls >= locked_from else state['lock'])
elif a[:3] == ['device', 'info', 'processes']:
    write({'runningProcesses': state.get('processes', [])})
elif a[:3] == ['device', 'process', 'terminate']:
    open(f'{d}/terminated', 'a').write(a[a.index('--pid') + 1] + '\n')
'''

FAKE_IOREG = r'''#!/usr/bin/env python3
import os, sys
d = os.environ['FAKE_DIR']
if '-n' in sys.argv:
    locked = open(f'{d}/locked').read().strip() == 'true'
    key = '<key>CGSSessionScreenIsLocked</key><true/>' if locked else ''
    print(f'<?xml version="1.0"?><plist version="1.0"><dict><key>IOConsoleUsers</key><array><dict>{key}</dict></array></dict></plist>')
else:
    idle = float(open(f'{d}/idle').read())
    print(f'  | |   "HIDIdleTime" = {int(idle * 1e9)}')
'''

FAKE_XCODEBUILD = r'''#!/usr/bin/env python3
import json, os, sys, time
d = os.environ['FAKE_DIR']; plan = json.load(open(f'{d}/xcodebuild.json'))
only = [x.split(':', 1)[1] for x in sys.argv if x.startswith('-only-testing:')]
env = {k: v for k, v in os.environ.items() if k.startswith('TEST_RUNNER_')}
open(f'{d}/xcodebuild-calls', 'a').write(json.dumps({'only': only, 'env': env, 'args': sys.argv[1:], 'pid': os.getpid()}) + '\n')
key = 'preflight' if any('PhysicalPreflightTests' in o for o in only) else ('macinput' if 'TEST_RUNNER_FARSIDE_PHYSICAL_MAC_INPUT' in env else 'readonly')
mode = plan.get(key, 'pass')
print('Testing started', flush=True)
if mode == 'unlock':
    print('Error Domain=com.apple.dt.deviceprep Code=-3 "Unlock Roshan’s iPhone to Continue"', flush=True); time.sleep(100)
if mode == 'hang':
    time.sleep(100)
if mode == 'maclock':
    time.sleep(1); open(f'{d}/locked', 'w').write('true'); time.sleep(100)
if mode == 'human':
    time.sleep(1); open(f'{d}/idle', 'w').write('0.2'); open(f'{d}/human-at', 'w').write(str(time.time())); time.sleep(100)
if key == 'preflight':
    print(f"Test Case '-[FarsidePhysicalLifecycleUITests.PhysicalPreflightTests testAutomationReady]' passed (1.0 seconds).")
    print('\t Executed 1 test, with 0 failures (0 unexpected) in 1.0 (1.0) seconds')
elif mode == 'fail':
    print('\t Executed 1 test, with 1 failure (1 unexpected) in 1.0 (1.0) seconds'); sys.exit(65)
else:
    print('\t Executed 3 tests, with 2 tests skipped and 0 failures (0 unexpected) in 1.0 (1.0) seconds')
'''

READ_ONLY_SOURCE = 'final class PhysicalLifecycleSmokeTests: XCTestCase {\n    func testHomeReturn() throws {}\n}\n'
MAC_INPUT_SOURCE = textwrap.dedent('''\
    @MainActor final class PhysicalSpotlightTests: PhysicalMacInputTestCase {
        @MainActor
        func testOpenAppTypesIntoSpotlight() throws {}
        // func testCommentedOut() throws {}
        func testClipboardPhoneToMac() throws {}
        private func helper() {}
    }
''')
IPHONE = {
    'identifier': '557A7877-F729-5031-9606-0E04F2B67822',
    'connectionProperties': {'pairingState': 'paired', 'tunnelState': 'connected'},
    'deviceProperties': {'name': 'Test iPhone', 'developerModeStatus': 'enabled'},
    'hardwareProperties': {'udid': '00008150-TEST', 'platform': 'iOS', 'reality': 'physical'},
}
SIMULATOR = {
    'identifier': 'SIM', 'connectionProperties': {'pairingState': 'paired', 'tunnelState': 'disconnected'},
    'deviceProperties': {'name': 'Sim', 'developerModeStatus': None},
    'hardwareProperties': {'udid': 'SIM', 'platform': 'iOS', 'reality': 'virtual'},
}


class PhysicalRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.sources = self.dir / 'sources'
        self.sources.mkdir()
        (self.sources / 'PhysicalLifecycleSmokeTests.swift').write_text(READ_ONLY_SOURCE)
        (self.sources / 'PhysicalMacInputTestCase.swift').write_text('class PhysicalMacInputTestCase: XCTestCase {\n}\n')
        (self.sources / 'PhysicalPreflightTests.swift').write_text(
            'final class PhysicalPreflightTests: XCTestCase {\n    func testAutomationReady() throws {}\n}\n')
        for name, body in [('devicectl', FAKE_DEVICECTL), ('ioreg', FAKE_IOREG), ('xcodebuild', FAKE_XCODEBUILD)]:
            path = self.dir / name
            path.write_text(body)
            path.chmod(0o755)
        self.derived = self.dir / 'derived'
        (self.derived / 'Build' / 'Products').mkdir(parents=True)
        (self.derived / 'Build' / 'Products' / f'{TARGET}_iphoneos27.0-arm64.xctestrun').write_text('fake')
        self.host_name = f'FakeHost{os.getpid()}'
        (self.dir / self.host_name).symlink_to('/bin/sleep')
        self.host = subprocess.Popen([str(self.dir / self.host_name), '120'])
        self.state({'devices': [IPHONE, SIMULATOR], 'lock': {'passcodeRequired': False, 'unlockedSinceBoot': True}})
        self.plan({})
        self.mac(locked=False, idle=300)

    def tearDown(self):
        self.host.kill()
        self.host.wait()
        self.tmp.cleanup()

    def state(self, value):
        (self.dir / 'state.json').write_text(json.dumps(value))

    def plan(self, value):
        (self.dir / 'xcodebuild.json').write_text(json.dumps(value))

    def mac(self, locked, idle):
        (self.dir / 'locked').write_text('true' if locked else 'false')
        (self.dir / 'idle').write_text(str(idle))

    def add_mac_input_tests(self):
        (self.sources / 'PhysicalSpotlightTests.swift').write_text(MAC_INPUT_SOURCE)

    def env(self, **limits):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FARSIDE_', 'TEST_RUNNER_'))}
        env.update({
            'FAKE_DIR': str(self.dir), 'FARSIDE_RUNNER_ROOT': str(self.dir / 'root'),
            'FARSIDE_RUNNER_TEST_SOURCES': str(self.sources), 'FARSIDE_RUNNER_DEVICECTL': str(self.dir / 'devicectl'),
            'FARSIDE_RUNNER_IOREG': str(self.dir / 'ioreg'), 'FARSIDE_RUNNER_XCODEBUILD': str(self.dir / 'xcodebuild'),
            'FARSIDE_RUNNER_DERIVED': str(self.derived), 'FARSIDE_RUNNER_HOST_PROCESS': self.host_name,
            # Inherited gates must never reach the iPhone.
            'TEST_RUNNER_FARSIDE_PHYSICAL_MAC_INPUT': '1', 'FARSIDE_PHYSICAL_MAC_INPUT': '1',
        })
        env.update({f'FARSIDE_RUNNER_{k.upper()}': str(v) for k, v in limits.items()})
        return env

    def run_runner(self, *args, **limits):
        started = time.monotonic()
        result = subprocess.run(['/bin/zsh', str(RUNNER), *args], env=self.env(**limits),
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        result.seconds = time.monotonic() - started
        result.last = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ''
        return result

    def run_in_terminal(self, *args, answer='yes', keyboard=True, idle_after=300, **limits):
        """Runs the runner with a pseudo-terminal, answering the confirmation. keyboard=True also moves the
        fake HID idle clock, as a real keypress would; idle_after is the idle time once confirmed."""
        leader, follower = pty.openpty()
        started = time.monotonic()
        process = subprocess.Popen(['/bin/zsh', str(RUNNER), *args], env=self.env(**limits),
                                   stdin=follower, stdout=follower, stderr=subprocess.PIPE, text=True)
        os.close(follower)
        output, answered, confirmed = b'', False, False
        while time.monotonic() - started < 60:
            ready, _, _ = select.select([leader], [], [], 1)
            if not ready:
                continue
            try:
                chunk = os.read(leader, 4096)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if not answered and b'to continue:' in output:
                if keyboard:
                    (self.dir / 'idle').write_text('0.5')
                os.write(leader, (answer + '\n').encode())
                answered = True
            if not confirmed and b'Confirmed at this Mac' in output:
                (self.dir / 'idle').write_text(str(idle_after))
                confirmed = True
        else:
            process.kill()
        process.wait(timeout=30)
        stderr = process.stderr.read()
        process.stderr.close()
        os.close(leader)
        text = output.decode(errors='replace').replace('\r', '')
        lines = [line for line in text.strip().splitlines() if line.strip()]
        return process.returncode, (lines[-1] if lines else ''), text, stderr, time.monotonic() - started

    def calls(self):
        path = self.dir / 'xcodebuild-calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_dry_run_reports_ready_and_sends_nothing(self):
        r = self.run_runner('--dry-run')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.last.startswith('READY'), r.stdout)
        self.assertIn('Test iPhone (00008150-TEST) pairing paired, Developer Mode enabled, tunnel connected', r.stdout)
        self.assertIn('lock state unlocked', r.stdout)
        self.assertIn('Read-only:    PhysicalLifecycleSmokeTests', r.stdout)
        self.assertIn('-test-timeouts-enabled YES -default-test-execution-time-allowance 180', r.stdout)
        self.assertIn('Auto-Lock to Never', r.stdout)
        self.assertEqual(self.calls(), [], 'a dry run must not run xcodebuild')
        devicectl = (self.dir / 'devicectl-calls').read_text()
        self.assertNotIn('process', devicectl)

    def test_locked_iphone_stops_with_one_instruction(self):
        self.state({'devices': [IPHONE], 'lock': {'passcodeRequired': True, 'unlockedSinceBoot': True}})
        r = self.run_runner('--dry-run')
        self.assertEqual(r.returncode, 3)
        self.assertEqual(r.last, 'NOT READY: Test iPhone is locked. Unlock it and leave it on the Home Screen, then run this again.')

    def test_unanswered_iphone_is_bounded(self):
        self.state({'devices': [IPHONE], 'lockHang': True, 'lock': {}})
        r = self.run_runner('--dry-run', device_limit=3)
        self.assertEqual(r.returncode, 3)
        self.assertIn('did not answer', r.last)
        self.assertLess(r.seconds, 15)

    def test_missing_developer_mode_and_missing_iphone(self):
        off = json.loads(json.dumps(IPHONE))
        off['deviceProperties']['developerModeStatus'] = 'disabled'
        self.state({'devices': [off], 'lock': {}})
        r = self.run_runner('--dry-run')
        self.assertEqual(r.returncode, 3)
        self.assertIn('Developer Mode is off', r.last)
        self.state({'devices': [SIMULATOR], 'lock': {}})
        r = self.run_runner('--dry-run')
        self.assertEqual(r.returncode, 3)
        self.assertTrue(r.last.startswith('NOT READY: no iPhone is paired with this Mac.'), r.last)

    def test_locked_mac_stops_before_the_iphone_is_asked(self):
        self.mac(locked=True, idle=300)
        r = self.run_runner('--dry-run')
        self.assertEqual(r.returncode, 3)
        self.assertEqual(r.last, 'NOT READY: this Mac is locked. Unlock it, then run this again.')
        self.assertFalse((self.dir / 'devicectl-calls').exists())

    def test_mac_input_tests_are_skipped_without_the_flag(self):
        self.add_mac_input_tests()
        r = self.run_runner('--skip-build')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls()
        self.assertEqual([c['only'] for c in calls], [[f'{TARGET}/PhysicalPreflightTests/testAutomationReady'],
                                                      [f'{TARGET}/PhysicalLifecycleSmokeTests']])
        self.assertEqual(calls[0]['env'], {'TEST_RUNNER_FARSIDE_PHYSICAL_PREFLIGHT': '1'})
        self.assertEqual(calls[1]['env'], {'TEST_RUNNER_FARSIDE_PHYSICAL_LIFECYCLE_SMOKE': '1'})
        self.assertIn('-test-timeouts-enabled', calls[1]['args'])
        self.assertIn('Skipping 2 Mac-input test(s)', r.stderr)
        self.assertIn('read-only: 1 passed, 0 failed, 2 skipped', r.stderr)

    def test_only_mac_input_without_flag_is_refused_and_unclassified_never_runs(self):
        self.add_mac_input_tests()
        r = self.run_runner('--dry-run', '--only', 'PhysicalSpotlightTests')
        self.assertEqual(r.returncode, 2)
        self.assertIn('Add --mac-input', r.last)
        (self.sources / 'PhysicalFeatureTests.swift').write_text('final class PhysicalFeatureTests: XCTestCase {\n    func testOpenApp() throws {}\n}\n')
        r = self.run_runner('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertIn('Never run:    PhysicalFeatureTests', r.stdout)
        r = self.run_runner('--dry-run', '--only', 'PhysicalFeatureTests')
        self.assertEqual(r.returncode, 2)
        self.assertIn('not a known physical test class', r.last)

    def test_mac_input_refuses_without_a_terminal(self):
        self.add_mac_input_tests()
        r = self.run_runner('--mac-input', '--skip-build')
        self.assertEqual(r.returncode, 2)
        self.assertIn('needs a person at this Mac', r.last)
        self.assertEqual(self.calls(), [])

    def test_mac_input_cancelled_unless_yes(self):
        self.add_mac_input_tests()
        code, last, _, _, _ = self.run_in_terminal('--mac-input', '--skip-build', answer='y')
        self.assertEqual(code, 2)
        self.assertEqual(last, 'Cancelled: nothing was sent to this Mac.')
        self.assertEqual(self.calls(), [])

    def test_mac_input_yes_must_come_from_this_macs_keyboard(self):
        self.add_mac_input_tests()
        code, last, text, stderr, _ = self.run_in_terminal('--mac-input', '--skip-build', keyboard=False)
        self.assertEqual(code, 2, text + stderr)
        self.assertIn("did not come from this Mac's keyboard", last)
        self.assertEqual(self.calls(), [])

    def test_mac_input_runs_each_test_alone_after_confirmation(self):
        self.add_mac_input_tests()
        code, last, text, stderr, _ = self.run_in_terminal('--mac-input', '--skip-build')
        self.assertEqual(code, 0, text + stderr)
        self.assertIn('CLICK AND TYPE ON THIS MAC: 2 test(s)', text)
        mac = [c for c in self.calls() if 'TEST_RUNNER_FARSIDE_PHYSICAL_MAC_INPUT' in c['env']]
        self.assertEqual([c['only'] for c in mac], [[f'{TARGET}/PhysicalSpotlightTests/testOpenAppTypesIntoSpotlight'],
                                                    [f'{TARGET}/PhysicalSpotlightTests/testClipboardPhoneToMac']])
        self.assertIn('MAC INPUT 1/2: PhysicalSpotlightTests/testOpenAppTypesIntoSpotlight will now click and type', stderr)

    def test_mac_input_waits_for_idle_and_gives_up_bounded(self):
        self.add_mac_input_tests()
        code, last, text, stderr, seconds = self.run_in_terminal('--mac-input', '--skip-build', idle_after=30, idle_wait_limit=2)
        self.assertEqual(code, 5, text + stderr)
        self.assertIn('no more Mac input was sent', last)
        self.assertFalse([c for c in self.calls() if 'TEST_RUNNER_FARSIDE_PHYSICAL_MAC_INPUT' in c['env']])
        self.assertLess(seconds, 20)

    def test_human_activity_stops_the_mac_input_test_immediately(self):
        self.add_mac_input_tests()
        self.plan({'macinput': 'human'})
        self.state({'devices': [IPHONE], 'lock': {'passcodeRequired': False},
                    'processes': [{'processIdentifier': 501, 'executable': 'file:///private/var/containers/Bundle/Application/X/PocketDeskRemote.app/PocketDeskRemote'},
                                  {'processIdentifier': 502, 'executable': 'file:///private/var/containers/Bundle/Application/Y/FarsidePhysicalLifecycleUITests-Runner.app/FarsidePhysicalLifecycleUITests-Runner'},
                                  {'processIdentifier': 77, 'executable': 'file:///Applications/MobileSafari.app/MobileSafari'}]})
        code, last, text, stderr, _ = self.run_in_terminal('--mac-input', '--skip-build')
        stopped_at = time.time()
        self.assertEqual(code, 4, text + stderr)
        self.assertTrue(last.startswith("STOPPED: this Mac's keyboard, mouse or trackpad was used"), last)
        self.assertEqual(sorted((self.dir / 'terminated').read_text().split()), ['501', '502'])
        mac = [c for c in self.calls() if 'TEST_RUNNER_FARSIDE_PHYSICAL_MAC_INPUT' in c['env']]
        self.assertEqual(len(mac), 1, 'nothing more may run after the stop')
        log = next((self.dir / 'root' / 'runs').glob('*/run.log')).read_text()
        self.assertIn('Stopping PhysicalSpotlightTests/testOpenAppTypesIntoSpotlight', log)
        self.assertIn(f'Paused {self.host_name} (pid {self.host.pid})', log)
        self.assertIn(f'Resumed {self.host_name} (pid {self.host.pid})', log)
        self.assertNotIn('T', subprocess.run(['ps', '-o', 'state=', '-p', str(self.host.pid)], capture_output=True, text=True).stdout)
        self.assertLess(stopped_at - float((self.dir / 'human-at').read_text()), 15)
        self.assertFalse(self.alive(mac[0]['pid']))

    def test_mac_locking_mid_test_stops_it(self):
        self.add_mac_input_tests()
        self.plan({'macinput': 'maclock'})
        code, last, text, stderr, _ = self.run_in_terminal('--mac-input', '--skip-build')
        self.assertEqual(code, 4, text + stderr)
        self.assertTrue(last.startswith("STOPPED: this Mac's screen locked"), last)
        self.assertEqual(len([c for c in self.calls() if 'TEST_RUNNER_FARSIDE_PHYSICAL_MAC_INPUT' in c['env']]), 1)

    def alive(self, pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def test_missing_option_value_exits_instead_of_spinning(self):
        for option in ['--device', '--only', '--derived-data']:
            r = self.run_runner('--dry-run', option)
            self.assertEqual(r.returncode, 2, option)
            self.assertIn('needs a value', r.stderr)

    def test_only_with_an_unknown_test_name_is_refused(self):
        r = self.run_runner('--dry-run', '--only', 'PhysicalLifecycleSmokeTests/testTypo')
        self.assertEqual(r.returncode, 2)
        self.assertIn('does not exist', r.last)

    def test_iphone_locking_mid_run_is_caught_by_the_lock_poll(self):
        self.plan({'readonly': 'hang'})
        self.state({'devices': [IPHONE], 'lock': {'passcodeRequired': False}, 'lockedFromCall': 2})
        r = self.run_runner('--skip-build', lock_poll_interval=1)
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn('the iPhone locked during the read-only tests', r.last)
        self.assertIn('Auto-Lock to Never', r.last)
        self.assertLess(r.seconds, 25)

    def test_missing_build_products_give_the_build_instruction(self):
        next((self.derived / 'Build' / 'Products').glob('*.xctestrun')).unlink()
        r = self.run_runner('--skip-build')
        self.assertEqual(r.returncode, 3)
        self.assertIn('without --skip-build', r.last)
        self.assertEqual(self.calls(), [])

    def test_interrupt_ends_the_running_xcodebuild(self):
        self.plan({'readonly': 'hang'})
        process = subprocess.Popen(['/bin/zsh', str(RUNNER), '--skip-build'], env=self.env(), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and len(self.calls()) < 2:
            time.sleep(0.2)
        self.assertEqual(len(self.calls()), 2)
        os.killpg(process.pid, signal.SIGINT)
        process.communicate(timeout=30)
        time.sleep(0.5)
        self.assertFalse(self.alive(self.calls()[1]['pid']), 'xcodebuild must not outlive an interrupted run')

    def test_iphone_unlock_prompt_during_preflight_stops_fast(self):
        self.plan({'preflight': 'unlock'})
        r = self.run_runner('--skip-build')
        self.assertEqual(r.returncode, 3)
        self.assertIn('Unlock the iPhone and leave it on the Home Screen', r.last)
        self.assertLess(r.seconds, 20)
        self.assertEqual(len(self.calls()), 1, 'no test runs after a failed pre-flight')

    def test_hung_read_only_run_is_bounded(self):
        self.plan({'readonly': 'hang'})
        r = self.run_runner('--skip-build', read_only_limit=2)
        self.assertEqual(r.returncode, 5)
        self.assertIn('gave no result within', r.last)
        self.assertLess(r.seconds, 20)


if __name__ == '__main__':
    unittest.main()
