#!/usr/bin/env python3
"""Reject empty/skipped supplemental selections; reads xcresulttool JSON only."""
import json, pathlib, re, sys

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

def validate(summary, tree, all_claims=False, expected_methods=None):
    selected = []
    suites = {'ClaimsVerificationUITests'}
    if expected_methods is not None:
        if (not expected_methods or len(set(expected_methods)) != len(expected_methods)
                or any(not isinstance(m, str) or m.count('/') != 1 for m in expected_methods)):
            raise ValueError('Expected selection must be a nonempty unique list of Class/method identifiers')
        suites.update(m.split('/')[0] for m in expected_methods)
    def visit(nodes, ancestry=''):
        for node in nodes:
            location = ancestry + '/' + node.get('name', '')
            if node.get('nodeType') == 'Test Case':
                method = node.get('name', '').removesuffix('()')
                identity = node.get('nodeIdentifier', '') + location
                matching_suites = [suite for suite in suites
                                   if re.search(r'(?<![\w])'+re.escape(suite)+r'(?![\w])', identity)]
                selected.append({'method': method, 'result': node.get('result'),
                                 'suite': matching_suites[0] if len(matching_suites) == 1 else None,
                                 'claimsClass': 'ClaimsVerificationUITests' in matching_suites})
            visit(node.get('children', []), location)
    visit(tree.get('testNodes', []))
    if expected_methods is not None:
        expected = set(expected_methods)
        executed = {str(n['suite'])+'/'+n['method'] for n in selected}
        passed = (summary.get('result') == 'Passed'
                  and summary.get('totalTestCount') == len(expected)
                  and summary.get('passedTests') == len(expected)
                  and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0
                  and summary.get('expectedFailures') == 0 and len(selected) == len(expected)
                  and executed == expected and all(n['result'] == 'Passed' for n in selected))
        return {'accepted': passed, 'scope': 'Exact selected recovery methods only; no original eight-method pass inferred',
                'expectedMethods': sorted(expected), 'selectedTests': selected,
                'reason': 'Every selected method executed and passed.' if passed
                          else 'Missing, skipped, failed, duplicate, or unexpected selected method; not a pass.'}
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
        flags = sys.argv[3:]
        expected = None
        if '--expected-methods-file' in flags:
            if '--all-claims' in flags:
                raise ValueError('Exact recovery selection and original class mode are mutually exclusive')
            expected = json.loads(pathlib.Path(flags[flags.index('--expected-methods-file')+1]).read_text())
            if not isinstance(expected, list): raise ValueError('Expected methods receipt must be a list')
        receipt = validate(json.loads(pathlib.Path(sys.argv[1]).read_text()),
                           json.loads(pathlib.Path(sys.argv[2]).read_text()),
                           all_claims='--all-claims' in flags, expected_methods=expected)
    except (OSError, ValueError, IndexError, TypeError, AttributeError) as error:
        receipt = {'accepted': False, 'reason': 'Missing/invalid result receipt: ' + str(error)}
    print(json.dumps(receipt, indent=2))
    sys.exit(0 if receipt['accepted'] else 1)
