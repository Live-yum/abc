"""Read one pinned Actions artifact; never execute its contents."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = 'Live-yum/abc'
RUN = 38013071745
HEAD = '5f267796a7b1e694ef3ec2b90aef6387619f95c4'
ARTIFACT = 11654427205
NAME = 'full-shell-paired-' + HEAD
SIZE = 42938457
DIGEST = 'd0840c73acb6c5a855150e4a917d8b309ac14ada53d4615798277bb878088dac'
MAX_SELECTED = 3 * 1024 * 1024
MAX_METADATA = 128 * 1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api_request(path):
    return urllib.request.Request(
        'https://api.github.com/repos/' + REPOSITORY + '/' + path,
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28'},
    )


def get_json(opener, path):
    with opener.open(api_request(path), timeout=60) as response:
        data = response.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024:
        raise ValueError('Metadata exceeds fixed size limit')
    return json.loads(data)


def selected(name):
    parts = PurePosixPath(name).parts
    return ('shell-paired-results' in parts and
            parts.index('shell-paired-results') == len(parts) - 2 and
            PurePosixPath(name).suffix in ('.log', '.json'))


def main(output):
    output.mkdir(parents=True, exist_ok=False)
    status = {'status': 'incomplete', 'repository': REPOSITORY, 'runId': RUN,
              'head': HEAD, 'artifactId': ARTIFACT, 'artifactSha256': DIGEST,
              'executesDownloadedContent': False, 'benchmarkRerun': False}
    status_path = output / 'inspection.json'
    status_path.write_text(json.dumps(status, indent=2) + '\n')
    try:
        opener = urllib.request.build_opener(NoRedirect)
        run = get_json(opener, f'actions/runs/{RUN}')
        artifact = get_json(opener, f'actions/artifacts/{ARTIFACT}')
        if (run['id'] != RUN or run['head_sha'] != HEAD or
                run['repository']['full_name'] != REPOSITORY or
                run['status'] != 'completed' or run['conclusion'] != 'failure'):
            raise ValueError('Original failed run identity mismatch')
        if (artifact['id'] != ARTIFACT or artifact['name'] != NAME or
                artifact['expired'] or artifact['size_in_bytes'] != SIZE or
                artifact['digest'] != 'sha256:' + DIGEST or
                artifact['workflow_run']['id'] != RUN or
                artifact['workflow_run']['head_sha'] != HEAD):
            raise ValueError('Original artifact identity mismatch')
        try:
            opener.open(api_request(f'actions/artifacts/{ARTIFACT}/zip'), timeout=60)
            raise ValueError('Expected the documented artifact redirect')
        except urllib.error.HTTPError as response:
            if response.code != 302:
                raise ValueError('Artifact download redirect unavailable') from None
            location = response.headers.get('Location', '')
        parsed = urllib.parse.urlsplit(location)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError('Invalid official artifact redirect')
        # Authorization is sent only to api.github.com, never to the signed
        # storage redirect. The redirect itself is never recorded or printed.
        archive = Path(os.environ['RUNNER_TEMP']) / 'fixed-shell-artifact.zip'
        digest = hashlib.sha256()
        count = 0
        with urllib.request.urlopen(location, timeout=60) as response, archive.open('xb') as stream:
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if count > SIZE:
                    raise ValueError('Original archive exceeded pinned byte count')
                digest.update(chunk)
                stream.write(chunk)
        if count != SIZE or digest.hexdigest() != DIGEST:
            raise ValueError('Original archive hash or byte count mismatch')
        entries = []
        seen = set()
        with zipfile.ZipFile(archive) as source:
            if len(source.infolist()) > 5000:
                raise ValueError('Unexpected archive entry count')
            if sum(i.file_size for i in source.infolist()) > 512 * 1024 * 1024:
                raise ValueError('Declared uncompressed archive exceeds fixed budget')
            candidates = []
            for info in source.infolist():
                path = PurePosixPath(info.filename)
                if (not info.filename or info.filename in seen or path.is_absolute()
                        or len(info.filename.encode('utf-8')) > 240
                        or str(path) != info.filename.rstrip('/')
                        or '..' in path.parts or '\\' in info.filename
                        or stat.S_ISLNK(info.external_attr >> 16) or info.flag_bits & 1):
                    raise ValueError('Unsafe archive member')
                seen.add(info.filename)
                if not info.is_dir() and selected(info.filename):
                    candidates.append(info)
            if (not candidates or len(candidates) > 256
                    or sum(i.file_size for i in candidates) > MAX_SELECTED):
                raise ValueError('Selected evidence missing or exceeds three MiB budget')
            for info in candidates:
                data = source.read(info)  # verifies the selected member CRC
                data.decode('utf-8')
                if b'\0' in data:
                    raise ValueError('Selected member is not plain UTF-8 evidence')
                target = output / 'files' / info.filename
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                entries.append({'path': info.filename, 'bytes': len(data),
                                'sha256': hashlib.sha256(data).hexdigest()})
        if not any(PurePosixPath(r['path']).name == 'summary.json' for r in entries):
            raise ValueError('Original summary missing')
        if not any(PurePosixPath(r['path']).name == '01-B.log' for r in entries):
            raise ValueError('First process log missing')
        status.update(status='extracted-original-evidence', sourceRunConclusion=run['conclusion'],
                      sourceArtifactBytes=count, files=entries,
                      selectedBytes=sum(r['bytes'] for r in entries),
                      limits='No binaries executed; no measurements rerun; source failure unchanged.')
        encoded = (json.dumps(status, indent=2) + '\n').encode()
        if len(encoded) > MAX_METADATA:
            raise ValueError('Inspection manifest exceeds fixed budget')
        status_path.write_bytes(encoded)
        # At most 3 MiB text + 128 KiB manifest, safely below a 5 MiB ZIP.
        print(json.dumps({'status': status['status'], 'files': len(entries),
                          'selectedBytes': status['selectedBytes']}))
    except Exception as error:
        # Do not print HTTP exceptions, request URLs, headers or credentials.
        status['status'] = 'inspection-failed'
        status['errorType'] = type(error).__name__
        if type(error) is ValueError:
            status['reason'] = str(error)
        status_path.write_text(json.dumps(status, indent=2) + '\n')
        print('Fixed-artifact inspection failed; bounded status retained.', file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main(Path(sys.argv[1]))
