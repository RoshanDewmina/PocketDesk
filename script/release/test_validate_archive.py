#!/usr/bin/env python3
"""Run archive metadata gates with fixture bundles; never sign or launch an app."""
import base64
import contextlib
import io
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


VALIDATOR = Path(__file__).with_name('validate_archive.py')
MAC_DEBUG_KEY = 'com.apple.security.get-task-allow'
IOS_DEBUG_KEY = 'get-task-allow'


class ArchiveFixture(unittest.TestCase):
    def validate(self, platform, debug_entitlements=None, *, mutate=None, service_ready=None):
        with tempfile.TemporaryDirectory(prefix='farside-archive-fixture-') as directory:
            app = Path(directory) / 'Farside.app'
            mac = platform == 'mac'
            resources = app / 'Contents/Resources' if mac else app
            resources.mkdir(parents=True)
            (resources / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyTracking': False}))
            (resources / 'ThirdPartyNotices.txt').touch()
            info = {
                'CFBundleIdentifier': 'com.roshan.PocketDesk.RemoteHost' if mac else 'com.roshan.PocketDesk.Remote',
                'CFBundleShortVersionString': '1.0',
                'CFBundleVersion': '20260929.11',
                'NSLocalNetworkUsageDescription': 'Connect to your paired Mac.',
            }
            entitlements = dict(debug_entitlements or {})
            if mac:
                info.update({
                    'PocketDeskServiceURL': 'wss://signal.getfarside.com/signal',
                    'SUPublicEDKey': base64.b64encode(bytes(32)).decode(),
                    'SUFeedURL': 'https://getfarside.com/mac/appcast.xml',
                })
            else:
                info.update({
                    'FarsideAPNSEnvironment': 'production',
                    'FarsideServiceBaseURL': 'https://signal.getfarside.com',
                    'FarsideServiceReady': 'NO',
                })
                entitlements.update({
                    'aps-environment': 'production',
                    'com.apple.developer.associated-domains': ['applinks:getfarside.com'],
                })
                for bundle, identifier in (('FarsideWidgets.appex', 'com.roshan.PocketDesk.Remote.Widgets'),
                                           ('FarsideShare.appex', 'com.roshan.PocketDesk.Remote.Share')):
                    extension = app / 'PlugIns' / bundle
                    extension.mkdir(parents=True)
                    (extension / 'Info.plist').write_bytes(plistlib.dumps({
                        'CFBundleIdentifier': identifier,
                        'CFBundleShortVersionString': info['CFBundleShortVersionString'],
                        'CFBundleVersion': info['CFBundleVersion'],
                    }))
                    (extension / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyTracking': False}))
            info_path = app / 'Contents/Info.plist' if mac else app / 'Info.plist'
            info_path.write_bytes(plistlib.dumps(info))
            if mutate:
                mutate(app, info_path)

            def codesign(command, **kwargs):
                if command == ['codesign', '-d', '--entitlements', ':-', str(app)]:
                    return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(entitlements))
                if command == ['codesign', '--verify', '--deep', '--strict', str(app)]:
                    return subprocess.CompletedProcess(command, 0)
                raise AssertionError(f'Unexpected external command: {command}')

            output = io.StringIO()
            argv = [str(VALIDATOR), str(app)]
            if service_ready is not None:
                argv += ['--service-ready', service_ready]
            with patch.object(sys, 'argv', argv), \
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


class ArchiveDebugEntitlementTests(ArchiveFixture):
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


class ArchiveMetadataTests(ArchiveFixture):
    @staticmethod
    def change_info(changes):
        def mutate(_app, info_path):
            info = plistlib.loads(info_path.read_bytes())
            for key, value in changes.items():
                if value is None:
                    info.pop(key, None)
                else:
                    info[key] = value
            info_path.write_bytes(plistlib.dumps(info))
        return mutate

    @staticmethod
    def change_widget(changes):
        def mutate(app, _info_path):
            path = app / 'PlugIns/FarsideWidgets.appex/Info.plist'
            info = plistlib.loads(path.read_bytes())
            info.update(changes)
            path.write_bytes(plistlib.dumps(info))
        return mutate

    def assert_invalid(self, platform, reason, *, mutate=None, service_ready=None):
        code, output = self.validate(platform, mutate=mutate, service_ready=service_ready)
        self.assertEqual(code, 1, output)
        self.assertIn(reason, output)

    def test_platform_specific_bundle_identity(self):
        for platform, wrong_id in (('mac', 'com.roshan.PocketDesk.Remote'),
                                   ('ios', 'com.roshan.PocketDesk.RemoteHost')):
            with self.subTest(platform=platform):
                self.assert_invalid(platform, 'Unexpected bundle identity for archive platform',
                                    mutate=self.change_info({'CFBundleIdentifier': wrong_id}))

    def test_phone_verification_url_is_exact(self):
        for url in ('https://signal-staging.getfarside.com', 'https://other.example',
                    'https://user:secret@signal.getfarside.com', 'https://signal.getfarside.com/verify',
                    'http://signal.getfarside.com', ''):
            with self.subTest(url=url):
                self.assert_invalid('ios', 'Unexpected phone verification service URL',
                                    mutate=self.change_info({'FarsideServiceBaseURL': url}))

    def test_readiness_accepts_only_exact_boolean_or_build_string(self):
        for expected, values in (('no', (False, 'NO')), ('yes', (True, 'YES'))):
            for value in values:
                with self.subTest(expected=expected, value=value):
                    code, output = self.validate('ios', mutate=self.change_info({'FarsideServiceReady': value}),
                                                 service_ready=expected)
                    self.assertEqual(code, 0, output)
                    self.assertIn('phone purchases disabled' if expected == 'no'
                                  else 'phone readiness marker matches yes', output)

    def test_readiness_rejects_absent_malformed_and_wrong_mode(self):
        cases = (('no', None), ('no', True), ('no', 'YES'), ('no', 'no'), ('no', 'false'),
                 ('no', '0'), ('no', 0), ('no', 1), ('no', '$(FARSIDE_SERVICE_READY)'),
                 ('yes', False), ('yes', 'NO'), ('yes', 'yes'), ('yes', 1))
        for expected, value in cases:
            with self.subTest(expected=expected, value=value):
                self.assert_invalid('ios', 'Phone service readiness does not match expected value',
                                    mutate=self.change_info({'FarsideServiceReady': value}),
                                    service_ready=expected)

    def test_widget_identity_version_build_and_manifest(self):
        cases = (
            ('Missing Farside widget extension', lambda app, _info: shutil.rmtree(app / 'PlugIns/FarsideWidgets.appex')),
            ('Unexpected Farside widget bundle identity', self.change_widget({'CFBundleIdentifier': 'other.widget'})),
            ('Farside widget CFBundleShortVersionString differs from phone', self.change_widget({'CFBundleShortVersionString': '0.9'})),
            ('Farside widget CFBundleVersion differs from phone', self.change_widget({'CFBundleVersion': '20260929.10'})),
            ('Invalid Farside widget Info.plist', lambda app, _info: (app / 'PlugIns/FarsideWidgets.appex/Info.plist').write_bytes(b'not a plist')),
            ('Missing Farside widget privacy manifest', lambda app, _info: (app / 'PlugIns/FarsideWidgets.appex/PrivacyInfo.xcprivacy').unlink()),
            ('Invalid Farside widget privacy manifest', lambda app, _info: (app / 'PlugIns/FarsideWidgets.appex/PrivacyInfo.xcprivacy').write_bytes(b'not a plist')),
        )
        for reason, mutate in cases:
            with self.subTest(reason=reason):
                self.assert_invalid('ios', reason, mutate=mutate)

    def test_share_extension_identity_version_and_manifest(self):
        share = 'PlugIns/FarsideShare.appex'
        cases = (
            ('Missing Send to My Mac extension', lambda app, _info: shutil.rmtree(app / share)),
            ('Unexpected Send to My Mac extension bundle identity',
             lambda app, _info: (app / share / 'Info.plist').write_bytes(plistlib.dumps({
                 **plistlib.loads((app / share / 'Info.plist').read_bytes()), 'CFBundleIdentifier': 'other.share'}))),
            ('Send to My Mac extension CFBundleVersion differs from phone',
             lambda app, _info: (app / share / 'Info.plist').write_bytes(plistlib.dumps({
                 **plistlib.loads((app / share / 'Info.plist').read_bytes()), 'CFBundleVersion': '1'}))),
            ('Missing Send to My Mac extension privacy manifest', lambda app, _info: (app / share / 'PrivacyInfo.xcprivacy').unlink()),
        )
        for reason, mutate in cases:
            with self.subTest(reason=reason):
                self.assert_invalid('ios', reason, mutate=mutate)

    def test_missing_main_privacy_manifest_is_rejected(self):
        for platform in ('mac', 'ios'):
            with self.subTest(platform=platform):
                def mutate(app, _info_path):
                    resources = app / 'Contents/Resources' if platform == 'mac' else app
                    (resources / 'PrivacyInfo.xcprivacy').unlink()
                self.assert_invalid(platform, 'Missing privacy manifest', mutate=mutate)

    def test_invalid_privacy_manifests_are_rejected(self):
        invalid = (
            ('empty', b''),
            ('malformed', b'not a plist'),
            ('truncated XML', b'<?xml version="1.0"?><plist><dict>'),
            ('truncated binary', b'bplist00'),
            ('XML array', plistlib.dumps([], fmt=plistlib.FMT_XML)),
            ('binary array', plistlib.dumps([], fmt=plistlib.FMT_BINARY)),
            ('XML scalar', plistlib.dumps('text', fmt=plistlib.FMT_XML)),
            ('binary scalar', plistlib.dumps(False, fmt=plistlib.FMT_BINARY)),
            ('directory', None),
        )
        for platform, widget in (('mac', False), ('ios', False), ('ios', True)):
            for case, content in invalid:
                with self.subTest(platform=platform, widget=widget, case=case):
                    def mutate(app, _info_path):
                        resources = (app / 'PlugIns/FarsideWidgets.appex' if widget else
                                     app / 'Contents/Resources' if platform == 'mac' else app)
                        manifest = resources / 'PrivacyInfo.xcprivacy'
                        if content is None:
                            manifest.unlink()
                            manifest.mkdir()
                        else:
                            manifest.write_bytes(content)
                    reason = ('Invalid Farside widget privacy manifest' if widget
                              else 'Invalid privacy manifest')
                    self.assert_invalid(platform, reason, mutate=mutate)

    def test_xml_and_binary_dictionary_privacy_manifests_are_accepted(self):
        for platform in ('mac', 'ios'):
            for format in (plistlib.FMT_XML, plistlib.FMT_BINARY):
                with self.subTest(platform=platform, format=format):
                    def mutate(app, _info_path):
                        resources = app / 'Contents/Resources' if platform == 'mac' else app
                        manifest = plistlib.dumps({'NSPrivacyTracking': False}, fmt=format)
                        (resources / 'PrivacyInfo.xcprivacy').write_bytes(manifest)
                        if platform == 'ios':
                            (app / 'PlugIns/FarsideWidgets.appex/PrivacyInfo.xcprivacy').write_bytes(manifest)
                    code, output = self.validate(platform, mutate=mutate)
                    self.assertEqual(code, 0, output)
                    self.assertIn('Archive metadata checks passed', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
