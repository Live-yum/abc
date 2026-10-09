#!/usr/bin/env python3
"""Check the distributed source closures and recorded runtime integrity."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def read_file(root, relative):
    path = root / relative
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Source must be a regular file inside its subset: {relative}")
    return path.read_bytes()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_sha_records(root, records):
    total = 0
    for record in records:
        data = read_file(root, record["path"])
        if len(data) != record["bytes"] or sha256(data) != record["sha256"]:
            raise ValueError(f"Integrity mismatch: {record['path']}")
        total += len(data)
    return total


def verify_exact_files(root, expected):
    actual = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file()}
    if actual != expected:
        raise ValueError(f"Unexpected source closure: extra={actual - expected}, missing={expected - actual}")


def main():
    # These two allowlisted WLD assets must be exact original synthetic output,
    # never user saves placed under a permitted fixture filename.
    with tempfile.TemporaryDirectory(prefix="terraforge-fixtures-") as directory:
        for name, generator in (
            ("synthetic-objects.wld", "generate_region_object_fixture.py"),
            ("synthetic-circuit.wld", "generate_circuit_fixture.py"),
        ):
            output = Path(directory) / name
            subprocess.run([sys.executable, str(ROOT / "native" / generator), str(output)],
                           cwd=ROOT, check=True, capture_output=True)
            if read_file(ROOT, f"assets/qa/{name}") != output.read_bytes():
                raise ValueError(f"Public QA asset differs from its synthetic generator: {name}")

    terra_root = ROOT / "native/vendor/TerraWasm"
    terra = json.loads((terra_root / "SOURCE_MANIFEST.json").read_text())
    if terra["sourceCommit"] != "e2c3c817b2b482a535763695d19945971e19e41c":
        raise ValueError("Unexpected TerraWasm base revision")
    terra_bytes = verify_sha_records(terra_root, terra["files"])
    verify_exact_files(terra_root, {row["path"] for row in terra["files"]} | {"SOURCE_MANIFEST.json"})

    viewer_root = ROOT / "vendor/viewer-circuit"
    viewer = json.loads((viewer_root / "retrieved-source-manifest.json").read_text())
    if viewer["commit"] != "366ebc57751cadfb077f968f4d5069028b3bf9a6" or len(viewer["files"]) != 40:
        raise ValueError("Unexpected viewer source revision or closure size")
    viewer_bytes = 0
    for record in viewer["files"]:
        data = read_file(viewer_root, record["path"])
        blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if len(data) != record["size"] or blob != record["sha"]:
            raise ValueError(f"Upstream Git blob mismatch: {record['path']}")
        viewer_bytes += len(data)
    verify_exact_files(viewer_root, {row["path"] for row in viewer["files"]} | {"README.md", "retrieved-source-manifest.json"})

    rules = json.loads((ROOT / "assets/private/circuit_rules.provenance.json").read_text())
    verify_sha_records(viewer_root, rules["modules"])
    if {row["path"] for row in rules["modules"]} != {row["path"] for row in viewer["files"]}:
        raise ValueError("Rules bundle module set differs from the distributed source closure")
    for group in ("adapters", "hosts", "outputs"):
        verify_sha_records(ROOT, rules[group])
    verify_sha_records(ROOT, [rules["helper"]])
    engines = json.loads((ROOT / "web/engine/circuit_rules.engine-provenance.json").read_text())
    verify_sha_records(ROOT, engines["artifacts"])
    source_manifest = engines["sourceManifest"]
    if sha256(read_file(ROOT, source_manifest["path"])) != source_manifest["sha256"]:
        raise ValueError("Engine source manifest differs from the recorded build provenance")
    web_manifest = json.loads((ROOT / "web/engine/manifest.json").read_text())
    if web_manifest["sourceManifestSha256"] != source_manifest["sha256"]:
        raise ValueError("Web build and engine provenance identify different source manifests")
    verify_sha_records(ROOT / "web/engine", [
        {"path": name, **record} for name, record in web_manifest["artifacts"].items()
    ])
    print(f"Verified {len(terra['files'])} TerraWasm files ({terra_bytes} bytes), "
          f"{len(viewer['files'])} viewer modules ({viewer_bytes} bytes), "
          "and generated runtime provenance.")


if __name__ == "__main__":
    main()
