import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from computerraria_inputs import copy_verified, extract_world, fetch, verified


class PublicFixtureIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.directory = Path(self.root.name)
        self.bytes = b'original circuit world bytes'
        self.spec = {'name': 'computerraria.wld', 'bytes': len(self.bytes),
                     'sha256': hashlib.sha256(self.bytes).hexdigest()}

    def archive(self, members):
        path = self.directory / 'input.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            for name, data, kind in members:
                item = tarfile.TarInfo(name)
                item.type = kind
                item.size = len(data) if kind == tarfile.REGTYPE else 0
                item.linkname = '../outside'
                archive.addfile(item, io.BytesIO(data) if item.isfile() else None)
        return path

    def test_regular_file_is_verified_and_existing_verified_cache_reused(self):
        archive = self.archive([('./computerraria.wld', self.bytes, tarfile.REGTYPE)])
        result = extract_world(archive, self.directory / 'out', self.spec)
        self.assertEqual(result.read_bytes(), self.bytes)
        self.assertTrue(verified(result, self.spec))
        self.assertEqual(extract_world('missing-cache-archive', result.parent, self.spec), result)

    def test_traversal_link_extra_member_and_wrong_size_are_rejected(self):
        cases = [[('../computerraria.wld', self.bytes, tarfile.REGTYPE)],
                 [('computerraria.wld', b'', tarfile.SYMTYPE)],
                 [('computerraria.wld', self.bytes, tarfile.REGTYPE), ('extra', b'x', tarfile.REGTYPE)],
                 [('computerraria.wld', self.bytes + b'x', tarfile.REGTYPE)]]
        for index, members in enumerate(cases):
            with self.subTest(index=index):
                output = self.directory / f'out-{index}'
                with self.assertRaises(ValueError):
                    extract_world(self.archive(members), output, self.spec)
                self.assertEqual(list(output.iterdir()), [])

    def test_unexpected_existing_file_is_preserved(self):
        target = self.directory / self.spec['name']
        target.write_bytes(b'user existing data')
        with self.assertRaises(ValueError):
            fetch(self.directory, self.spec, lambda *_args, **_kw: self.fail('Must not fetch'))
        self.assertEqual(target.read_bytes(), b'user existing data')

    def test_broken_symbolic_link_is_not_adopted_or_replaced(self):
        target = self.directory / self.spec['name']
        target.symlink_to('missing-target')
        with self.assertRaises(ValueError):
            fetch(self.directory, self.spec, lambda *_args, **_kw: self.fail('Must not fetch'))
        self.assertTrue(target.is_symlink())

    def test_download_corruption_and_overlength_leave_no_partial(self):
        for data in [b'wrong', self.bytes + b'x', b'x' * len(self.bytes)]:
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    fetch(self.directory, self.spec, lambda *_args, **_kw: io.BytesIO(data))
                self.assertEqual(list(self.directory.iterdir()), [])

    def test_copy_never_uses_unbounded_read(self):
        class Bounded(io.BytesIO):
            def read(self, size=-1):
                self_test.assertGreater(size, 0)
                self_test.assertLessEqual(size, 1024 * 1024)
                return super().read(size)
        self_test = self
        output = io.BytesIO()
        copy_verified(Bounded(self.bytes), output, self.spec)
        self.assertEqual(output.getvalue(), self.bytes)


if __name__ == '__main__':
    unittest.main()
