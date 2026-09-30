#!/usr/bin/env python3
"""Validate local archive metadata without sending it anywhere."""
import argparse
import base64
import binascii
import pathlib
import plistlib
import subprocess
import sys
from xml.parsers.expat import ExpatError


def validate_privacy_manifest(path, label, errors):
    if not path.exists():
        errors.append('Missing ' + label)
        return
    try:
        if not isinstance(plistlib.loads(path.read_bytes()), dict):
            raise ValueError('privacy manifest must be a dictionary')
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
        errors.append('Invalid ' + label)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--service-ready', choices=('no', 'yes'), default='no',
                    help='Expected phone Info.plist readiness; this never enables purchases')
args = parser.parse_args()
app = args.app
plist = app / 'Contents/Info.plist'
mac = plist.exists()
if not mac:
    plist = app / 'Info.plist'
info = plistlib.loads(plist.read_bytes())
errors = []
identifier = info.get('CFBundleIdentifier')
expected_identifier = 'com.roshan.PocketDesk.RemoteHost' if mac else 'com.roshan.PocketDesk.Remote'
if identifier != expected_identifier:
    errors.append('Unexpected bundle identity for archive platform')
if info.get('CFBundleShortVersionString') != '1.0': errors.append('Release version must be 1.0')
resources = app / 'Contents/Resources' if mac else app
validate_privacy_manifest(resources / 'PrivacyInfo.xcprivacy', 'privacy manifest', errors)
if not (resources / 'ThirdPartyNotices.txt').exists(): errors.append('Missing dependency notices')
if not info.get('NSLocalNetworkUsageDescription'): errors.append('Missing local network explanation')
if mac:
    if info.get('PocketDeskServiceURL') != 'wss://signal.getfarside.com/signal': errors.append('Missing production signal origin')
    try:
        if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32:
            errors.append('Invalid update signing public key')
    except (ValueError, binascii.Error):
        errors.append('Invalid update signing public key')
    if info.get('SUFeedURL') != 'https://getfarside.com/mac/appcast.xml': errors.append('Unexpected update feed')
else:
    if info.get('FarsideServiceBaseURL') != 'https://signal.getfarside.com':
        errors.append('Unexpected phone verification service URL')
    readiness = info.get('FarsideServiceReady')
    accepted = (False, 'NO') if args.service_ready == 'no' else (True, 'YES')
    if not any(type(readiness) is type(value) and readiness == value for value in accepted):
        errors.append('Phone service readiness does not match expected value')
    extensions = (('FarsideWidgets.appex', 'com.roshan.PocketDesk.Remote.Widgets', 'Farside widget'),
                  ('FarsideShare.appex', 'com.roshan.PocketDesk.Remote.Share', 'Send to My Mac extension'))
    for bundle, expected_extension_identifier, label in extensions:
        extension = app / 'PlugIns' / bundle
        extension_plist = extension / 'Info.plist'
        if not extension_plist.exists():
            errors.append('Missing ' + label + ('' if label.endswith('extension') else ' extension'))
        else:
            try:
                extension_info = plistlib.loads(extension_plist.read_bytes())
                if not isinstance(extension_info, dict):
                    raise ValueError('extension Info.plist must be a dictionary')
            except (OSError, ValueError, plistlib.InvalidFileException):
                errors.append('Invalid ' + label + ' Info.plist')
            else:
                if extension_info.get('CFBundleIdentifier') != expected_extension_identifier:
                    errors.append('Unexpected ' + label + ' bundle identity')
                for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
                    if extension_info.get(key) != info.get(key) or not info.get(key):
                        errors.append(label + ' ' + key + ' differs from phone')
        validate_privacy_manifest(extension / 'PrivacyInfo.xcprivacy', label + ' privacy manifest', errors)
result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True)
if result.returncode: errors.append('Could not read signed entitlements')
verified = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True)
if verified.returncode: errors.append('Code signature validation failed')
try:
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
except plistlib.InvalidFileException:
    entitlements = {}; errors.append('Unreadable signed entitlements')
if not mac:
    if entitlements.get('aps-environment') != 'production': errors.append('Distribution must use production APNs')
    if info.get('FarsideAPNSEnvironment') != entitlements.get('aps-environment'): errors.append('APNs configuration differs from signed entitlement')
    if entitlements.get('com.apple.developer.associated-domains') != ['applinks:getfarside.com']: errors.append('Associated domain differs from AASA')
if entitlements.get('com.apple.security.get-task-allow') or entitlements.get('get-task-allow'):
    errors.append('Distribution enables get-task-allow')
if entitlements.get('com.apple.security.cs.disable-library-validation'): errors.append('Distribution disables library validation')
for error in errors: print(error)
if errors:
    print('Archive metadata checks FAILED')
else:
    phone_state = ('phone purchases disabled by readiness' if args.service_ready == 'no'
                   else 'phone readiness marker matches yes') if not mac else 'phone readiness not applicable'
    print('Archive metadata checks passed; ' + phone_state +
          '; live service, purchase, signing identity and submission acceptance remain separate')
sys.exit(1 if errors else 0)
