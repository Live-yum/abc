"""Publish only successful, same-repository push-to-main Flutter CI artifacts.

No external dependencies, build execution, artifact execution, secrets beyond the
job-scoped GITHUB_TOKEN, stable releases, clobbering or deletion.
"""
import base64
import hashlib
import io
import json
import os
from pathlib import PurePosixPath
import re
import stat
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPO = 'Live-yum/abc'
REPO_ID = 1410608255
WORKFLOW_ID = 379151257
EXPECTED_JOBS = {
    'Analyze, tests, and Web', 'Native engine ASan and UBSan contracts',
    'Android unsigned release build', 'macOS and unsigned iOS builds',
    'Linux desktop build',
}
PACKAGES = {
    'terraforge-web': {'terraforge-web.tar.gz': 'terraforge-web.tar.gz'},
    'terraforge-linux': {'terraforge-linux.tar.gz': 'terraforge-linux.tar.gz'},
    'terraforge-apple-unsigned': {
        'terraforge-macos-unsigned.tar.gz': 'terraforge-macos-unsigned.tar.gz',
        'terraforge-ios-unsigned.tar.gz': 'terraforge-ios-unsigned.tar.gz',
    },
    'terraforge-android-unsigned': {'app-release.apk': 'terraforge-android-unsigned.apk'},
}
MAX_ARCHIVE = 500 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(urllib.parse.urlsplit(newurl).scheme == 'https', 'Non-HTTPS redirect')
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if urllib.parse.urlsplit(req.full_url).netloc != urllib.parse.urlsplit(newurl).netloc:
            redirected.remove_header('Authorization')
        return redirected


class API:
    def __init__(self):
        self.token = os.environ['GH_TOKEN']
        self.opener = urllib.request.build_opener(SafeRedirect())

    def request(self, path, method='GET', data=None, binary=False, missing_ok=False):
        url = path if path.startswith('https://') else f'https://api.github.com/repos/{REPO}/{path}'
        parsed = urllib.parse.urlsplit(url)
        require(parsed.netloc in {'api.github.com', 'uploads.github.com'}, 'Unexpected API host')
        require(parsed.path.startswith(f'/repos/{REPO}/'), 'Unexpected API repository')
        headers = {'Authorization': f'Bearer {self.token}',
                   'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'terraforge-release'}
        if isinstance(data, bytes):
            headers['Content-Type'] = 'application/octet-stream'
        elif data is not None:
            data = json.dumps(data).encode()
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=120) as response:
                body = response.read(MAX_ARCHIVE + 1)
            require(len(body) <= MAX_ARCHIVE, 'Response exceeds size bound')
            return body if binary else json.loads(body or b'null')
        except urllib.error.HTTPError as error:
            if error.code == 404 and missing_ok:
                return None
            # Do not log redirected URLs or request headers.
            raise RuntimeError(f'GitHub API {method} failed with HTTP {error.code}') from None

    def pages(self, path, key=None):
        result = []
        separator = '&' if '?' in path else '?'
        for page in range(1, 101):
            response = self.request(f'{path}{separator}per_page=100&page={page}')
            items = response[key] if key else response
            result.extend(items)
            if len(items) < 100:
                return result
        raise ValueError('Pagination limit exceeded')


def validate_run(run, jobs):
    require(run['repository']['id'] == REPO_ID and
            run['head_repository']['id'] == REPO_ID, 'Foreign repository')
    require(run['workflow_id'] == WORKFLOW_ID and run['path'] == '.github/workflows/ci.yml',
            'Wrong build workflow')
    require(run['event'] == 'push' and run['head_branch'] == 'main', 'Not a main push')
    require(run['status'] == 'completed' and run['conclusion'] == 'success', 'Build not successful')
    require(re.fullmatch(r'[0-9a-f]{40}', run['head_sha']), 'Invalid source SHA')
    require({job['name'] for job in jobs} == EXPECTED_JOBS and len(jobs) == 5,
            'Missing or unexpected functional jobs')
    require(all(job['conclusion'] == 'success' for job in jobs), 'Functional job not successful')


def select_artifacts(artifacts, run):
    selected = []
    for prefix in PACKAGES:
        found = [a for a in artifacts if a['name'] == f"{prefix}-{run['head_sha']}"]
        require(len(found) == 1, f'Missing or duplicate artifact: {prefix}')
        artifact = found[0]
        origin = artifact['workflow_run']
        require(not artifact['expired'], 'Expired artifact')
        require(origin['id'] == run['id'] and origin['head_sha'] == run['head_sha'] and
                origin['repository_id'] == REPO_ID and origin['head_repository_id'] == REPO_ID and
                origin['head_branch'] == 'main', 'Artifact provenance mismatch')
        require(re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest', '')), 'Missing artifact digest')
        selected.append((prefix, artifact))
    return selected


def unpack(data, expected, archive_digest):
    require(digest(data) == archive_digest, 'Artifact archive digest mismatch')
    result = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = [i for i in archive.infolist() if not i.is_dir()]
        require(sum(i.file_size for i in members) <= MAX_ARCHIVE, 'Expanded artifact too large')
        for info in members:
            path = PurePosixPath(info.filename)
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in info.filename,
                    'Unsafe archive path')
            require(not stat.S_ISLNK(info.external_attr >> 16), 'Artifact symlink rejected')
            require(info.filename in expected, 'Unexpected file in artifact')
            target = expected[info.filename]
            require(target not in result, 'Duplicate artifact file')
            result[target] = archive.read(info)
        require(set(result) == set(expected.values()), 'Incomplete artifact files')
    return result


def version_from_pubspec(raw):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$', raw, re.M)
    require(match is not None, 'Unrecognized pubspec version; review versioning before publishing')
    return match.group(1)


def validate_tag(api, tag, sha, required=False):
    ref = api.request(f'git/ref/tags/{tag}', missing_ok=True)
    if ref is None:
        require(not required, 'Published release has no tag')
        return
    # Only our immutable lightweight tag is supported; never repoint a tag.
    require(ref['object']['type'] == 'commit' and ref['object']['sha'] == sha,
            'Existing tag does not point to the exact verified source')


def verify_assets(assets, files, complete):
    names = [asset['name'] for asset in assets]
    require(len(names) == len(set(names)), 'Duplicate release asset names')
    require(set(names) <= set(files), 'Unexpected existing release assets')
    for asset in assets:
        data = files[asset['name']]
        require(asset['state'] == 'uploaded' and asset['size'] == len(data) and
                asset.get('digest') == digest(data), 'Existing release asset mismatch; refusing overwrite')
    if complete:
        require(set(names) == set(files), 'Published release assets incomplete; refusing mutation')


def publish(api, run, files, notes, tag):
    sha = run['head_sha']
    validate_tag(api, tag, sha)
    # Listing includes drafts for this job token, allowing safe interrupted-upload recovery.
    matches = [r for r in api.pages('releases') if r['tag_name'] == tag]
    require(len(matches) <= 1, 'Multiple matching releases')
    release = matches[0] if matches else None
    if release:
        require(release['target_commitish'] == sha and release['prerelease'],
                'Existing release target/type mismatch')
        assets = api.pages(f"releases/{release['id']}/assets")
        verify_assets(assets, files, complete=not release['draft'])
        if not release['draft']:
            validate_tag(api, tag, sha, required=True)
            print(f"Already published and verified: {release['html_url']}")
            return release
        require(release['body'] == notes, 'Existing draft notes differ; refusing overwrite')
    else:
        release = api.request('releases', method='POST', data={
            'tag_name': tag, 'target_commitish': sha, 'name': f'TerraForge {tag} (preview)',
            'body': notes, 'draft': True, 'prerelease': True, 'make_latest': 'false',
        })
        assets = []
    existing = {a['name'] for a in assets}
    for name, data in sorted(files.items()):
        if name not in existing:
            api.request(f"https://uploads.github.com/repos/{REPO}/releases/{release['id']}/assets?name={urllib.parse.quote(name)}",
                        method='POST', data=data)
    verify_assets(api.pages(f"releases/{release['id']}/assets"), files, complete=True)
    validate_tag(api, tag, sha)
    release = api.request(f"releases/{release['id']}", method='PATCH',
                          data={'draft': False, 'prerelease': True, 'make_latest': 'false'})
    require(not release['draft'] and release['prerelease'], 'Release publication not confirmed')
    validate_tag(api, tag, sha, required=True)
    verify_assets(api.pages(f"releases/{release['id']}/assets"), files, complete=True)
    print(f"Published and verified: {release['html_url']}")
    return release


def main():
    require(os.environ.get('GITHUB_REPOSITORY') == REPO, 'Wrong workflow repository')
    run_id = os.environ['RELEASE_RUN_ID']
    require(re.fullmatch(r'[0-9]+', run_id), 'Invalid run ID')
    api = API()
    run = api.request(f'actions/runs/{run_id}')
    jobs = api.pages(f'actions/runs/{run_id}/jobs?filter=latest', 'jobs')
    validate_run(run, jobs)
    sha = run['head_sha']
    ancestry = api.request(f'compare/{sha}...main')
    require(ancestry['status'] in {'ahead', 'identical'}, 'Verified source is not on main')
    source = api.request(f'contents/pubspec.yaml?ref={sha}')
    version = version_from_pubspec(base64.b64decode(source['content']).decode())
    tag = f"v{version}-preview.{run['run_number']}.{sha[:12]}"
    # The one-time bootstrap must not depend on expired CI artifacts forever.
    # A previously published bootstrap is only inspected, never republished.
    if os.environ.get('GITHUB_EVENT_NAME') == 'push':
        existing = api.request(f'releases/tags/{tag}', missing_ok=True)
        if existing is not None and not existing['draft']:
            require(existing['target_commitish'] == sha and existing['prerelease'],
                    'Existing bootstrap target/type mismatch')
            validate_tag(api, tag, sha, required=True)
            assets = api.pages(f"releases/{existing['id']}/assets")
            expected = {name for package in PACKAGES.values() for name in package.values()}
            expected |= {'BUILD-PROVENANCE.json', 'SHA256SUMS'}
            require(len(assets) == len(expected) and {a['name'] for a in assets} == expected and
                    all(a['state'] == 'uploaded' and re.fullmatch(r'sha256:[0-9a-f]{64}', a.get('digest') or '')
                        for a in assets), 'Existing bootstrap asset metadata incomplete')
            print(f"Bootstrap already published; tag and asset metadata checked: {existing['html_url']}")
            return
    selected = select_artifacts(api.pages(f'actions/runs/{run_id}/artifacts', 'artifacts'), run)
    files = {}
    for prefix, artifact in selected:
        data = api.request(f"actions/artifacts/{artifact['id']}/zip", binary=True)
        files.update(unpack(data, PACKAGES[prefix], artifact['digest']))
    manifest = {
        'schema_version': 1, 'repository': REPO, 'source_sha': sha,
        'version': version, 'tag': tag, 'ci_run_id': run['id'], 'ci_run_attempt': run['run_attempt'],
        'ci_url': run['html_url'], 'workflow_id': run['workflow_id'],
        'functional_jobs': [{'name': j['name'], 'conclusion': j['conclusion']} for j in sorted(jobs, key=lambda job: job['name'])],
        'artifacts': [{'id': a['id'], 'name': a['name'], 'digest': a['digest']} for _, a in selected],
        'assets': {name: {'sha256': digest(data)[7:], 'size': len(data)} for name, data in sorted(files.items())},
        'classification': 'preview; not stable; performance and target-device acceptance incomplete',
    }
    files['BUILD-PROVENANCE.json'] = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    files['SHA256SUMS'] = ''.join(f'{digest(data)[7:]}  {name}\n' for name, data in sorted(files.items())).encode()
    notes = f'''## Experimental preview / 实验性预发布

Source: `{sha}`. Built by [Flutter CI run {run['id']}]({run['html_url']}) (attempt {run['run_attempt']}).
All five functional CI jobs succeeded for this exact main commit. Attached packages are copied from that run, not rebuilt from another branch. See BUILD-PROVENANCE.json and SHA256SUMS for provenance and integrity.

### Important limitations / 已知限制
- This is not a stable or feature-equivalent release. Passing functional builds does not establish performance or real-device acceptance.
- Earlier recorded performance comparisons failed, and prior eight-cycle memory measurements did not establish a plateau. Real-device smoothness remains unverified/unmet. A successful correctness/report-generation workflow does not establish these performance acceptance goals; no performance gates have been relaxed. See [performance requirements](https://github.com/{REPO}/blob/{sha}/tool/perf/README.md) and [complete Computerraria acceptance](https://github.com/{REPO}/blob/{sha}/docs/COMPUTERRARIA.md).
- Android APK is **unsigned** and cannot be installed as-is; distribution signing is not configured.
- iOS is an **unsigned Runner.app build archive**, not an installable signed IPA; device provisioning/signing and App Store release are not included.
- macOS is **unsigned and not notarized**. Linux is the x64 desktop bundle; Web is a static bundle that must be served over HTTP(S). Neither is deployed by this workflow.
- No Windows package was built. No production deployment, store submission, signing keys or persistent credentials are created.
- Keep backups of original saves. Builds and synthetic round-trip tests do not certify in-game compatibility.

### Verification
Run `sha256sum -c SHA256SUMS` beside the downloaded assets. The provenance file records the exact source SHA, functional CI run, upstream artifact IDs/digests and package hashes. Re-running publication verifies an existing release; it never replaces its tag or assets.
'''
    release = publish(api, run, files, notes, tag)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as output:
            output.write(f"Preview: {release['html_url']}\n\nVerified source: `{sha}`; five platform packages plus provenance and checksums.\n")


if __name__ == '__main__':
    main()
