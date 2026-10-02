#!/usr/bin/env python3
"""Isolated App Store claim evidence runner; never installs or starts the Mac host."""
import argparse, datetime, hashlib, json, os, pathlib, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
from result_guard import ALL_CLAIMS
from recovery import GROUPS, FEATURE_METHODS, PHONE_UNIT_METHODS, parse_groups, audit_methods, check_methods, test_module
p = argparse.ArgumentParser()
p.add_argument('stage', nargs='?', choices=['all','auto','settings','build','phone','ipad','phone-more','ipad-more','phone-audit','ipad-audit','phone-features','ipad-features','phone-units','phone-check','ipad-check','duo','core','backend','host'], default='all')
p.add_argument('--output', default='/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/b7-claims')
p.add_argument('--dd', default='/Volumes/Studio/Development/Caches/b7-claims/DD')
p.add_argument('--phone', help='Explicit lane-owned simulator override; default is a dedicated claims iPhone')
p.add_argument('--ipad', help='Explicit lane-owned simulator override; default is a dedicated claims iPad')
p.add_argument('--duo', default='663C5184-F544-4CAE-B9C3-A683C26500CE')
p.add_argument('--ui-timeout',type=int,default=7200,help='Per-method default and maximum allowance for the full screen inventories')
p.add_argument('--audit-groups',type=parse_groups,default='all',metavar='GROUPS',help='Recovery groups: all or '+','.join(GROUPS))
p.add_argument('--audit-size',choices=['both','default','AX-XXXL'],default='both',help='Sizes selected by phone-audit/ipad-audit')
a = p.parse_args()
studio = pathlib.Path('/Volumes/Studio')
if not studio.is_mount():
    raise SystemExit('Receipt SSD is not mounted at /Volumes/Studio; no commands started.')
receipt_parent = pathlib.Path(a.dd).resolve().parent
if not receipt_parent.is_relative_to(studio.resolve()):
    raise SystemExit('--dd must reside on /Volumes/Studio for SSD-backed receipt storage.')
OUT = pathlib.Path(a.output).resolve(); OUT.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
physical_log = receipt_parent / 'receipts' / stamp
physical_log.mkdir(parents=True) # Fail closed on collision, never overwrite an existing receipt.
LOG = OUT / 'logs' / stamp
LOG.parent.mkdir(parents=True, exist_ok=True)
LOG.symlink_to(physical_log, target_is_directory=True) # Public paths continue to identify raw receipts.
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
from identity import source_identity, artifact_identity, verify
from simulators import select
selected_devices = {}
def device(family):
    if family not in selected_devices:
        record=LOG/(family+'-device.json')
        requested=getattr(a,family)
        if requested:
            gate()
            # Read-only UUID validation cannot create a duplicate device. It need
            # not queue behind an unrelated build before taking the free slot.
            selected_devices[family]=select(family,requested)
            record.write_text(json.dumps(selected_devices[family],indent=2)+'\n')
        else:
            code=run('select-'+family,[sys.executable,str(ROOT/'script/claims/simulators.py'),family,str(record)],True,primary=True)
            if code: raise SystemExit('Dedicated simulator selection failed; no test started.')
            selected_devices[family] = json.loads(record.read_text())
        (LOG/'selected-devices.json').write_text(json.dumps(selected_devices,indent=2))
        print('Dedicated '+family+': '+selected_devices[family]['udid'],flush=True)
    return selected_devices[family]['udid']
GATES = pathlib.Path('/Users/roshansilva/Documents/Codex/2026-10-01/testing')
def gate():
    while any((GATES / x).exists() for x in ['PAUSE-BUILDS','PRIORITY-BUILD']) or list(GATES.glob('QUIET-GRANTED-*')):
        print('Waiting for shared build/quiet gate', flush=True); time.sleep(60)
    if __import__('shutil').disk_usage('/').free < 10 * 1024**3:
        raise SystemExit('Internal disk below 10 GiB: no builds/tests started')
def run(name, args, locked=False, timeout=None, manifest=False, shutdown=None, primary=False):
    if locked:
        gate()
        flags=(['--manifest',manifest if isinstance(manifest,str) else a.dd] if manifest else [])+(['--shutdown-simulator',shutdown] if shutdown else [])
        prefix=['/usr/bin/lockf','-k','/tmp/farside-xcodebuild.lock'] if primary else [str(pathlib.Path.home()/'bin/farside-lock')]
        args = prefix+[sys.executable,str(ROOT/'script/claims/locked.py'),*flags,*args]
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
    code = run('phone-build',common+['-configuration','Debug','-scheme','PocketDeskRemote','-destination','platform=iOS Simulator,id='+device('phone'),'ARCHS=arm64','build-for-testing'],True)
    if code == 0:
        if source_identity()!=before:
            raise SystemExit('Source changed during build; receipt invalid, rebuild.')
        build_manifest().write_text(json.dumps({'source':before,'artifacts':artifact_identity(a.dd)},indent=2))
    return code
def test(label, device, supplemental=False, recovery_methods=None, unit_only=False):
    while not (GATES/'CHAIN2-GO').exists():
        print('Waiting for shared simulator UI gate',flush=True); time.sleep(60)
    gate() # Respect quiet windows before the complete-artifact preflight as well as testing.
    try: verify(a.dd) # Fast preflight; also revalidated under lock.
    except RuntimeError as e: raise SystemExit(str(e))
    (LOG/'tested-build-manifest.json').write_bytes(build_manifest().read_bytes())
    if recovery_methods is not None:
        selectors=[test_module(method)+'/'+method for method in recovery_methods]
        (LOG/(label+'-expected-methods.json')).write_text(json.dumps(recovery_methods,indent=2))
        combined = label.endswith('-check')
        has_audits = combined or label.endswith('-audit')
        groups = (list(GROUPS) if combined or a.stage=='all' else a.audit_groups) if has_audits else []
        size = ('both' if combined or a.stage=='all' else a.audit_size) if has_audits else None
        (LOG/(label+'-scope.json')).write_text(json.dumps({
            'scope': ('Combined bounded audit/feature/unit selection only; all findings retained; no original eight-method pass or physical acceptance' if combined else
                      '89 selected phone-unit methods only; no UI inventory/physical acceptance' if unit_only else
                      'Selected bounded audits only' if has_audits else str(len(recovery_methods))+' selected feature/UI methods only; no accessibility inventory completion'),
            'auditGroups': groups,
            'auditSize': size,
            'surfacesPerSize': sum(GROUPS[g][1] for g in groups),
            'selectedUnitMethods': sum(test_module(method)=='RemotePhoneTests' for method in recovery_methods),
            'selectedUIMethods': sum(test_module(method)=='RemotePhoneUITests' for method in recovery_methods),
            'expectedMethods': recovery_methods,
            'originalEightMethodPass': False,
        },indent=2))
    elif supplemental:
        selectors=['RemotePhoneUITests/ClaimsVerificationUITests/'+method for method in ['testAccessibilityAuditSupplementalHomeUtilitiesDefaultSize','testAccessibilityAuditSupplementalHomeUtilitiesAccessibilityXXXL']]
    else:
        selectors=['RemotePhoneUITests/ClaimsVerificationUITests/'+method for method in sorted(ALL_CLAIMS)] + ['RemotePhoneUITests/'+method for method in FEATURE_METHODS[-2:]]
        if label=='phone': selectors += ['RemotePhoneTests/'+c for c in ['FarsideDesignTests','SessionLifecycleTests','VoiceInputTests','CommittedTextTests','ExactTextTraitsTests','TabletInputPhoneTests','IndirectInputTests','ViewportPreferenceTests','ViewportCaptureTests','ScreenRecordingApprovalPhoneTests']]
    run(label+'-tests',common+['-configuration','Debug','-scheme','PocketDeskRemote','-destination','platform=iOS Simulator,id='+device,'ARCHS=arm64','test-without-building','-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-test-timeouts-enabled','YES','-default-test-execution-time-allowance',str(a.ui_timeout),'-maximum-test-execution-time-allowance',str(a.ui_timeout),'-resultBundlePath',str(LOG/(label+'.xcresult'))]+['-only-testing:'+s for s in selectors],True,manifest=True,shutdown=device)
    bundle=LOG/(label+'.xcresult')
    if bundle.exists():
        # Read-only report extraction also runs after a failing audit. Raw .xcresult remains
        # authoritative; screenshots stay outside the repo and are not duplicated here.
        for report in ['summary','tests']:
            run(label+'-report-'+report,['xcrun','xcresulttool','get','test-results',report,'--path',str(bundle)])
        run(label+'-text-attachments',['xcrun','xcresulttool','export','attachments','--path',str(bundle),'--output-path',str(LOG/(label+'-attachments')),'--filter','*.txt'])
    guard_flags = (['--expected-methods-file',str(LOG/(label+'-expected-methods.json'))]
                   if recovery_methods is not None else ([] if supplemental else ['--all-claims']))
    run(label+'-selection-acceptance',[sys.executable,str(ROOT/'script/claims/result_guard.py'),str(LOG/(label+'-report-summary.log')),str(LOG/(label+'-report-tests.log'))]+guard_flags)
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
elif a.stage in ['phone','ipad']: test(a.stage,device(a.stage))
elif a.stage in ['phone-more','ipad-more']: test(a.stage,device(a.stage.split('-')[0]),supplemental=True)
elif a.stage in ['phone-audit','ipad-audit','phone-features','ipad-features']:
    family=a.stage.split('-')[0]
    methods=audit_methods(a.audit_groups,a.audit_size) if a.stage.endswith('-audit') else FEATURE_METHODS
    test(a.stage,device(family),recovery_methods=methods)
elif a.stage=='phone-units': test(a.stage,device('phone'),recovery_methods=PHONE_UNIT_METHODS,unit_only=True)
elif a.stage in ['phone-check','ipad-check']:
    family=a.stage.split('-')[0]
    test(a.stage,device(family),recovery_methods=check_methods(family))
elif a.stage=='duo': duo()
elif a.stage=='core': core()
elif a.stage=='backend': backend()
elif a.stage=='host': host()
else:
    auto(); duo(); backend()
    if build()==0:
        # A future one-command pass covers bounded audits plus feature/unit selectors.
        # It does not rewrite the failed receipts of the original monolithic methods.
        # One native invocation per device avoids repeated gate checks after a new
        # simulator boot has reduced free internal space. The pre-launch floor stays intact.
        for family in ['phone','ipad']:
            test(family+'-check',device(family),recovery_methods=check_methods(family))
    core(); host()
print('Evidence: '+str(LOG),flush=True)
sys.exit(1 if any(r['exit'] for r in results if not r['name'].endswith('-shutdown')) else 0)
