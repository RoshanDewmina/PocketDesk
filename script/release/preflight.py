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

ROOT = pathlib.Path(__file__).resolve().parents[2]

def inspect(config_path, identities=None):
    config = json.loads(pathlib.Path(config_path).read_text())
    missing = []
    required = ['appAppleId', 'productionD1Id', 'developerIdIdentity', 'sparklePublicKey',
                'notaryKeychainProfile', 'supportURL', 'privacyURL', 'termsURL', 'exportComplianceReviewed']
    for key in required:
        if not config.get(key) or str(config[key]).startswith('REPLACE'):
            missing.append(key)
    try:
        if len(base64.b64decode(config.get('sparklePublicKey', ''), validate=True)) != 32:
            missing.append('valid 32-byte Ed25519 update public key')
    except (ValueError, binascii.Error):
        missing.append('valid 32-byte Ed25519 update public key')
    if not str(config.get('appAppleId', '')).isdigit():
        missing.append('numeric appAppleId')
    if not re.fullmatch(r'[a-fA-F0-9-]{36}', str(config.get('productionD1Id', ''))):
        missing.append('valid productionD1Id')
    if config.get('serviceOrigin') != 'https://signal.getfarside.com':
        missing.append('production service origin')
    for key in ['supportURL', 'privacyURL', 'termsURL']:
        if not str(config.get(key, '')).startswith('https://getfarside.com/'):
            missing.append(key + ' on getfarside.com')
    if identities is None:
        identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                    text=True, capture_output=True, check=False).stdout
    identity = config.get('developerIdIdentity', '')
    if not identity.startswith('Developer ID Application:') or identity not in identities:
        missing.append('installed Developer ID Application signing identity')
    if not config.get('serviceAcceptancePassed'):
        missing.append('production service acceptance receipt')
    if not config.get('physicalAcceptancePassed'):
        missing.append('exact-build physical acceptance receipt')
    return sorted(set(missing))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(ROOT / 'script/release/config.example.json'))
    args = parser.parse_args()
    try:
        missing = inspect(args.config)
    except (OSError, ValueError) as error:
        print(json.dumps({'ready': False, 'error': str(error)})); sys.exit(2)
    print(json.dumps({'ready': not missing, 'missing': missing}, indent=2))
    sys.exit(1 if missing else 0)
