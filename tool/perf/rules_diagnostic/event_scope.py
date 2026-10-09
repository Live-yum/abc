"""Select only this push’s diagnostic edits; fail closed on missing identity."""
import json
import os
from pathlib import Path
import re
import subprocess

def scope_for_event(name, event, dispatch_head, check_commit, changed_paths):
    def commit(value):
        if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}', value):
            raise ValueError('Event scope requires exact 40-character lowercase commit SHAs')
        if not check_commit(value):
            raise ValueError(f'Event scope commit is unavailable: {value}')
        return value

    if name == 'workflow_dispatch':
        return {'run': True, 'reason': 'explicit-dispatch-one-attempt',
                'head': commit(dispatch_head), 'before': None}
    if name != 'pull_request' or event.get('action') not in ('opened', 'synchronize'):
        raise ValueError('Unsupported event: no rules measurement authorized by this workflow')
    request = event.get('pull_request', {})
    head = commit(request.get('head', {}).get('sha'))
    before = commit(event.get('before') if event['action'] == 'synchronize'
                    else request.get('base', {}).get('sha'))
    changed = changed_paths(before, head)
    enabled = any(p == '.github/workflows/rules-only-diagnostic.yml' or p.startswith('tool/perf/rules_diagnostic/') for p in changed)
    return {'run': enabled, 'reason': 'diagnostic-files-changed' if enabled
            else 'unrelated-event-diff-no-measurement', 'before': before, 'head': head}



def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    def exists(sha):
        return subprocess.check_output(['git', 'rev-parse', '--verify', sha + '^{commit}'], text=True, timeout=30).strip() == sha
    def changed(before, head):
        return subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', '-z', before, head, '--'], timeout=120).decode().split('\0')
    decision = scope_for_event(os.environ['GITHUB_EVENT_NAME'], event, os.environ.get('GITHUB_SHA'), exists, changed)
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
        output.write('run=' + str(decision['run']).lower() + '\n')
    print(json.dumps(decision))

if __name__ == '__main__':
    main()
