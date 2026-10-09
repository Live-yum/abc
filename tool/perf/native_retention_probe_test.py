"""Bounded C ABI/FFI contracts. No Flutter build, world, CI or network action."""
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIELDS = ('arena', 'ordblks', 'smblks', 'hblks', 'hblkhd', 'usmblks',
          'fsmblks', 'uordblks', 'fordblks', 'keepcost')


class NativeProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('C compiler unavailable')
        cls.temp = tempfile.TemporaryDirectory(prefix='abc-retention-contract-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.available = cls.compile(compiler, 'available')
        cls.unsupported = cls.compile(compiler, 'unsupported',
                                      '-DABC_RETENTION_DISABLE_MALLINFO2')

    @classmethod
    def compile(cls, compiler, name, *defines):
        target = cls.directory / f'{name}.so'
        subprocess.run([compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-fPIC', '-fvisibility=hidden', '-shared', *defines,
                        str(ROOT / 'tool/perf/native_retention_probe.c'),
                        '-ldl', '-pthread', '-o', str(target)],
                       check=True, capture_output=True, timeout=30)
        return target

    def load(self, path):
        library = ctypes.CDLL(str(path))
        initialize = library.abc_retention_initialize_v1
        initialize.argtypes, initialize.restype = [], ctypes.c_int
        snapshot = library.abc_retention_snapshot_v1
        snapshot.argtypes = [ctypes.POINTER(ctypes.c_uint64), ctypes.c_size_t]
        snapshot.restype = ctypes.c_int
        initialize()
        return snapshot

    def test_exact_word_count_and_no_partial_overwrite(self):
        snapshot = self.load(self.available)
        words = (ctypes.c_uint64 * 18)(*[12345] * 18)
        for count in (0, 15, 17):
            self.assertEqual(snapshot(words, count), -1)
            self.assertEqual(list(words), [12345] * 18)
        self.assertEqual(snapshot(None, 16), -1)
        snapshot(words, 16)
        self.assertEqual(list(words)[16:], [12345, 12345])

    def test_supported_layout_and_arena_accounting(self):
        # This cloud's Python binary itself overrides malloc/free. A fresh C
        # process verifies the available path against the official header.
        source = self.directory / 'direct-contract.c'
        source.write_text(r'''
#include <assert.h>
#include <malloc.h>
#include <stdint.h>
#include <stdlib.h>
extern int abc_retention_initialize_v1(void);
extern int abc_retention_snapshot_v1(uint64_t *, size_t);
int main(void) {
  uint64_t w[16], before[16], allocated[16], released[16];
  assert(abc_retention_initialize_v1() == 0);
  assert(abc_retention_snapshot_v1(w, 16) == 0);
  const struct mallinfo2 m = mallinfo2();
  const size_t expected[] = {m.arena,m.ordblks,m.smblks,m.hblks,m.hblkhd,
                            m.usmblks,m.fsmblks,m.uordblks,m.fordblks,m.keepcost};
  assert(w[0] == 1 && w[2] == sizeof(size_t) && w[3] == sizeof(m));
  for (size_t i=0;i<10;++i) assert(w[6+i] == expected[i]);
  assert(w[6] == w[13] + w[14]);
  assert(abc_retention_snapshot_v1(before, 16) == 0);
  unsigned char *data = malloc(2 * 1024 * 1024);
  assert(data);
  for (size_t i=0;i<2*1024*1024;i+=4096) data[i] = 42;
  assert(abc_retention_snapshot_v1(allocated, 16) == 0);
  assert(allocated[13]+allocated[10] >= before[13]+before[10]+2*1024*1024);
  free(data);
  assert(abc_retention_snapshot_v1(released, 16) == 0);
  assert(released[13]+released[10] < allocated[13]+allocated[10]);
  return 0;
}
''')
        executable = self.directory / 'direct-contract'
        subprocess.run(['cc', '-std=c11', '-O0', '-Wall', '-Wextra', '-Werror',
                        str(source), str(self.available), '-o', str(executable)],
                       check=True, capture_output=True, timeout=30)
        result = subprocess.run([str(executable)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unsupported_slots_are_sentinels_not_zeros(self):
        snapshot = self.load(self.unsupported)
        words = (ctypes.c_uint64 * 16)()
        self.assertEqual(snapshot(words, 16), 1)
        self.assertEqual(words[1], 1)
        self.assertEqual(list(words)[6:], [(1 << 64) - 1] * 10)

    def test_dart_available_and_unsupported_mapping(self):
        dart = os.environ.get('ABC_CONTRACT_DART') or shutil.which('dart')
        if not dart:
            self.skipTest('Provide ABC_CONTRACT_DART for the Dart wire contract')
        for path, expected in ((self.available, 'available'),
                               (self.unsupported, 'unsupported')):
            result = subprocess.run([
                dart,
                'tool/perf/native_retention_probe_contract.dart', str(path), expected,
                str(self.directory / (path.stem + '.jsonl')),
            ], cwd=ROOT, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['status'], 'contract-passed')


if __name__ == '__main__':
    unittest.main()
