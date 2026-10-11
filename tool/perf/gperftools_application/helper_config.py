"""Generate one native seal shared by both runtime-selected arms."""
import json
from pathlib import Path
import stat

from application_contract import require
from elf_identity import file_identity

ARMS = ('probe-only', 'product-with-ownership')


def write_config(path, target, allocator, directories):
    require(tuple(directories) == ARMS, 'Exactly one original control then product required')
    target, allocator = file_identity(target), file_identity(allocator)
    require(allocator['path'] == '/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16', 'Official full allocator path differs')
    def c_identity(row):
        return '{%s,%dULL,%dULL,%dULL,%s}' % (json.dumps(row['path']), row['device'], row['inode'], row['bytes'], json.dumps(row['sha256']))
    text = 'static const struct abc_file_identity abc_sealed_target=' + c_identity(target) + ';\n'
    text += 'static const struct abc_file_identity abc_sealed_library=' + c_identity(allocator) + ';\n'
    text += 'static const struct abc_arm_identity abc_sealed_arms[2]={\n'
    arms = {}
    for name, directory in directories.items():
        directory = Path(directory)
        info = directory.stat()
        require(directory.is_absolute() and directory.resolve() == directory
                and stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700,
                'Canonical private arm output required')
        text += '{%s,%s,%dULL,%dULL},\n' % (json.dumps(name), json.dumps(str(directory)), info.st_dev, info.st_ino)
        arms[name] = {'path': str(directory), 'device': info.st_dev, 'inode': info.st_ino}
    text += '};\n'
    with Path(path).open('x') as stream:
        stream.write(text)
    return {'target': target, 'allocator': allocator, 'arms': arms}
