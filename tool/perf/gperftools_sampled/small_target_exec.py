"""One sealed small-contract exec; profiler environment never enters driver.

Only the CI orchestrator calls this. File descriptors bind the target and the
official library observation; the dynamic loader pathname is not an atomic FD
binding. The target rechecks its loaded provider before any sample.
"""
import json
import hashlib
import os
import stat
from pathlib import Path
import sys

from sampled_seal_config import file_identity, OFFICIAL_LIBRARY


def open_sealed(record):
    """Retain the exact inode and verify its complete bounded bytes before exec."""
    fd = os.open(record['path'], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        expected = (record['device'], record['inode'], record['size'])
        if (not stat.S_ISREG(before.st_mode) or (before.st_dev, before.st_ino, before.st_size) != expected
                or not 0 < before.st_size <= 64 << 20):
            raise ValueError('Small retained file identity differs')
        digest, consumed = hashlib.sha256(), 0
        while consumed < before.st_size:
            block = os.read(fd, min(1 << 20, before.st_size - consumed))
            if not block:
                raise ValueError('Small retained file truncated')
            digest.update(block)
            consumed += len(block)
        after = os.fstat(fd)
        if (digest.hexdigest() != record['sha256'] or os.read(fd, 1)
                or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            raise ValueError('Small retained file bytes changed')
        return fd
    except BaseException as primary:
        try:
            os.close(fd)
        except OSError as error:
            primary.add_note('Retained descriptor close failed; not retried: ' + repr(error))
        raise


def close_once_all(descriptors, primary=None):
    failures = []
    for descriptor in descriptors:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as error:
                failures.append(repr(error))
    if failures:
        message = 'Small exec descriptor cleanup failed without retry: ' + repr(failures)
        if primary is not None:
            primary.add_note(message)
        else:
            raise ValueError(message)


def execute(seal_path, output):
    if (os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('CI') != 'true'
            or os.environ.get('GITHUB_REF') != 'refs/heads/codex/sampled-q0-feasibility-9d4'
            or os.environ.get('GITHUB_RUN_ATTEMPT') != '1'):
        raise ValueError('Small official execution requires fixed first-attempt CI')
    seal_path, output = Path(seal_path), Path(output)
    if seal_path.stat().st_size > 4096:
        raise ValueError('Small exec seal too large')
    seal = json.loads(seal_path.read_bytes())
    if set(seal) != {'target', 'library'} or seal['library']['path'] != OFFICIAL_LIBRARY:
        raise ValueError('Small exec seal differs')
    if file_identity(seal['target']['path'], executable=True) != seal['target'] or file_identity(OFFICIAL_LIBRARY) != seal['library']:
        raise ValueError('Small target or official library changed')
    if output.exists() or not output.is_absolute() or output.parent.resolve() != output.parent:
        raise ValueError('Small output must be a fresh absolute path')
    output.mkdir(mode=0o700)
    with (output / 'launch.once').open('x') as token:
        token.write(f'ABC_SAMPLED_SMALL_ONCE_V1 {os.getpid()}\n')
        token.flush()
        os.fsync(token.fileno())
    env = {k: v for k, v in os.environ.items() if not k.startswith(('LD_', 'HEAP', 'TCMALLOC', 'CPUPROFILE', 'MALLOC'))}
    env.update(LD_PRELOAD=OFFICIAL_LIBRARY, TCMALLOC_SAMPLE_PARAMETER='524288', ABC_SAMPLED_DIAGNOSTIC='1')
    target_fd = library_fd = None
    try:
        target_fd = open_sealed(seal['target'])
        library_fd = open_sealed(seal['library'])
        if file_identity(OFFICIAL_LIBRARY) != seal['library']:
            raise ValueError('Small loader library path changed')
        # FD exec binds executable bytes. The loader still resolves its library
        # pathname; actual loaded provider is independently checked by target.
        os.execve(target_fd, [seal['target']['path'], str(output)], env)
    finally:
        close_once_all((library_fd, target_fd), sys.exc_info()[1])


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Expected seal and fresh output directory')
    execute(sys.argv[1], sys.argv[2])
