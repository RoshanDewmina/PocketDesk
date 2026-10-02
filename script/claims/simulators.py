"""Select dedicated claim simulators; never silently reuse another lane's device."""
import json, pathlib, subprocess, sys

RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
TYPES = {'phone': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
         'ipad': 'com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro'}

def select(family, requested=None):
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j'], text=True))['devices']
    if requested:
        match = next((d for group in devices.values() for d in group if d['udid']==requested and d.get('isAvailable')), None)
        if not match: raise RuntimeError('Requested simulator is missing/unavailable: '+requested)
        return {'udid': requested, 'name': match['name'], 'explicitOverride': True}
    name = 'Farside B7 Claims '+family
    matches = [d for d in devices.get(RUNTIME, []) if d['name']==name and d.get('isAvailable')]
    if len(matches)>1: raise RuntimeError('Ambiguous dedicated simulator name: '+name)
    if matches:
        if matches[0].get('deviceTypeIdentifier') != TYPES[family]:
            raise RuntimeError('Dedicated simulator name has the wrong/missing device type: '+name)
        return {'udid': matches[0]['udid'], 'name': name, 'runtime': RUNTIME, 'created': False}
    runtimes = json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','-j'],text=True))['runtimes']
    if not any(r['identifier']==RUNTIME and r.get('isAvailable') for r in runtimes):
        raise RuntimeError('Dedicated claims checks require the available iOS27.0 runtime; no substitution.')
    identifier = subprocess.check_output(['xcrun','simctl','create',name,TYPES[family],RUNTIME],text=True).strip()
    return {'udid': identifier, 'name': name, 'runtime': RUNTIME, 'deviceType': TYPES[family], 'created': True}

def destination_conflicts(process_rows, device, own_pid):
    """ps rows are (pid, executable, argv). Match native Xcode, not our wrapper."""
    return [pid for pid, executable, argv in process_rows
            if pid != own_pid and executable.endswith('/xcodebuild') and 'id='+device in argv]

def active_conflicts(device):
    rows=[]
    for line in subprocess.check_output(['ps','-Ao','pid=,comm=,args='],text=True).splitlines():
        fields=line.strip().split(None,2)
        if len(fields)==3 and fields[1].endswith('/xcodebuild'):
            rows.append((int(fields[0]),fields[1],fields[2]))
    return destination_conflicts(rows,device,__import__('os').getpid())

if __name__ == '__main__':
    # The caller serializes lookup/create with the shared lock and gate helper.
    try:
        record=select(sys.argv[1],sys.argv[3] if len(sys.argv)>3 else None)
        pathlib.Path(sys.argv[2]).write_text(json.dumps(record,indent=2)+'\n')
        print(json.dumps(record))
    except RuntimeError as error:
        raise SystemExit(str(error))
