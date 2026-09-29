#!/usr/bin/env python3
"""Local release-config fixtures; identities are injected, never queried."""
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch


PREFLIGHT = Path(__file__).with_name('preflight.py')
SPEC = importlib.util.spec_from_file_location('release_preflight', PREFLIGHT)
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)
IDENTITY = 'Developer ID Application: Fixture Publisher (ABCDE12345)'
IDENTITIES = f'  1) {"a" * 40} "{IDENTITY}"\n     1 valid identities found\n'


class PreflightFixture(unittest.TestCase):
    def setUp(self):
        self.config = {
            'serviceOrigin': 'https://signal.getfarside.com',
            'appAppleId': '1234567890',
            'productionD1Id': '9c1bcbfb-5786-4c0d-87cf-83ed143d7875',
            'developerIdIdentity': IDENTITY,
            'sparklePublicKey': base64.b64encode(bytes(range(32))).decode('ascii'),
            'notaryKeychainProfile': 'fixture-profile',
            'supportURL': 'https://getfarside.com/support',
            'privacyURL': 'https://getfarside.com/privacy',
            'termsURL': 'https://getfarside.com/terms',
            'exportComplianceReviewed': True,
            'serviceAcceptancePassed': True,
            'physicalAcceptancePassed': True,
        }

    def inspect(self, config):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            path.write_text(json.dumps(config))
            return preflight.inspect(path, identities=IDENTITIES)

    def assert_rejected(self, key, values, expected):
        for value in values:
            with self.subTest(key=key, value=value):
                config = self.config.copy()
                config[key] = value
                self.assertIn(expected, self.inspect(config))

    def test_valid_config_with_injected_identity(self):
        self.assertEqual(self.inspect(self.config), [])
        other_valid_uuid = self.config.copy()
        other_valid_uuid['productionD1Id'] = '9c1bcbfb-5786-1c0d-87cf-83ed143d7875'
        self.assertEqual(self.inspect(other_valid_uuid), [])

    def test_acceptance_gates_require_json_true(self):
        for key, label in (
            ('exportComplianceReviewed', 'exportComplianceReviewed'),
            ('serviceAcceptancePassed', 'production service acceptance receipt'),
            ('physicalAcceptancePassed', 'exact-build physical acceptance receipt'),
        ):
            self.assert_rejected(key, [False, 'true', 'yes', '1', 1, [], {}], label)

    def test_apple_id_is_ascii_positive_decimal_string(self):
        self.assert_rejected('appAppleId', [0, 123456, True, '0', '00123',
                                            '１２３', '١٢٣', '123 ', '+123', 'REPLACE_ID'],
                             'numeric appAppleId')

    def test_production_d1_is_canonical_nonplaceholder_uuid(self):
        self.assert_rejected('productionD1Id', [
            '------------------------------------',
            '00000000-0000-0000-0000-000000000000',
            '11111111-1111-4111-8111-111111111111',
            '12345678-1234-4234-8234-123456789abc',
            '5b916903-865e-4659-b359-e8ef333167bd',  # committed staging DB
            '9C1BCBFB-5786-4C0D-87CF-83ED143D7875',
            '9c1bcbfb57861c0d87cf83ed143d7875',
            42,
        ], 'valid productionD1Id')

    def test_fixed_service_origin(self):
        self.assert_rejected('serviceOrigin', [
            'http://signal.getfarside.com',
            'https://signal.getfarside.com/',
            'https://signal.getfarside.com.evil.test',
            'https://signal.getfarside.com:443',
            'https://signal.getfarside.com ',
        ], 'production service origin')

    def test_support_urls_have_exact_https_origin_and_safe_syntax(self):
        invalid = [
            'http://getfarside.com/support',
            'https://getfarside.com.evil.test/support',
            'https://user@getfarside.com/support',
            'https://getfarside.com:443/support',
            'https://getfarside.com/\\evil.test/support',
            'https://getfarside.com//evil.test/support',
            'https://getfarside.com/%5cevil.test/support',
            'https://getfarside.com/%2f/evil.test/support',
            'https://getfarside.com/support%0a',
            'https://getfarside.com/support\n',
            'https://getfarside.com/sup port',
            'https://getfarside.com/#fragment',
            'https://getfarside.com',
            123,
        ]
        for key in ('supportURL', 'privacyURL', 'termsURL'):
            self.assert_rejected(key, invalid, f'{key} on getfarside.com')

    def test_identity_and_update_key_still_gate(self):
        self.assert_rejected('developerIdIdentity', [None, 123, 'Apple Development: Fixture',
                                                      'Developer ID Application: Other',
                                                      'Developer ID Application: Fixture Publisher'],
                             'installed Developer ID Application signing identity')
        self.assert_rejected('sparklePublicKey', [123, 'REPLACE_KEY',
                                                   base64.b64encode(bytes(31)).decode('ascii')],
                             'valid 32-byte Ed25519 update public key')

    def test_nonobject_config_is_concise_error(self):
        for config in ([], None, 'text', 123):
            with self.subTest(config=config), self.assertRaisesRegex(ValueError, 'JSON object'):
                self.inspect(config)

    def test_malformed_json_is_concise_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            path.write_text('{')
            with self.assertRaisesRegex(ValueError, 'invalid release config JSON'):
                preflight.inspect(path, identities=IDENTITY)

    def test_cli_bad_json_exits_two_with_json_error(self):
        for content in ('{', '[]'):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'config.json'
                path.write_text(content)
                output = io.StringIO()
                with patch.object(sys, 'argv', [str(PREFLIGHT), '--config', str(path)]):
                    with contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as exit_result:
                        runpy.run_path(str(PREFLIGHT), run_name='__main__')
                self.assertEqual(exit_result.exception.code, 2)
                self.assertEqual(json.loads(output.getvalue())['ready'], False)


if __name__ == '__main__':
    unittest.main()
