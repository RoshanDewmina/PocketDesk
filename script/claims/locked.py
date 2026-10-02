#!/usr/bin/env python3
"""Check gates and binary/source identity under lock; cleanup stays under that lock."""
import os,pathlib,shutil,subprocess,sys
from identity import verify
from simulators import active_conflicts,native_exit_code
p=pathlib.Path('/Users/roshansilva/Documents/Codex/2026-10-01/testing')
if any((p/x).exists() for x in ['PAUSE-BUILDS','PRIORITY-BUILD']) or list(p.glob('QUIET-GRANTED-*')):
    print('Shared gate appeared while waiting; releasing lock (exit 75).',flush=True)
    sys.exit(75)
if shutil.disk_usage('/').free < 10*1024**3:
    print('Internal free disk below 10 GiB; releasing lock.',flush=True); sys.exit(76)
args=sys.argv[1:]; dd=None; shutdown=None
if args and args[0]=='--manifest': dd=args[1]; args=args[2:]
if args and args[0]=='--shutdown-simulator': shutdown=args[1]; args=args[2:]
if 'test-without-building' in args and any('RemotePhoneUITests' in arg for arg in args) and not (p/'CHAIN2-GO').exists():
    print('Simulator UI gate closed while waiting; releasing lock (exit 75).',flush=True)
    sys.exit(75)
if shutdown:
    conflicts=active_conflicts(shutdown)
    if conflicts:
        print('Simulator already targeted by native Xcode PID(s): '+','.join(map(str,conflicts))+'; no launch or shutdown.',flush=True)
        sys.exit(79)
if dd:
    try: verify(dd)
    except RuntimeError as e: print(str(e),flush=True); sys.exit(78)
code=0
try:
    native_code=subprocess.call(args)
    code=native_exit_code(native_code)
    if native_code==75: print('Native command returned75 after execution; mapped to80 to prevent slot-helper repetition.',flush=True)
    if dd:
        try: verify(dd)
        except RuntimeError as e: print('Receipt invalidated: '+str(e),flush=True); code=78
finally:
    if shutdown:
        conflicts=active_conflicts(shutdown)
        if conflicts:
            print('Late destination conflict: '+','.join(map(str,conflicts))+'; receipt invalidated, no simulator shutdown.',flush=True)
            code=79
        else: subprocess.run(['xcrun','simctl','shutdown',shutdown],check=False)
sys.exit(code)
