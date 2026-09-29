#!/usr/bin/env python3
"""Validate local archive metadata without sending it anywhere."""
import base64, binascii, pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
plist = app / 'Contents/Info.plist'
mac = plist.exists()
if not mac:
    plist = app / 'Info.plist'
info = plistlib.loads(plist.read_bytes())
errors = []
identifier = info.get('CFBundleIdentifier')
if identifier not in ['com.roshan.PocketDesk.RemoteHost', 'com.roshan.PocketDesk.Remote']:
    errors.append('Unexpected bundle identity')
if info.get('CFBundleShortVersionString') != '1.0': errors.append('Release version must be 1.0')
resources = app / 'Contents/Resources' if mac else app
if not (resources / 'PrivacyInfo.xcprivacy').exists(): errors.append('Missing privacy manifest')
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
print('Archive metadata checks ' + ('FAILED' if errors else 'passed; signing and live acceptance remain separate'))
sys.exit(1 if errors else 0)
