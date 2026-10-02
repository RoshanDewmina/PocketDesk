#!/usr/bin/env python3
"""Evidence inventory, not a proof of absence or a runtime acceptance test."""
import json,pathlib,subprocess,sys,platform
root=pathlib.Path(__file__).resolve().parents[2]; out=pathlib.Path(sys.argv[1])
queries={
'frameworks':(['RemotePhone','RemoteHost'],r'^import (SwiftUI|UIKit|ScreenCaptureKit|VideoToolbox)'),
'account-paths':(['RemotePhone','RemoteHost','RemoteShared'],r'(?i)(sign.?in|log.?in|create.?account|ASAuthorization|AuthenticationServices|oauth|firebase|supabase)'),
'session-caps':(['RemotePhone','RemoteHost','RemoteShared','Server','Backend'],r'(?i)(1800|30 ?\* ?60|time.?limit|session.?renew|renewal|SESSION_RENEWAL|expiresAt|lease)'),
'privacy':(['RemotePhone'],r'(contentConcealed|privacyShield|scenePhase|background-concealed)'),
'haptic':(['RemotePhone'],r'(UIImpactFeedbackGenerator|UISelectionFeedbackGenerator|sensoryFeedback|haptic)'),
'dictation':(['RemotePhone'],r'(requiresOnDeviceRecognition|supportsOnDeviceRecognition|SFSpeechRecognizer|Voice input)'),
'architecture':(['project.yml','PocketDesktop.xcodeproj/project.pbxproj'],r'(MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|ARCHS|deploymentTarget|TARGETED_DEVICE_FAMILY)')}
for name,(paths,pattern) in queries.items():
    r=subprocess.run(['rg','-n',pattern,*paths],cwd=root,text=True,capture_output=True)
    (out/(name+'.txt')).write_text(r.stdout+r.stderr)
    if r.returncode>1: raise SystemExit(r.returncode)
r=subprocess.run(['git','rev-parse','HEAD'],cwd=root,text=True,capture_output=True,check=True)
(out/'provenance.json').write_text(json.dumps({'revision':r.stdout.strip(),'os':platform.platform(),'git_status':subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True),'scope':'Source scan only; no account/time-limit absence requires inspection of relevant matches.'},indent=2))

objects=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-','PocketDesktop.xcodeproj/project.pbxproj'],cwd=root))['objects']
configs=[]
for target in objects.values():
    if target.get('isa')!='PBXNativeTarget': continue
    for key in objects[target['buildConfigurationList']]['buildConfigurations']:
        c=objects[key]; b=c['buildSettings']
        configs.append({'target':target['name'],'configuration':c['name'],'MACOSX_DEPLOYMENT_TARGET':b.get('MACOSX_DEPLOYMENT_TARGET'),'IPHONEOS_DEPLOYMENT_TARGET':b.get('IPHONEOS_DEPLOYMENT_TARGET'),'ARCHS':b.get('ARCHS'),'TARGETED_DEVICE_FAMILY':b.get('TARGETED_DEVICE_FAMILY')})
(out/'pbx-configurations.json').write_text(json.dumps(configs,indent=2))

from identity import source_identity
(out/'source-input-sha256.json').write_text(json.dumps(source_identity(),indent=2))
