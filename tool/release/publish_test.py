import base64
import os
import io
import unittest
import urllib.request
import zipfile
from unittest.mock import Mock, patch

import publish as p

SHA = 'a' * 40


def good_run():
    return {'id': 42, 'repository': {'id': p.REPO_ID}, 'head_repository': {'id': p.REPO_ID},
            'workflow_id': p.WORKFLOW_ID, 'path': '.github/workflows/ci.yml',
            'event': 'push', 'head_branch': 'main', 'head_sha': SHA,
            'status': 'completed', 'conclusion': 'success'}


def archive(entries):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as z:
        for name, value in entries:
            z.writestr(name, value)
    return data.getvalue()


class GuardTests(unittest.TestCase):
    def test_successful_main_build(self):
        p.validate_run(good_run(), [{'name': n, 'conclusion': 'success'} for n in p.EXPECTED_JOBS])

    def test_reject_wrong_runs(self):
        for key, value in [('event', 'pull_request'), ('head_branch', 'feature'),
                           ('conclusion', 'failure'), ('status', 'in_progress'),
                           ('workflow_id', 1), ('path', 'evil.yml'), ('head_sha', 'main'),
                           ('head_repository', {'id': 1}), ('repository', {'id': 1})]:
            with self.subTest(key=key):
                run = good_run()
                run[key] = value
                with self.assertRaises(ValueError):
                    p.validate_run(run, [{'name': n, 'conclusion': 'success'} for n in p.EXPECTED_JOBS])

    def test_all_five_jobs_required(self):
        jobs = [{'name': n, 'conclusion': 'success'} for n in p.EXPECTED_JOBS]
        for invalid in [jobs[:-1], jobs + [jobs[0]], [{**j, 'conclusion': 'skipped'} for j in jobs]]:
            with self.assertRaises(ValueError):
                p.validate_run(good_run(), invalid)

    def artifacts(self):
        return [{'id': i, 'name': f'{name}-{SHA}', 'digest': 'sha256:' + 'b' * 64,
                 'expired': False, 'workflow_run': {'id': 42, 'head_sha': SHA, 'head_branch': 'main',
                     'repository_id': p.REPO_ID, 'head_repository_id': p.REPO_ID}}
                for i, name in enumerate(p.PACKAGES)]

    def test_sha_bound_artifacts(self):
        self.assertEqual(4, len(p.select_artifacts(self.artifacts(), good_run())))
        for key, value in [('expired', True), ('digest', None), ('name', 'unbound')]:
            artifacts = self.artifacts()
            artifacts[0][key] = value
            with self.assertRaises((ValueError, TypeError)):
                p.select_artifacts(artifacts, good_run())
        artifacts = self.artifacts()
        artifacts[0]['workflow_run']['head_repository_id'] = 5
        with self.assertRaises(ValueError):
            p.select_artifacts(artifacts, good_run())
        with self.assertRaises(ValueError):
            p.select_artifacts(self.artifacts() + [self.artifacts()[0]], good_run())

    def test_valid_zip(self):
        data = archive([('app-release.apk', b'package')])
        result = p.unpack(data, p.PACKAGES['terraforge-android-unsigned'], p.digest(data))
        self.assertEqual({'terraforge-android-unsigned.apk': b'package'}, result)

    def test_reject_archive_mutation_and_bad_paths(self):
        expected = p.PACKAGES['terraforge-android-unsigned']
        data = archive([('app-release.apk', b'package')])
        with self.assertRaises(ValueError):
            p.unpack(data, expected, 'sha256:' + '0' * 64)
        for name in ['../app-release.apk', '/app-release.apk', 'nested/app-release.apk', 'app-release.apk\\evil', 'evil.sh']:
            data = archive([(name, b'bad')])
            with self.assertRaises(ValueError):
                p.unpack(data, expected, p.digest(data))
        data = archive([('app-release.apk', b'package'), ('app-release.apk', b'other')])
        with self.assertRaises(ValueError):
            p.unpack(data, expected, p.digest(data))
        data = archive([])
        with self.assertRaises(ValueError):
            p.unpack(data, expected, p.digest(data))

    def test_symlink_rejected(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as z:
            info = zipfile.ZipInfo('app-release.apk')
            info.external_attr = 0o120777 << 16
            z.writestr(info, '../secret')
        with self.assertRaises(ValueError):
            p.unpack(stream.getvalue(), p.PACKAGES['terraforge-android-unsigned'], p.digest(stream.getvalue()))

    def test_tag_never_repointed(self):
        api = Mock()
        api.request.return_value = {'object': {'type': 'commit', 'sha': SHA}}
        p.validate_tag(api, 'v0.1.0-preview.1', SHA)
        for value in [None, {'object': {'type': 'commit', 'sha': 'b' * 40}}, {'object': {'type': 'tag', 'sha': SHA}}]:
            api.request.return_value = value
            with self.assertRaises(ValueError):
                p.validate_tag(api, 'v0.1.0-preview.1', SHA, required=True)

    def test_release_assets_must_match_exactly(self):
        files = {'app.apk': b'package'}
        valid = {'name': 'app.apk', 'size': 7, 'digest': p.digest(b'package'), 'state': 'uploaded'}
        p.verify_assets([valid], files, True)
        for assets in [[], [valid, valid], [{**valid, 'digest': p.digest(b'other')}],
                       [{**valid, 'size': 8}], [{**valid, 'name': 'other'}], [{**valid, 'state': 'starter'}]]:
            with self.assertRaises(ValueError):
                p.verify_assets(assets, files, True)

    def test_published_release_is_read_only(self):
        files = {'app.apk': b'package'}
        release = {'id': 1, 'tag_name': 'v1', 'target_commitish': SHA, 'prerelease': True,
                   'draft': False, 'html_url': 'https://github.com/Live-yum/abc/releases/tag/v1'}
        api = Mock()
        api.request.return_value = {'object': {'type': 'commit', 'sha': SHA}}
        api.pages.side_effect = [[release], [{'name': 'app.apk', 'size': 7,
            'digest': p.digest(b'package'), 'state': 'uploaded'}]]
        p.publish(api, good_run(), files, 'notes', 'v1')
        self.assertTrue(all('method' not in call.kwargs for call in api.request.call_args_list))

    def test_interrupted_draft_resumes_without_reupload(self):
        files = {'app.apk': b'package'}
        release = {'id': 1, 'tag_name': 'v1', 'target_commitish': SHA, 'prerelease': True,
                   'draft': True, 'body': 'notes', 'html_url': 'https://github.com/Live-yum/abc/releases/tag/v1'}
        asset = {'name': 'app.apk', 'size': 7, 'digest': p.digest(b'package'), 'state': 'uploaded'}
        api = Mock()
        api.pages.side_effect = [[release], [asset], [asset], [asset]]
        api.request.side_effect = lambda path, **kw: {**release, 'draft': False} if kw.get('method') == 'PATCH' else {'object': {'type': 'commit', 'sha': SHA}}
        p.publish(api, good_run(), files, 'notes', 'v1')
        mutations = [call for call in api.request.call_args_list if 'method' in call.kwargs]
        self.assertEqual(1, len(mutations))
        self.assertEqual('PATCH', mutations[0].kwargs['method'])

    def test_new_release_is_draft_until_assets_verify(self):
        files = {'app.apk': b'package'}
        release = {'id': 1, 'tag_name': 'v1', 'target_commitish': SHA, 'prerelease': True,
                   'draft': True, 'body': 'notes', 'html_url': 'https://github.com/Live-yum/abc/releases/tag/v1'}
        asset = {'name': 'app.apk', 'size': 7, 'digest': p.digest(b'package'), 'state': 'uploaded'}
        api = Mock()
        api.pages.side_effect = [[], [asset], [asset]]
        def request(path, **kw):
            if path == 'releases':
                self.assertTrue(kw['data']['draft'])
                self.assertTrue(kw['data']['prerelease'])
                self.assertEqual(SHA, kw['data']['target_commitish'])
                return release
            if path.startswith('https://uploads.github.com/'):
                return asset
            if kw.get('method') == 'PATCH':
                return {**release, 'draft': False}
            return {'object': {'type': 'commit', 'sha': SHA}}
        api.request.side_effect = request
        p.publish(api, good_run(), files, 'notes', 'v1')
        mutations = [call for call in api.request.call_args_list if 'method' in call.kwargs]
        self.assertEqual(['POST', 'POST', 'PATCH'], [c.kwargs['method'] for c in mutations])

    def test_corrupt_draft_is_not_repaired_destructively(self):
        files = {'app.apk': b'package'}
        release = {'id': 1, 'tag_name': 'v1', 'target_commitish': SHA, 'prerelease': True,
                   'draft': True, 'body': 'notes'}
        api = Mock()
        api.request.return_value = {'object': {'type': 'commit', 'sha': SHA}}
        api.pages.side_effect = [[release], [{'name': 'app.apk', 'size': 7,
            'digest': p.digest(b'corrupt'), 'state': 'uploaded'}]]
        with self.assertRaises(ValueError):
            p.publish(api, good_run(), files, 'notes', 'v1')
        self.assertTrue(all('method' not in call.kwargs for call in api.request.call_args_list))

    def test_existing_bootstrap_does_not_need_expired_artifacts(self):
        run = {**good_run(), 'run_number': 14}
        release = {'id': 1, 'draft': False, 'prerelease': True,
                   'target_commitish': SHA, 'html_url': 'https://github.com/Live-yum/abc/releases/tag/v1'}
        names = {name for package in p.PACKAGES.values() for name in package.values()}
        names |= {'BUILD-PROVENANCE.json', 'SHA256SUMS'}
        api = Mock()
        def request(path, **kw):
            self.assertNotIn('artifacts', path)
            self.assertNotIn('method', kw)
            if path.startswith('actions/runs/'):
                return run
            if path.startswith('compare/'):
                return {'status': 'ahead'}
            if path.startswith('contents/'):
                return {'content': base64.b64encode(b'version: 0.1.0+1').decode()}
            if path.startswith('releases/tags/'):
                return release
            if path.startswith('git/ref/'):
                return {'object': {'type': 'commit', 'sha': SHA}}
            self.fail(path)
        api.request.side_effect = request
        api.pages.side_effect = [[{'name': n, 'conclusion': 'success'} for n in p.EXPECTED_JOBS],
                                [{'name': n, 'state': 'uploaded', 'digest': 'sha256:' + 'b' * 64} for n in names]]
        with patch.object(p, 'API', return_value=api), patch.dict(os.environ, {
            'GITHUB_REPOSITORY': p.REPO, 'RELEASE_RUN_ID': '42', 'GITHUB_EVENT_NAME': 'push',
        }):
            p.main()

    def test_redirect_drops_authorization(self):
        handler = p.SafeRedirect()
        request = urllib.request.Request('https://api.github.com/repos/Live-yum/abc/actions/artifacts/1/zip',
                                         headers={'Authorization': 'Bearer fake-test-only'})
        redirected = handler.redirect_request(request, None, 302, 'Found', {}, 'https://example.com/archive')
        self.assertFalse(redirected.has_header('Authorization'))
        with self.assertRaises(ValueError):
            handler.redirect_request(request, None, 302, 'Found', {}, 'http://example.com/archive')

    def test_versions(self):
        self.assertEqual('0.1.0', p.version_from_pubspec('name: x\nversion: 0.1.0+1\n'))
        for raw in ['version: latest', 'version: 1.0', 'name: no-version']:
            with self.assertRaises(ValueError):
                p.version_from_pubspec(raw)


if __name__ == '__main__':
    unittest.main()
