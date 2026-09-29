#!/usr/bin/env python3
"""Read-only release gate. Reports missing inputs; never deploys or creates credentials."""
import argparse
import base64
import binascii
import json
import pathlib
import re
import subprocess
import sys
import uuid
from urllib.parse import unquote_to_bytes, urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[2]
STAGING_D1_ID = '5b916903-865e-4659-b359-e8ef333167bd'
PLACEHOLDER_D1_IDS = {
    '00000000-0000-0000-0000-000000000000',
    '11111111-1111-4111-8111-111111111111',
    '12345678-1234-4234-8234-123456789abc',
}


def configured_string(value):
    return (isinstance(value, str) and bool(value) and value == value.strip()
            and not value.startswith('REPLACE')
            and all(ord(character) >= 32 and ord(character) != 127 for character in value))


def production_d1_id(value):
    if not configured_string(value) or value == STAGING_D1_ID or value in PLACEHOLDER_D1_IDS:
        return False
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        return False
    # Canonical syntax and known placeholders only; resource existence is external.
    return parsed.int != 0 and str(parsed) == value


def public_url(value):
    if not configured_string(value) or '\\' in value or any(c.isspace() for c in value):
        return False
    try:
        parsed = urlsplit(value)
        decoded = unquote_to_bytes(value).decode('utf-8')
    except (ValueError, UnicodeDecodeError):
        return False
    return (parsed.scheme == 'https' and parsed.netloc == 'getfarside.com'
            and parsed.path.startswith('/') and not parsed.path.startswith('//')
            and not parsed.fragment and not re.search(r'%(?![0-9a-fA-F]{2})', value)
            and '\\' not in decoded and not any(c.isspace() or ord(c) < 32 or ord(c) == 127
                                            for c in decoded)
            and not urlsplit(decoded).path.startswith('//'))


def installed_identity(value, identities):
    if not configured_string(value) or not value.startswith('Developer ID Application:'):
        return False
    for line in identities.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+[0-9a-fA-F]{40}\s+"([^"]+)"\s*', line)
        if match and match.group(1) == value:
            return True
    return False


def inspect(config_path, identities=None):
    try:
        config = json.loads(pathlib.Path(config_path).read_text())
    except json.JSONDecodeError as error:
        raise ValueError(f'invalid release config JSON at line {error.lineno}, column {error.colno}') from None
    if not isinstance(config, dict):
        raise ValueError('release config must be a JSON object')
    missing = []
    required = ['appAppleId', 'productionD1Id', 'developerIdIdentity', 'sparklePublicKey',
                'notaryKeychainProfile', 'supportURL', 'privacyURL', 'termsURL']
    for key in required:
        if not configured_string(config.get(key)):
            missing.append(key)
    if config.get('exportComplianceReviewed') is not True:
        missing.append('exportComplianceReviewed')
    try:
        key = config.get('sparklePublicKey')
        if not configured_string(key) or len(base64.b64decode(key, validate=True)) != 32:
            missing.append('valid 32-byte Ed25519 update public key')
    except (ValueError, binascii.Error):
        missing.append('valid 32-byte Ed25519 update public key')
    if not isinstance(config.get('appAppleId'), str) or not re.fullmatch(r'[1-9][0-9]*', config['appAppleId']):
        missing.append('numeric appAppleId')
    if not production_d1_id(config.get('productionD1Id')):
        missing.append('valid productionD1Id')
    if config.get('serviceOrigin') != 'https://signal.getfarside.com':
        missing.append('production service origin')
    for key in ['supportURL', 'privacyURL', 'termsURL']:
        if not public_url(config.get(key)):
            missing.append(key + ' on getfarside.com')
    if identities is None:
        identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                    text=True, capture_output=True, check=False).stdout
    identity = config.get('developerIdIdentity', '')
    if not installed_identity(identity, identities):
        missing.append('installed Developer ID Application signing identity')
    if config.get('serviceAcceptancePassed') is not True:
        missing.append('production service acceptance receipt')
    if config.get('physicalAcceptancePassed') is not True:
        missing.append('exact-build physical acceptance receipt')
    return sorted(set(missing))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(ROOT / 'script/release/config.example.json'))
    args = parser.parse_args()
    try:
        missing = inspect(args.config)
    except (OSError, ValueError) as error:
        print(json.dumps({'ready': False, 'error': str(error)}))
        sys.exit(2)
    print(json.dumps({'ready': not missing, 'missing': missing}, indent=2))
    sys.exit(1 if missing else 0)
