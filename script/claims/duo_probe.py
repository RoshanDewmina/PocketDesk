#!/usr/bin/env python3
"""One assigned simulator boot probe, invoked inside locked.py's owned cleanup."""
import datetime, json, pathlib, subprocess, sys

def probe(device, record, marker):
    # Exclusive creation prevents repeating a crashed/interrupted attempt. A new
    # integrated build requiring new Duo evidence must use a fresh output folder.
    try:
        with pathlib.Path(marker).open('x') as f:
            json.dump({'device':device,'attemptedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()},f)
    except FileExistsError:
        print('Duo attempt already recorded; no boot.',flush=True)
        return 1
    result = {'device': device, 'accepted': False, 'attempts': 1}
    code = 1
    try:
        boot = subprocess.run(['xcrun', 'simctl', 'boot', device], timeout=30)
        result['bootExit'] = boot.returncode
        if boot.returncode == 0:
            status = subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'],
                                    text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=180)
            print(status.stdout, flush=True)
            result['statusExit'] = status.returncode
            devices = json.loads(subprocess.check_output(
                ['xcrun', 'simctl', 'list', 'devices', '-j'], text=True, timeout=10))['devices']
            result['state'] = next((d.get('state') for group in devices.values()
                                    for d in group if d['udid'] == device), None)
            result['migrationFailed'] = 'Data Migration Failed' in status.stdout
            result['accepted'] = status.returncode == 0 and not result['migrationFailed'] and result['state'] == 'Booted'
            code = 0 if result['accepted'] else 1
    except (subprocess.SubprocessError, ValueError, KeyError) as error:
        result['error'] = str(error)
        code = 124 if isinstance(error, subprocess.TimeoutExpired) else 1
    finally:
        pathlib.Path(record).write_text(json.dumps(result, indent=2)+'\n')
    return code

if __name__ == '__main__':
    raise SystemExit(probe(sys.argv[1], sys.argv[2], sys.argv[3]))
