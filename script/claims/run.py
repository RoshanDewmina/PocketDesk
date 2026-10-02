#!/usr/bin/env python3
"""Isolated App Store claim evidence runner; never installs or starts the Mac host."""
import argparse, datetime, hashlib, json, os, pathlib, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('stage', nargs='?', choices=['all','auto','settings','build','phone','ipad','phone-more','ipad-more','duo','core','backend','host'], default='all')
p.add_argument('--output', default='/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/b7-claims')
p.add_argument('--dd', default='/Volumes/Studio/Development/Caches/b7-claims/DD')
p.add_argument('--phone', default='C643B2C2-3248-4AE4-B234-8F54414F3A41')
p.add_argument('--ipad', default='68F60FDF-7FA8-4129-A165-9B47D8579461')
p.add_argument('--duo', default='663C5184-F544-4CAE-B9C3-A683C26500CE')
a = p.parse_args()
OUT = pathlib.Path(a.output); OUT.mkdir(parents=True, exist_ok=True)
LOG = OUT / 'logs' / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'); LOG.mkdir(parents=True)
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
                if any('RemotePhoneUITests' in arg for arg in args):
                    while not (GATES/'CHAIN2-GO').exists():
                        print('Waiting for shared simulator UI gate',flush=True); time.sleep(60)
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
    run('public-site',['curl','--fail','--head','--location','--max-time','20','--silent','--show-error','https://getfarside.com'])
    settings()
def settings():
    for config in ['Debug','Release']:
        run('build-settings-'+config,common+['-configuration',config,'-scheme','PocketDeskRemoteHost','-showBuildSettings','-json'],True)
def build():
    before=source_identity()
    code = run('phone-build',common+['-configuration','Debug','-scheme','PocketDeskRemote','-destination','platform=iOS Simulator,id='+a.phone,'ARCHS=arm64','build-for-testing'],True)
    if code == 0:
        if source_identity()!=before:
            raise SystemExit('Source changed during build; receipt invalid, rebuild.')
        build_manifest().write_text(json.dumps({'source':before,'artifacts':artifact_identity(a.dd)},indent=2))
    return code
def test(label, device, supplemental=False):
    while not (GATES/'CHAIN2-GO').exists():
        print('Waiting for shared simulator UI gate',flush=True); time.sleep(60)
    gate() # Respect quiet windows before the complete-artifact preflight as well as testing.
    try: verify(a.dd) # Fast preflight; also revalidated under lock.
    except RuntimeError as e: raise SystemExit(str(e))
    (LOG/'tested-build-manifest.json').write_bytes(build_manifest().read_bytes())
    if supplemental:
        selectors=['RemotePhoneUITests/ClaimsVerificationUITests/'+method for method in ['testAccessibilityAuditSupplementalHomeUtilitiesDefaultSize','testAccessibilityAuditSupplementalHomeUtilitiesAccessibilityXXXL']]
    else:
        selectors=['RemotePhoneUITests/ClaimsVerificationUITests','RemotePhoneUITests/FarsideRedesignUITests/testKeyboardBarPutsCommandFirstAndInReachInPortrait','RemotePhoneUITests/SessionLayoutTests/testLongVoicePreviewKeepsDoneReachableInLandscapeWithoutRecording']
        if label=='phone': selectors += ['RemotePhoneTests/'+c for c in ['FarsideDesignTests','SessionLifecycleTests','VoiceInputTests','CommittedTextTests','ExactTextTraitsTests','TabletInputPhoneTests','IndirectInputTests','ViewportPreferenceTests','ViewportCaptureTests','ScreenRecordingApprovalPhoneTests']]
    run(label+'-tests',common+['-configuration','Debug','-scheme','PocketDeskRemote','-destination','platform=iOS Simulator,id='+device,'ARCHS=arm64','test-without-building','-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-test-timeouts-enabled','YES','-default-test-execution-time-allowance','3600','-maximum-test-execution-time-allowance','3600','-resultBundlePath',str(LOG/(label+'.xcresult'))]+['-only-testing:'+s for s in selectors],True,manifest=True,shutdown=device)
    bundle=LOG/(label+'.xcresult')
    if bundle.exists():
        # Read-only report extraction also runs after a failing audit. Raw .xcresult remains
        # authoritative; screenshots stay outside the repo and are not duplicated here.
        for report in ['summary','tests']:
            run(label+'-report-'+report,['xcrun','xcresulttool','get','test-results',report,'--path',str(bundle)])
        run(label+'-text-attachments',['xcrun','xcresulttool','export','attachments','--path',str(bundle),'--output-path',str(LOG/(label+'-attachments')),'--filter','*.txt'])
    run(label+'-selection-acceptance',[sys.executable,str(ROOT/'script/claims/result_guard.py'),str(LOG/(label+'-report-summary.log')),str(LOG/(label+'-report-tests.log'))]+([] if supplemental else ['--all-claims']))
def core():
    before=source_identity()
    ddcore=a.dd+'-core'
    cmd=[ddcore if x==a.dd else x for x in common]
    if run('core-build',cmd+['-configuration','Debug','-scheme','RemoteCoreTests','-destination','platform=macOS','build-for-testing'],True)==0:
        if source_identity()!=before: raise SystemExit('Source changed during core build; receipt invalid.')
        (pathlib.Path(ddcore)/'claims-build-manifest.json').write_text(json.dumps({'source':before,'artifacts':artifact_identity(ddcore)},indent=2))
        (LOG/'tested-core-build-manifest.json').write_bytes((pathlib.Path(ddcore)/'claims-build-manifest.json').read_bytes())
        classes='SessionRenewalPlanTests,CoordinatorRenewalTests,SessionRenewalIntegrationTests,HostReadinessTests,HostPresentationTests,HostLivePopoverTests,HostLifecycleTests,NativeGestureEngineTests,ViewportTransformTests,ViewportCaptureGeometryTests,LocalOwnerAdmissionTests,LocalSignalingLifecycleTests,OwnerLocalCoordinatorTests,HostPairingPreflightTests,InputAppliedReceiptTests'
        run('core-tests',['xcrun','xctest','-XCTest',classes,ddcore+'/Build/Products/Debug/RemoteCoreTests.xctest'],True,manifest=ddcore)
def host():
    before=source_identity()
    ddhost=a.dd+'-host'
    cmd=[ddhost if x==a.dd else x for x in common]
    if run('host-build',cmd+['-configuration','Debug','-scheme','PocketDeskRemoteHost','-destination','platform=macOS','build'],True)==0:
        if source_identity()!=before: raise SystemExit('Source changed during host build; receipt invalid.')
        (LOG/'host-build-manifest.json').write_text(json.dumps({'source':before,'artifacts':artifact_identity(ddhost)},indent=2))
        import plistlib
        for app in (pathlib.Path(ddhost)/'Build/Products/Debug').glob('*.app'):
            info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
            if info.get('CFBundleIdentifier')=='com.roshan.PocketDesk.RemoteHost':
                binary=app/'Contents/MacOS'/info['CFBundleExecutable']
                run('host-architectures',['lipo','-archs',str(binary)])
                run('host-minimum-os',['xcrun','vtool','-show-build',str(binary)])
                (LOG/'host-artifact.json').write_text(json.dumps({'app':str(app),'binary':str(binary),'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'minimum_plist':info.get('LSMinimumSystemVersion')},indent=2))
                break
        else: raise SystemExit('Built host bundle not found; no platform artifact proof.')
def backend():
    gate()
    primary=pathlib.Path('/Users/roshansilva/Developer/PocketDesk/Backend')
    dep=ROOT/'Backend/node_modules'
    if (ROOT/'Backend/bun.lock').read_bytes() != (primary/'bun.lock').read_bytes():
        raise SystemExit('Backend lockfile differs from shared installed dependencies; resolve isolated pinned dependencies first.')
    if not dep.exists():
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
elif a.stage=='settings': settings()
elif a.stage=='build': build()
elif a.stage in ['phone','ipad']: test(a.stage,getattr(a,a.stage))
elif a.stage in ['phone-more','ipad-more']: test(a.stage,getattr(a,a.stage.split('-')[0]),supplemental=True)
elif a.stage=='duo': duo()
elif a.stage=='core': core()
elif a.stage=='backend': backend()
elif a.stage=='host': host()
else:
    auto(); duo(); backend()
    if build()==0:
        test('phone',a.phone); test('ipad',a.ipad)
    core(); host()
print('Evidence: '+str(LOG),flush=True)
sys.exit(1 if any(r['exit'] for r in results if not r['name'].endswith('-shutdown')) else 0)
