#!/usr/bin/env python3
"""Isolated App Store claim evidence runner; never installs or starts the Mac host."""
import argparse, datetime, hashlib, json, os, pathlib, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('stage', nargs='?', choices=['all','auto','build','phone','ipad','duo','core','backend'], default='all')
p.add_argument('--output', default='/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/b7-claims')
p.add_argument('--dd', default='/Volumes/Studio/Development/Caches/b7-claims/DD')
p.add_argument('--phone', default='C643B2C2-3248-4AE4-B234-8F54414F3A41')
p.add_argument('--ipad', default='68F60FDF-7FA8-4129-A165-9B47D8579461')
p.add_argument('--duo', default='663C5184-F544-4CAE-B9C3-A683C26500CE')
a = p.parse_args()
OUT = pathlib.Path(a.output); OUT.mkdir(parents=True, exist_ok=True)
LOG = OUT / 'logs' / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'); LOG.mkdir(parents=True)
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
from identity import source_identity, artifact_identity, verify
GATES = pathlib.Path('/Users/roshansilva/Documents/Codex/2026-10-01/testing')
def gate():
    while any((GATES / x).exists() for x in ['PAUSE-BUILDS','PRIORITY-BUILD']) or list(GATES.glob('QUIET-GRANTED-*')):
        print('Waiting for shared build/quiet gate', flush=True); time.sleep(60)
    if __import__('shutil').disk_usage('/').free < 10 * 1024**3:
        raise SystemExit('Internal disk below 10 GiB: no builds/tests started')
def run(name, args, locked=False, timeout=None, manifest=False, shutdown=None):
    if locked:
        gate()
        flags=(['--manifest',manifest if isinstance(manifest,str) else a.dd] if manifest else [])+(['--shutdown-simulator',shutdown] if shutdown else [])
        args = ['/usr/bin/lockf','-k','/tmp/farside-xcodebuild.lock',sys.executable,str(ROOT/'script/claims/locked.py'),*flags,*args]
    print(name + ': ' + ' '.join(args), flush=True)
    with (LOG / (name+'.log')).open('a') as f:
        try:
            while True:
                r = subprocess.run(args, cwd=ROOT, env=ENV, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
                if not locked or r.returncode != 75: break
                gate() # Lock has been released; never wait for PRIORITY while holding it.
        except subprocess.TimeoutExpired:
            f.write('\nTimed out after '+str(timeout)+' seconds; no retry.\n')
            r = subprocess.CompletedProcess(args,124)
    print(name + ' exit=' + str(r.returncode), flush=True)
    results.append({'name':name,'exit':r.returncode,'log':str(LOG/(name+'.log'))})
    (LOG/'results.json').write_text(json.dumps(results,indent=2))
    return r.returncode
results=[]
common=['xcodebuild','-project','PocketDesktop.xcodeproj','-derivedDataPath',a.dd,'-clonedSourcePackagesDirPath','/Users/roshansilva/Developer/PocketDesk/outputs/RemoteBuild/SourcePackages','-disableAutomaticPackageResolution','-onlyUsePackageVersionsFromResolvedFile']
def build_manifest():
    return pathlib.Path(a.dd)/'claims-build-manifest.json'
def auto():
    run('source-audit',[sys.executable,str(ROOT/'script/claims/source_audit.py'),str(LOG)])
    run('xcode-version',['xcodebuild','-version'],True)
    run('simulators',['xcrun','simctl','list','devices','available'])
    for config in ['Debug','Release']:
        run('build-settings-'+config,common+['-configuration',config,'-alltargets','-showBuildSettings','-json'],True)
def build():
    before=source_identity()
    code = run('phone-build',common+['-configuration','Debug','-scheme','PocketDeskRemote','-destination','platform=iOS Simulator,id='+a.phone,'ARCHS=arm64','build-for-testing'],True)
    if code == 0:
        if source_identity()!=before:
            raise SystemExit('Source changed during build; receipt invalid, rebuild.')
        build_manifest().write_text(json.dumps({'source':before,'artifacts':artifact_identity(a.dd)},indent=2))
    return code
def test(label, device):
    try: verify(a.dd) # Fast preflight; also revalidated under lock.
    except RuntimeError as e: raise SystemExit(str(e))
    (LOG/'tested-build-manifest.json').write_bytes(build_manifest().read_bytes())
    selectors=['RemotePhoneUITests/ClaimsVerificationUITests','RemotePhoneUITests/FarsideRedesignUITests/testKeyboardBarPutsCommandFirstAndInReachInPortrait','RemotePhoneUITests/SessionLayoutTests/testLongVoicePreviewKeepsDoneReachableInLandscapeWithoutRecording']
    if label=='phone': selectors += ['RemotePhoneTests/FarsideDesignTests','RemotePhoneTests/SessionLifecycleTests','RemotePhoneTests/VoiceInputTests','RemotePhoneTests/CommittedTextTests','RemotePhoneTests/ExactTextTraitsTests','RemotePhoneTests/TabletInputPhoneTests']
    run(label+'-tests',common+['-configuration','Debug','-scheme','PocketDeskRemote','-destination','platform=iOS Simulator,id='+device,'ARCHS=arm64','test-without-building','-parallel-testing-enabled','NO','-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','3600','-resultBundlePath',str(LOG/(label+'.xcresult'))]+['-only-testing:'+s for s in selectors],True,manifest=True,shutdown=device)
def core():
    before=source_identity()
    ddcore=a.dd+'-core'
    cmd=[ddcore if x==a.dd else x for x in common]
    if run('core-build',cmd+['-configuration','Debug','-scheme','RemoteCoreTests','-destination','platform=macOS','build-for-testing'],True)==0:
        if source_identity()!=before: raise SystemExit('Source changed during core build; receipt invalid.')
        (pathlib.Path(ddcore)/'claims-build-manifest.json').write_text(json.dumps({'source':before,'artifacts':artifact_identity(ddcore)},indent=2))
        (LOG/'tested-core-build-manifest.json').write_bytes((pathlib.Path(ddcore)/'claims-build-manifest.json').read_bytes())
        classes='SessionRenewalPlanTests,CoordinatorRenewalTests,SessionRenewalIntegrationTests,HostReadinessTests,HostPresentationTests,HostLivePopoverTests,HostLifecycleTests'
        run('core-tests',['xcrun','xctest','-XCTest',classes,ddcore+'/Build/Products/Debug/RemoteCoreTests.xctest'],True,manifest=ddcore)
def backend():
    gate()
    primary=pathlib.Path('/Users/roshansilva/Developer/PocketDesk/Backend')
    dep=ROOT/'Backend/node_modules'
    if not dep.exists():
        if (ROOT/'Backend/bun.lock').read_bytes() != (primary/'bun.lock').read_bytes():
            raise SystemExit('Backend lockfile differs from shared installed dependencies; resolve isolated pinned dependencies first.')
        dep.symlink_to(primary/'node_modules',target_is_directory=True)
    # Only local Cloudflare test fixtures; no wrangler dev/deploy, credentials or provider access.
    before=source_identity()
    run('backend-renewal-route',['node',str(dep/'vitest/vitest.mjs'),'run','--root',str(ROOT/'Backend'),'--config',str(ROOT/'Backend/vitest.config.ts'),'test/renewal.test.ts','test/route.test.ts'])
    if source_identity()!=before: raise SystemExit('Source changed during backend checks; receipt invalid.')
def duo():
    gate()
    run('duo-boot-once',['xcrun','simctl','boot',a.duo])
    try:
        code=run('duo-boot-status',['xcrun','simctl','bootstatus',a.duo,'-b'],timeout=180)
        text=(LOG/'duo-boot-status.log').read_text()
        states=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j'],env=ENV,text=True))['devices']
        device=next((d for group in states.values() for d in group if d['udid']==a.duo),{})
        failed=code!=0 or 'Data Migration Failed' in text or device.get('state')!='Booted'
        results.append({'name':'duo-boot-acceptance','exit':1 if failed else 0,'state':device.get('state'),'log':str(LOG/'duo-boot-status.log')})
        (LOG/'results.json').write_text(json.dumps(results,indent=2))
        print('Duo boot acceptance: '+('FAILED; no retry' if failed else 'completed'),flush=True)
    finally:
        run('duo-shutdown',['xcrun','simctl','shutdown',a.duo])
if a.stage=='auto': auto()
elif a.stage=='build': build()
elif a.stage in ['phone','ipad']: test(a.stage,getattr(a,a.stage))
elif a.stage=='duo': duo()
elif a.stage=='core': core()
elif a.stage=='backend': backend()
else:
    auto(); duo(); backend()
    if build()==0:
        test('phone',a.phone); test('ipad',a.ipad)
    core()
print('Evidence: '+str(LOG),flush=True)
sys.exit(1 if any(r['exit'] for r in results if not r['name'].endswith('-shutdown')) else 0)
