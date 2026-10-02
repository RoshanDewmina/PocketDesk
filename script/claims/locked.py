#!/usr/bin/env python3
"""Check gates and binary/source identity under lock; cleanup stays under that lock."""
import os,pathlib,shutil,subprocess,sys
from identity import verify
p=pathlib.Path('/Users/roshansilva/Documents/Codex/2026-10-01/testing')
if any((p/x).exists() for x in ['PAUSE-BUILDS','PRIORITY-BUILD']) or list(p.glob('QUIET-GRANTED-*')):
    print('Shared gate appeared while waiting; releasing lock (exit 75).',flush=True)
    sys.exit(75)
if shutil.disk_usage('/').free < 10*1024**3:
    print('Internal free disk below 10 GiB; releasing lock.',flush=True); sys.exit(76)
args=sys.argv[1:]; dd=None; shutdown=None
if args and args[0]=='--manifest': dd=args[1]; args=args[2:]
if args and args[0]=='--shutdown-simulator': shutdown=args[1]; args=args[2:]
if dd:
    try: verify(dd)
    except RuntimeError as e: print(str(e),flush=True); sys.exit(78)
code=0
try:
    code=subprocess.call(args)
    if dd:
        try: verify(dd)
        except RuntimeError as e: print('Receipt invalidated: '+str(e),flush=True); code=78
finally:
    if shutdown: subprocess.run(['xcrun','simctl','shutdown',shutdown],check=False)
sys.exit(code)
