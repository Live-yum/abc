#!/usr/bin/env python3
"""Verify a selected completed run of this same repository's performance workflow."""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[1-9][0-9]{0,19}', args.run_id):
        parser.error('baseline_run_id must be a positive GitHub run ID')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
        parser.error('Invalid same-repository name')
    request = Request(f'https://api.github.com/repos/{args.repository}/actions/runs/{args.run_id}',
                      headers={'Accept': 'application/vnd.github+json',
                               'Authorization': f'Bearer {os.environ["GH_TOKEN"]}',
                               'X-GitHub-Api-Version': '2022-11-28'})
    with urlopen(request, timeout=30) as response:
        run = json.load(response)
    assert run['repository']['full_name'].lower() == args.repository.lower(), 'Cross-repository baseline forbidden'
    assert run['path'].split('@')[0] == '.github/workflows/performance.yml', 'Baseline must come from this performance workflow'
    assert run['status'] == 'completed' and run['conclusion'] == 'success', 'Baseline run must have completed successfully'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({key: run[key] for key in
                                      ('id', 'run_attempt', 'head_sha', 'event', 'path', 'html_url', 'status', 'conclusion')}, indent=2) + '\n')


if __name__ == '__main__':
    main()
