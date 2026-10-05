import json, os, subprocess, tempfile
from pathlib import Path
script = str(Path('script/agent-hooks/farside-notify').resolve())
with tempfile.TemporaryDirectory() as d:
    bridge = Path(d) / 'bridge.json'
    bridge.write_text(json.dumps({'port': 12345, 'token': 'a'*64}))
    def run(args, payload=''):
        return subprocess.run(['/bin/sh', script, '--bridge-file', str(bridge), '--dry-run', '--strict'] + args,
            input=payload, text=True, capture_output=True)
    shared = ['--agent', 'other', '--session', 'confidential/job/name', '--run', 'private-run-one']
    first = run(shared + ['--exit-status', '0'])
    assert first.returncode == 0, first.stderr
    complete = json.loads(first.stdout.splitlines()[1])
    assert complete['type'] == 'completed'
    assert len(complete['id']) == 14
    assert complete == json.loads(run(shared + ['--exit-status', '0']).stdout.splitlines()[1])
    failed = json.loads(run(shared + ['--exit-status', '42']).stdout.splitlines()[1])
    assert failed['type'] == 'failed' and failed['id'] != complete['id']
    second = json.loads(run(['--agent', 'other', '--session', 'confidential/job/name', '--run', 'private-run-two', '--exit-status', '0']).stdout.splitlines()[1])
    assert second['id'] != complete['id'] and second['agent']['runHash'] != complete['agent']['runHash']
    assert 'confidential' not in first.stdout and 'private-run' not in first.stdout
    assert run(['--exit-status', '0']).returncode == 1
    assert run(shared + ['--exit-status', '256']).returncode == 1
    assert run(shared + ['--exit-status', 'bad']).returncode == 1
    for hook in ['Stop', 'SessionEnd', 'idle']:
        result = run(['--agent', 'codex'], json.dumps({'hook_event_name': hook, 'session_id': 'secret'}))
        assert result.returncode == 0 and result.stdout == '', hook
    attention = json.loads(run(['--agent', 'codex'], json.dumps({'hook_event_name': 'PermissionRequest', 'session_id': 'secret'})).stdout.splitlines()[1])
    assert attention['type'] == 'needs_user'
    print('PASS: explicit exit status, stable IDs, distinct runs, privacy, validation, Stop/idle ignored, legacy attention')
