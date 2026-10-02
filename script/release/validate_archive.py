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


# Reviewed first-party inventory, not an exhaustive list of Apple's permitted reasons.
# Refresh against Apple's live privacy-manifest documentation when target usage changes.
DEFAULTS = 'NSPrivacyAccessedAPICategoryUserDefaults'
FILE_TIMESTAMPS = 'NSPrivacyAccessedAPICategoryFileTimestamp'
MAIN_APIS = {
    DEFAULTS: {'CA92.1'},
    'NSPrivacyAccessedAPICategorySystemBootTime': {'35F9.1', '8FFB.1'},
    FILE_TIMESTAMPS: {'3B52.1', 'C617.1'},
    'NSPrivacyAccessedAPICategoryDiskSpace': {'E174.1'},
}
MAIN_DATA = {'NSPrivacyCollectedDataTypeDeviceID', 'NSPrivacyCollectedDataTypePurchaseHistory'}
PRIVACY_INVENTORY = {
    'host': (MAIN_APIS, MAIN_DATA),
    'phone': ({**MAIN_APIS, DEFAULTS: {'CA92.1', '1C8F.1'}},
              MAIN_DATA | {'NSPrivacyCollectedDataTypeProductInteraction'}),
    'widget': ({DEFAULTS: {'1C8F.1'}}, set()),
    # ShareShared's staged-content protection switch reads standard defaults in the
    # extension path. The app-only SendToMacFileIO initializer also references them.
    'share': ({DEFAULTS: {'CA92.1'}, FILE_TIMESTAMPS: {'3B52.1', 'C617.1'}}, set()),
}


def string_array(value, *, nonempty=False):
    return (isinstance(value, list) and (bool(value) or not nonempty)
            and all(isinstance(item, str) and item.strip() for item in value)
            and len(value) == len(set(value)))


def validate_privacy_manifest(path, label, errors, target):
    if not path.exists():
        errors.append('Missing ' + label)
        return
    try:
        manifest = plistlib.loads(path.read_bytes())
        if not isinstance(manifest, dict):
            raise ValueError('privacy manifest must be a dictionary')
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
        errors.append('Invalid ' + label)
        return

    def invalid(detail):
        errors.append('Invalid ' + label + ': ' + detail)

    required_keys = {'NSPrivacyTracking', 'NSPrivacyTrackingDomains',
                     'NSPrivacyAccessedAPITypes', 'NSPrivacyCollectedDataTypes'}
    if set(manifest) != required_keys:
        invalid('top-level keys differ from reviewed inventory')
    if type(manifest.get('NSPrivacyTracking')) is not bool:
        invalid('NSPrivacyTracking must be a Boolean')
    elif manifest['NSPrivacyTracking']:
        invalid('tracking differs from reviewed no-tracking inventory')
    domains = manifest.get('NSPrivacyTrackingDomains')
    if not string_array(domains) or domains:
        invalid('NSPrivacyTrackingDomains must be an empty array for this inventory')

    expected_apis, expected_data = PRIVACY_INVENTORY[target]
    apis = manifest.get('NSPrivacyAccessedAPITypes')
    seen_apis = set()
    if not isinstance(apis, list):
        invalid('NSPrivacyAccessedAPITypes must be an array')
    else:
        for entry in apis:
            if not isinstance(entry, dict) or set(entry) != {'NSPrivacyAccessedAPIType', 'NSPrivacyAccessedAPITypeReasons'}:
                invalid('accessed API entry has invalid fields')
                continue
            category = entry['NSPrivacyAccessedAPIType']
            if not isinstance(category, str) or category not in expected_apis:
                invalid('accessed API category is outside reviewed inventory')
                continue
            if category in seen_apis:
                invalid('duplicate accessed API category ' + category)
            seen_apis.add(category)
            reasons = entry['NSPrivacyAccessedAPITypeReasons']
            if not string_array(reasons, nonempty=True):
                invalid(category + ' reasons must be a nonempty array of unique strings')
            elif set(reasons) != expected_apis[category]:
                invalid(category + ' reasons differ from reviewed inventory; expected ' +
                        ', '.join(sorted(expected_apis[category])))
    for category in sorted(set(expected_apis) - seen_apis):
        invalid('missing required API category ' + category)

    collected = manifest.get('NSPrivacyCollectedDataTypes')
    seen_data = set()
    if not isinstance(collected, list):
        invalid('NSPrivacyCollectedDataTypes must be an array')
    else:
        for entry in collected:
            keys = {'NSPrivacyCollectedDataType', 'NSPrivacyCollectedDataTypeLinked',
                    'NSPrivacyCollectedDataTypeTracking', 'NSPrivacyCollectedDataTypePurposes'}
            if not isinstance(entry, dict) or set(entry) != keys:
                invalid('collected data entry has invalid fields')
                continue
            data_type = entry['NSPrivacyCollectedDataType']
            if not isinstance(data_type, str) or data_type not in expected_data:
                invalid('collected data type is outside reviewed inventory')
                continue
            if data_type in seen_data:
                invalid('duplicate collected data type ' + data_type)
            seen_data.add(data_type)
            linked = entry['NSPrivacyCollectedDataTypeLinked']
            tracking = entry['NSPrivacyCollectedDataTypeTracking']
            if type(linked) is not bool or type(tracking) is not bool:
                invalid(data_type + ' linked/tracking fields must be Booleans')
            elif not linked or tracking:
                invalid(data_type + ' linked/tracking fields differ from reviewed inventory')
            purposes = entry['NSPrivacyCollectedDataTypePurposes']
            if not string_array(purposes, nonempty=True):
                invalid(data_type + ' purposes must be a nonempty array of unique strings')
            elif purposes != ['NSPrivacyCollectedDataTypePurposeAppFunctionality']:
                invalid(data_type + ' purposes differ from reviewed inventory')
    for data_type in sorted(expected_data - seen_data):
        invalid('missing required collected data type ' + data_type)

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
validate_privacy_manifest(resources / 'PrivacyInfo.xcprivacy', 'privacy manifest', errors,
                          'host' if mac else 'phone')
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
        validate_privacy_manifest(extension / 'PrivacyInfo.xcprivacy', label + ' privacy manifest', errors,
                                  'widget' if bundle == 'FarsideWidgets.appex' else 'share')
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
