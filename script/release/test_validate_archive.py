#!/usr/bin/env python3
"""Run archive metadata gates with fixture bundles; never sign or launch an app."""
import base64
import contextlib
import io
from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


VALIDATOR = Path(__file__).with_name('validate_archive.py')
MAC_DEBUG_KEY = 'com.apple.security.get-task-allow'
IOS_DEBUG_KEY = 'get-task-allow'


class ArchiveDebugEntitlementTests(unittest.TestCase):
    def validate(self, platform, debug_entitlements):
        with tempfile.TemporaryDirectory(prefix='farside-archive-fixture-') as directory:
            app = Path(directory) / 'Farside.app'
            mac = platform == 'mac'
            resources = app / 'Contents/Resources' if mac else app
            resources.mkdir(parents=True)
            (resources / 'PrivacyInfo.xcprivacy').touch()
            (resources / 'ThirdPartyNotices.txt').touch()
            info = {
                'CFBundleIdentifier': 'com.roshan.PocketDesk.RemoteHost' if mac else 'com.roshan.PocketDesk.Remote',
                'CFBundleShortVersionString': '1.0',
                'NSLocalNetworkUsageDescription': 'Connect to your paired Mac.',
            }
            entitlements = dict(debug_entitlements)
            if mac:
                info.update({
                    'PocketDeskServiceURL': 'wss://signal.getfarside.com/signal',
                    'SUPublicEDKey': base64.b64encode(bytes(32)).decode(),
                    'SUFeedURL': 'https://getfarside.com/mac/appcast.xml',
                })
            else:
                info['FarsideAPNSEnvironment'] = 'production'
                entitlements.update({
                    'aps-environment': 'production',
                    'com.apple.developer.associated-domains': ['applinks:getfarside.com'],
                })
            info_path = app / 'Contents/Info.plist' if mac else app / 'Info.plist'
            info_path.write_bytes(plistlib.dumps(info))

            def codesign(command, **kwargs):
                if command == ['codesign', '-d', '--entitlements', ':-', str(app)]:
                    return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(entitlements))
                if command == ['codesign', '--verify', '--deep', '--strict', str(app)]:
                    return subprocess.CompletedProcess(command, 0)
                raise AssertionError(f'Unexpected external command: {command}')

            output = io.StringIO()
            with patch.object(sys, 'argv', [str(VALIDATOR), str(app)]), \
                    patch('subprocess.run', side_effect=codesign) as signing, \
                    contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as exit_result:
                runpy.run_path(str(VALIDATOR), run_name='__main__')
            self.assertEqual(signing.call_count, 2)
            return exit_result.exception.code, output.getvalue()

    def assert_rejected(self, platform, entitlements):
        code, output = self.validate(platform, entitlements)
        self.assertEqual(code, 1, output)
        self.assertIn('Distribution enables get-task-allow', output)
        self.assertIn('Archive metadata checks FAILED', output)

    def test_mac_debug_entitlement_is_rejected(self):
        for platform in ('mac', 'ios'):
            with self.subTest(platform=platform):
                self.assert_rejected(platform, {MAC_DEBUG_KEY: True})

    def test_ios_debug_entitlement_is_rejected(self):
        for platform in ('mac', 'ios'):
            with self.subTest(platform=platform):
                self.assert_rejected(platform, {IOS_DEBUG_KEY: True})

    def test_absent_and_false_debug_entitlements_are_accepted(self):
        for platform in ('mac', 'ios'):
            for entitlements in ({}, {MAC_DEBUG_KEY: False}, {IOS_DEBUG_KEY: False},
                                 {MAC_DEBUG_KEY: False, IOS_DEBUG_KEY: False}):
                with self.subTest(platform=platform, entitlements=entitlements):
                    code, output = self.validate(platform, entitlements)
                    self.assertEqual(code, 0, output)
                    self.assertIn('Archive metadata checks passed', output)

    def test_false_key_cannot_mask_other_unsafe_key(self):
        for platform in ('mac', 'ios'):
            for entitlements in ({MAC_DEBUG_KEY: False, IOS_DEBUG_KEY: True},
                                 {MAC_DEBUG_KEY: True, IOS_DEBUG_KEY: False},
                                 {MAC_DEBUG_KEY: False, IOS_DEBUG_KEY: 1},
                                 {MAC_DEBUG_KEY: 'YES', IOS_DEBUG_KEY: False}):
                with self.subTest(platform=platform, entitlements=entitlements):
                    self.assert_rejected(platform, entitlements)


if __name__ == '__main__':
    unittest.main(verbosity=2)
