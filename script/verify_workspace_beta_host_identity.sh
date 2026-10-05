#!/bin/zsh
# Read-only preflight. Never repair/reset permission records or modify binaries.
set -euo pipefail
if (( $# != 2 )); then
  print -u2 'Usage: verify_workspace_beta_host_identity.sh INSTALLED_BETA_APP CANDIDATE_BETA_APP'
  exit 2
fi
/usr/bin/python3 - "$1" "$2" <<'PY'
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

TEAM = '39HM2X8GS6'
BETA_ID = 'com.roshan.PocketDesk.WorkspaceBetaHost'
PRODUCTION_ID = 'com.roshan.PocketDesk.RemoteHost'
EXECUTABLE = 'PocketDeskRemoteHost'
PRODUCTION = Path('/Applications/PocketDesk Host.app')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    require(result.returncode == 0, f'Command failed ({result.returncode}): {args[0]}\n{result.stderr}')
    return result.stdout + result.stderr


def bundle(path, expected_id, beta):
    require(path.is_dir() and not path.is_symlink(), f'Expected a regular app bundle: {path}')
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == expected_id, f'Unexpected bundle ID: {path}')
    if beta:
        require(info.get('FarsideWorkspaceBeta') is True, f'Boolean beta marker missing: {path}')
    else:
        require('FarsideWorkspaceBeta' not in info, 'Production unexpectedly has a beta marker.')
    require(info.get('CFBundleExecutable') == EXECUTABLE, f'Host executable name changed: {path}')
    executable = path / 'Contents/MacOS' / EXECUTABLE
    require(executable.is_file() and not executable.is_symlink(), f'Missing regular main executable: {path}')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(path))
    identity = run('/usr/bin/codesign', '-dv', str(path))
    require(f'TeamIdentifier={TEAM}' in identity.splitlines() and 'Signature=adhoc' not in identity,
            f'Expected stable Apple development team: {path}')
    require(f'Identifier={expected_id}' in identity.splitlines(), f'Signing identifier mismatch: {path}')
    designated = run('/usr/bin/codesign', '-d', '-r-', str(path))
    requirements = [line.removeprefix('designated => ') for line in designated.splitlines()
                    if line.startswith('designated => ')]
    require(len(requirements) == 1 and requirements[0] and 'cdhash' not in requirements[0],
            f'Missing or build-specific designated requirement: {path}')
    output = run('/usr/bin/dwarfdump', '--uuid', str(executable))
    lines = [line for line in output.splitlines() if line.strip()]
    rows = [re.fullmatch(r'UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\) .+', line) for line in lines]
    require(bool(rows) and all(rows), f'Cannot establish every main executable UUID: {path}')
    uuids = {row.group(2): row.group(1).upper() for row in rows}
    require(len(uuids) == len(rows) and all(u != '00000000-0000-0000-0000-000000000000' for u in uuids.values()),
            f'Invalid or repeated main executable architecture UUID: {path}')
    return {'path': str(path), 'bundleID': expected_id, 'version': info.get('CFBundleVersion'),
            'executable': str(executable), 'mainUUIDs': uuids, 'requirement': requirements[0]}


try:
    installed = bundle(Path(sys.argv[1]), BETA_ID, True)
    candidate = bundle(Path(sys.argv[2]), BETA_ID, True)
    production = bundle(PRODUCTION, PRODUCTION_ID, False)
    # Compare literal requirements and validate against the installed requirement.
    # Even an equivalent rewrite requires an explicit identity migration review.
    require(installed['requirement'] == candidate['requirement'],
            'Beta designated requirement changed; stopped before touching the running app.')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict',
        '-R=' + installed['requirement'], candidate['path'])
    require(set(candidate['mainUUIDs']) == {'arm64'}, 'Beta candidate must remain arm64 only.')
    collisions = set(candidate['mainUUIDs'].values()) & set(production['mainUUIDs'].values())
    require(not collisions, 'Candidate main UUID collides with production: ' + ', '.join(sorted(collisions)))
    # A fresh build with the beta host Debug target override must link its actual
    # application code into the main executable. Do not patch LC_UUID after link.
    macos = Path(candidate['path']) / 'Contents/MacOS'
    require(not list(macos.glob('*.debug.dylib')) and not (macos / '__preview.dylib').exists(),
            'Candidate still contains the Debug dylib launcher layout; use a fresh derived-data path.')
    dependencies = run('/usr/bin/otool', '-L', candidate['executable'])
    require('.debug.dylib' not in dependencies and '__preview.dylib' not in dependencies,
            'Candidate main executable still loads the Debug/preview dylib.')
    for record in (installed, candidate, production):
        record.pop('requirement')
    print(json.dumps({'status': 'PASS', 'installedBeta': installed, 'candidateBeta': candidate,
                      'production': production, 'team': TEAM, 'designatedRequirementUnchanged': True}, indent=2))
    print('Signing continuity and distinct main UUID verified. Local Network and other grants still require runtime verification.')
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    print(f'Identity/UUID preflight FAILED: {error}', file=sys.stderr)
    sys.exit(1)
PY
