"""Guard added-source provenance without inventing an upstream before blob."""
import hashlib
from pathlib import Path
import tempfile
import unittest

from verify_authorized_sources import verify_created_source_records


class CreatedSourceProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "added.c").write_bytes(b"/* original local code */\n")
        data = (self.root / "added.c").read_bytes()
        self.record = {
            "path": "added.c", "origin": "original-abc-implementation",
            "beforeExists": False,
            "introducedAfterCommit": "5c659e6832d0ed00851d82dc7287cc3e8f3d2480",
            "afterBytes": len(data), "afterSha256": hashlib.sha256(data).hexdigest(),
        }

    def test_accepts_an_exact_new_local_file_and_empty_list(self):
        verify_created_source_records(self.root, [self.record], set())
        verify_created_source_records(self.root, [], {"unrelated.c"})

    def test_rejects_claims_of_old_source_and_missing_origin(self):
        mutations = [
            {"beforeExists": True}, {"beforeExists": 0},
            {"origin": "upstream"}, {"introducedAfterCommit": "unknown"},
            {"beforeSha256": "0" * 64}, {"beforeBytes": 0},
            {"afterBytes": 0}, {"afterBytes": True},
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                changed = {**self.record, **mutation}
                with self.assertRaises(ValueError):
                    verify_created_source_records(self.root, [changed], set())

    def test_rejects_duplicate_or_modified_removed_overlap(self):
        with self.assertRaises(ValueError):
            verify_created_source_records(self.root, [self.record] * 2, set())
        with self.assertRaises(ValueError):
            verify_created_source_records(self.root, [self.record], {"added.c"})

    def test_rejects_changed_bytes_or_identity(self):
        for mutation in [{"afterSha256": "0" * 64}, {"afterBytes": 999}]:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verify_created_source_records(self.root, [{**self.record, **mutation}], set())
        (self.root / "added.c").write_text("changed")
        with self.assertRaises(ValueError):
            verify_created_source_records(self.root, [self.record], set())

    def test_rejects_link_and_outside_subset(self):
        (self.root / "link.c").symlink_to(self.root / "added.c")
        for path in ("link.c", "../outside.c"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                verify_created_source_records(self.root, [{**self.record, "path": path}], set())


if __name__ == "__main__":
    unittest.main()
