#!/usr/bin/env python3
"""Verify the reviewed, human-readable diagnostic payload before setup/build."""
import hashlib
import json
from pathlib import Path


def verify(repo):
    repo = Path(repo).resolve()
    manifest = json.loads((repo / "tool/perf/native_read_paired/source-manifest.json").read_text())
    for record in manifest["files"]:
        path = repo / record["path"]
        if not path.resolve().is_relative_to(repo) or path.is_symlink():
            raise ValueError(f"Invalid diagnostic source path: {record['path']}")
        data = path.read_bytes()
        if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise ValueError(f"Diagnostic source pin mismatch: {record['path']}")
    return len(manifest["files"])


if __name__ == "__main__":
    count = verify(Path(__file__).resolve().parents[3])
    print(f"Verified {count} reviewed diagnostic source files")
