#!/usr/bin/env python3
"""Reject empty/skipped supplemental selections; reads xcresulttool JSON only."""
import json, pathlib, sys

EXPECTED = {
    'testAccessibilityAuditSupplementalHomeUtilitiesDefaultSize',
    'testAccessibilityAuditSupplementalHomeUtilitiesAccessibilityXXXL',
}
ALL_CLAIMS = EXPECTED | {
    'testAccessibilityAuditAllScreensDefaultSize',
    'testAccessibilityAuditAllScreensAccessibilityXXXL',
    'testCoachLessonsUseSynthesizedGesturesAllFive',
    'testSessionPinchChangesAccessibleZoom',
    'testKeyboardAndNonRecordingDictationRemainReachable',
    'testOfflineConcealmentFixtureAndHomeBackgroundForeground',
}

def validate(summary, tree, all_claims=False):
    selected = []
    def visit(nodes, ancestry=''):
        for node in nodes:
            location = ancestry + '/' + node.get('name', '')
            if node.get('nodeType') == 'Test Case':
                method = node.get('name', '').removesuffix('()')
                identity = node.get('nodeIdentifier', '') + location
                selected.append({'method': method, 'result': node.get('result'),
                                 'claimsClass': 'ClaimsVerificationUITests' in identity})
            visit(node.get('children', []), location)
    visit(tree.get('testNodes', []))
    expected = ALL_CLAIMS if all_claims else EXPECTED
    if all_claims:
        selected = [n for n in selected if n['claimsClass']]
        passed = (summary.get('totalTestCount', 0) >= len(expected)
                  and len(selected) == len(expected)
                  and {n['method'] for n in selected} == expected
                  and all(n['result'] == 'Passed' for n in selected))
        return {'accepted': passed, 'scope': 'ClaimsVerificationUITests only; original Xcode suite exit is retained',
                'expectedMethods': sorted(expected), 'selectedTests': selected,
                'reason': 'All eight named claims methods executed and passed.' if passed
                          else 'Incomplete, skipped, or failing claims class; not a pass.'}
    passed = (summary.get('result') == 'Passed'
              and summary.get('totalTestCount') == 2 and summary.get('passedTests') == 2
              and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0
              and summary.get('expectedFailures') == 0 and len(selected) == 2
              and {n['method'] for n in selected} == EXPECTED
              and all(n['result'] == 'Passed' and n['claimsClass'] for n in selected))
    return {'accepted': passed, 'expectedMethods': sorted(EXPECTED), 'selectedTests': selected,
            'reason': 'Both named supplemental audits executed and passed.' if passed
                      else 'Missing, skipped, failed, unexpected, or empty supplemental selection; not a pass.'}

if __name__ == '__main__':
    try:
        receipt = validate(json.loads(pathlib.Path(sys.argv[1]).read_text()),
                           json.loads(pathlib.Path(sys.argv[2]).read_text()),
                           all_claims='--all-claims' in sys.argv[3:])
    except (OSError, ValueError, IndexError) as error:
        receipt = {'accepted': False, 'reason': 'Missing/invalid result receipt: ' + str(error)}
    print(json.dumps(receipt, indent=2))
    sys.exit(0 if receipt['accepted'] else 1)
