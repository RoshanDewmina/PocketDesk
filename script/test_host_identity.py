#!/usr/bin/env python3
"""Exercise the guard with real, temporary signed apps; never launch any app."""
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
INSTALLED = Path('/Applications/PocketDesk Host.app')
BUNDLE_ID = 'com.roshan.PocketDesk.RemoteHost'


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True)


class HostIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        details = run('/usr/bin/codesign', '-dvv', str(INSTALLED)).stderr
        cls.signer = next(line.removeprefix('Authority=') for line in details.splitlines()
                          if line.startswith('Authority=Apple Development:'))
        cls.scratch = tempfile.TemporaryDirectory(prefix='pocketdesk-identity-tests-')
        cls.directory = Path(cls.scratch.name)
        cls.addClassCleanup(cls.scratch.cleanup)
        for version in (1, 2):
            source = cls.directory / f'main{version}.c'
            source.write_text(f'int main(void) {{ return {version}; }}\n')
            run('/usr/bin/xcrun', 'clang', str(source), '-o', str(cls.directory / f'bin{version}'))
        cls.previous = cls.fixture('previous')

    @classmethod
    def fixture(cls, name, *, version=1, signer=None, requirement=None, bundle_id=BUNDLE_ID):
        app = cls.directory / f'{name}.app'
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        with (contents / 'Info.plist').open('wb') as handle:
            plistlib.dump({'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'Host',
                          'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(version)}, handle)
        binary = contents / 'MacOS/Host'
        binary.write_bytes((cls.directory / f'bin{version}').read_bytes())
        binary.chmod(0o755)
        args = ['/usr/bin/codesign', '--force', '--sign', signer or cls.signer, '--timestamp=none']
        if requirement:
            args.append(f'-r={requirement}')
        run(*args, str(app))
        return app

    def check_guard(self, candidate, *, accepted, previous=None):
        result = subprocess.run(['/bin/zsh', str(ROOT / 'script/verify_host_identity.sh'),
                                 str(previous or self.previous), str(candidate)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
        return result

    def test_changed_binary_same_identity_passes(self):
        updated = self.fixture('updated', version=2)
        self.assertNotEqual(hashlib.sha256((self.previous / 'Contents/MacOS/Host').read_bytes()).digest(),
                            hashlib.sha256((updated / 'Contents/MacOS/Host').read_bytes()).digest())
        self.check_guard(updated, accepted=True)

    def test_same_team_changed_requirement_rejected(self):
        candidate = self.fixture('changed-requirement', requirement=
                                 f'designated => identifier "{BUNDLE_ID}" and anchor apple generic')
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(candidate))
        result = self.check_guard(candidate, accepted=False)
        self.assertIn('signing identity changed', result.stderr)

    def test_adhoc_rejected(self):
        self.check_guard(self.fixture('adhoc', signer='-'), accepted=False)

    def test_tampered_bundle_rejected(self):
        candidate = self.fixture('tampered')
        (candidate / 'Contents/MacOS/Host').write_bytes(b'invalid executable')
        self.check_guard(candidate, accepted=False)

    def test_unrelated_identifier_rejected(self):
        self.check_guard(self.fixture('unrelated', bundle_id='com.example.Unrelated'), accepted=False)

    def test_missing_bundle_rejected(self):
        self.check_guard(self.directory / 'missing.app', accepted=False)

    def test_current_real_update_passes_read_only(self):
        self.check_guard(ROOT / 'outputs/RemoteBuild/Build/Products/Debug/PocketDeskRemoteHost.app',
                         previous=INSTALLED, accepted=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
