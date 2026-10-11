"""Pure offline seal-header preparation; never compiles or launches a target.

Build order: seal target/library/output/helper path; compile helper; seal its
actual hash into a second launcher header; compile launcher. The helper cannot
embed its own SHA without a circular build. The launcher verifies helper SHA.
All identities are observations, not immutable/atomic filesystem guarantees.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import re
import stat

FILE_LIMIT = 64 * 1024 * 1024
OFFICIAL_LIBRARY = "/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16"

def canonical_path(path: str | Path) -> str:
    value = os.fspath(path)
    if not value.startswith("/") or str(Path(value).resolve(strict=True)) != value:
        raise ValueError("seal requires an existing canonical absolute path")
    if len(os.fsencode(value)) >= 1024 or any(ord(c) < 32 or ord(c) > 126 or c in '"\\' for c in value):
        raise ValueError("seal paths must be printable ASCII and shorter than 1024 bytes")
    return value

def file_identity(path: str | Path, *, executable: bool = False) -> dict:
    value = canonical_path(path)
    fd = os.open(value, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_size > FILE_LIMIT or
                (executable and not before.st_mode & 0o111)):
            raise ValueError("invalid sealed file")
        data = bytearray()
        while len(data) <= FILE_LIMIT:
            part = os.read(fd, min(8192, FILE_LIMIT + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(fd)
        if (len(data) != before.st_size or len(data) > FILE_LIMIT or
                (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            raise ValueError("sealed file changed while read")
        if executable and data[:4] != b"\x7fELF":
            raise ValueError("sealed target must be ELF")
        return dict(path=value, device=before.st_dev, inode=before.st_ino,
                    size=before.st_size, sha256=hashlib.sha256(data).hexdigest())
    finally:
        os.close(fd)

def output_identity(path: str | Path) -> dict:
    value = canonical_path(path)
    st = os.stat(value, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o700 or st.st_uid != os.geteuid():
        raise ValueError("output must be an owned mode-0700 directory")
    return dict(path=value, device=st.st_dev, inode=st.st_ino)

def render_header(target: dict, library: dict, output: dict, helper_path: str,
                  *, helper: dict | None = None) -> str:
    # helper_path need not exist until after the first helper build.
    if (not helper_path.startswith("/") or len(os.fsencode(helper_path)) >= 1024 or
            any(ord(c) < 32 or ord(c) > 126 or c in '"\\' for c in helper_path)):
        raise ValueError("invalid helper path")
    def quoted(value):
        return json.dumps(value, ensure_ascii=True)
    def identity(name, record):
        canonical_path(record["path"])
        if (any(type(record[key]) is not int or record[key] < 0 for key in ("device", "inode", "size")) or
                record["size"] > FILE_LIMIT or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"])):
            raise ValueError("invalid file identity")
        return (f"static const struct abc_file_identity {name} = {{"
                f"{quoted(record['path'])}, UINT64_C({record['device']}), "
                f"UINT64_C({record['inode']}), UINT64_C({record['size']}), "
                f"{quoted(record['sha256'])}}};\n")
    text = "/* Generated observed identities; no live defaults. */\n"
    text += identity("abc_sample_sealed_target", target)
    text += identity("abc_sample_sealed_library", library)
    canonical_path(output["path"])
    if any(type(output[key]) is not int or output[key] < 0 for key in ("device", "inode")):
        raise ValueError("invalid output identity")
    text += ("static const struct abc_arm_identity abc_sample_sealed_output = {"
             f'"sampled-q0", {quoted(output["path"])}, UINT64_C({output["device"]}), '
             f'UINT64_C({output["inode"]})}};\n')
    text += f"static const char abc_sample_sealed_helper_path[] = {quoted(helper_path)};\n"
    if helper is not None:
        if helper["path"] != helper_path:
            raise ValueError("helper path mismatch")
        text += "#define ABC_SAMPLE_HAS_SEALED_HELPER 1\n"
        text += identity("abc_sample_sealed_helper", helper)
    return text
