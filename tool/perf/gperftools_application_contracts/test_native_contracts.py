#!/usr/bin/env python3
"""Offline C contract tests. Never executes Flutter, a WLD, or a profiler."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
PREFIXES = ('LD_', 'HEAP', 'TCMALLOC', 'CPUPROFILE', 'MALLOC')


def clean_environment(source=None):
    return {k: v for k, v in dict(os.environ if source is None else source).items()
            if not k.startswith(PREFIXES) and k != 'ABC_STACK_OUTPUT'}


def run(command, **kwargs):
    return subprocess.run(command, env=clean_environment(), check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=15, **kwargs)


def compile_c(output, sources, config=None, extra=()):
    args = [shutil.which('cc') or 'cc', '-std=c11', '-O2', '-Wall', '-Wextra',
            '-Werror', '-I', str(ROOT)]
    if config:
        args += [f'-DABC_SEALED_CONFIG={json.dumps(str(config))}', '-DABC_OFFLINE_TESTING=1']
    run(args + [str(p) for p in sources] + list(extra) + ['-o', str(output)])


def file_identity(path):
    stat = path.stat()
    return '{%s,%dULL,%dULL,%dULL,%s}' % (
        json.dumps(str(path)), stat.st_dev, stat.st_ino, stat.st_size,
        json.dumps(hashlib.sha256(path.read_bytes()).hexdigest()))


def seal(path, target, library, arms):
    data = 'static const struct abc_file_identity abc_sealed_target=%s;\n' % file_identity(target)
    data += 'static const struct abc_file_identity abc_sealed_library=%s;\n' % file_identity(library)
    data += 'static const struct abc_arm_identity abc_sealed_arms[2]={\n'
    for name, directory in arms.items():
        stat = directory.stat()
        data += '{%s,%s,%dULL,%dULL},\n' % (json.dumps(name), json.dumps(str(directory)), stat.st_dev, stat.st_ino)
    path.write_text(data + '};\n')


TARGET_SOURCE = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <unistd.h>
extern char **environ;
static void hex(const char *s) {for(;*s;s++)printf("%02x",(unsigned char)*s);puts("");}
int main(int argc,char **argv) {
    printf("PID %ld\n",(long)getpid());
    for(int i=0;i<argc;i++){printf("ARG ");hex(argv[i]);}
    for(char **p=environ;*p;p++){printf("ENV ");hex(*p);}
    char cwd[4096];if(!getcwd(cwd,sizeof cwd))return 2;
    printf("CWD ");hex(cwd);return 0;
}
'''
DSO_SOURCE = r'''
#include <stdlib.h>
__attribute__((constructor)) static void loaded(void) {setenv("ABC_OFFLINE_DSO_LOADED","1",1);}
int abc_inert_library(void) {return 42;}
'''


class NativeCoreContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='abc-native-core-')
        cls.binary = Path(cls.tmp.name) / 'core'
        compile_c(cls.binary, [ROOT/'quiet_dump_bridge.c', ROOT/'native_contracts_harness.c'])

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def case(self, name):
        result = json.loads(run([str(self.binary), name]).stdout)
        self.assertTrue(result['offline'])
        self.assertFalse(result['realProfilerInvoked'])
        self.assertLessEqual(result['dumps'], 2)
        self.assertLessEqual(result['stopCalls'], 1)
        return result

    def test_two_synchronous_cuts_have_ordered_native_times_and_dart_clock(self):
        r = self.case('success')
        self.assertEqual((r['a'], r['b'], r['failure'], r['dumps'], r['slots']), (0, 0, 0, 2, 2))
        self.assertEqual((r['maps'], r['publishes'], r['acks']), (4, 2, 2))
        self.assertEqual((r['stopCalls'], r['stopVerified'], r['stopAgain']), (1, 1, 0))
        self.assertGreaterEqual(r['observerBytes'], 2*1024*1024)
        events = r['events'].split(',')
        self.assertLess(events.index('gauge0'), events.index('q0.released-quiet-end'))
        self.assertLess(events.index('gauge7'), events.index('q7.released-quiet-end'))
        for cut, dart in zip(r['cuts'], [1234, 5678]):
            self.assertEqual(cut['gaugeDartUs'], dart)
            self.assertEqual(cut['accepted'], 1)
            times = [cut[k] for k in ['entryNs', 'dumpStartNs', 'dumpEndNs', 'ackEndNs', 'exitNs']]
            self.assertEqual(times, sorted(times))
            self.assertGreater(cut['beforeSize'], 0)

    def test_bad_order_repeat_third_and_post_stop_are_poisoned(self):
        for name, dumps in [('wrong-order', 0), ('wrong-cycle', 0), ('repeat', 1), ('third', 2), ('stop-before-q7', 1)]:
            with self.subTest(name=name):
                r = self.case(name)
                self.assertNotEqual(r['failure'], 0)
                self.assertEqual(r['dumps'], dumps)
                self.assertEqual((r['stopCalls'], r['stopVerified']), (1, 1))

    def test_failures_stop_and_preserve_partial_cut_metadata(self):
        for name, expected, dumps in [('maps-overflow', 5, 0), ('maps-read-error', 5, 0),
                ('publish-failure', 6, 1), ('ack-failure', 7, 1), ('late-ack', 7, 1),
                ('slow-dump', 8, 1), ('provider-changed', 2, 1), ('zero-clock', 10, 0)]:
            with self.subTest(name=name):
                r = self.case(name)
                self.assertEqual((r['failure'], r['dumps'], r['slots']), (expected, dumps, 1))
                self.assertEqual(r['stopCalls'], 1)
                self.assertEqual(r['cuts'][0]['accepted'], 0)

    def test_wrong_provider_never_calls_unknown_stop_or_dump(self):
        r = self.case('wrong-provider')
        self.assertEqual((r['init'], r['dumps'], r['stopCalls']), (2, 0, 0))

    def test_abnormal_finally_stops_without_any_dump(self):
        r = self.case('failure-finally')
        self.assertEqual((r['dumps'], r['stopCalls'], r['stopVerified']), (0, 1, 1))

    def test_not_running_is_not_started(self):
        r = self.case('not-running')
        self.assertEqual((r['init'], r['dumps']), (3, 0))

    def test_cleanup_failure_retains_primary_error_and_evidence(self):
        r = self.case('ack-and-stop-failure')
        self.assertEqual((r['failure'], r['cleanupFailure'], r['stopVerified'], r['stopCalls']), (7, 9, 0, 1))
        self.assertEqual((r['stop'], r['stopAgain']), (9, 9))
        self.assertGreater(r['cuts'][0]['dumpEndNs'], 0)


class NativeLauncherContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root_tmp = tempfile.TemporaryDirectory(prefix='abc-native-build-')
        cls.build = Path(cls.root_tmp.name)
        cls.target = cls.build/'inert-target'
        cls.library = cls.build/'inert-library.so'
        target_source, library_source = cls.build/'target.c', cls.build/'library.c'
        target_source.write_text(TARGET_SOURCE)
        library_source.write_text(DSO_SOURCE)
        compile_c(cls.target, [target_source])
        compile_c(cls.library, [library_source], extra=['-D_POSIX_C_SOURCE=200809L', '-shared', '-fPIC'])

    @classmethod
    def tearDownClass(cls):
        cls.root_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='abc-native-launch-')
        self.root = Path(self.tmp.name)
        self.arms = {name: self.root/name for name in ('probe-only', 'product-with-ownership')}
        for path in self.arms.values():
            path.mkdir(mode=0o700)
        self.config, self.launcher = self.root/'seal.h', self.root/'launcher'
        seal(self.config, self.target, self.library, self.arms)

    def tearDown(self):
        self.tmp.cleanup()

    def build_launcher(self):
        compile_c(self.launcher, [ROOT/'target_launcher.c'], self.config)

    def launch(self, arm='probe-only', extra_env=None):
        env = clean_environment()
        env.update({'ABC_STACK_ARM': arm, 'DISPLAY': ':123', 'FLUTTER_ENGINE_SWITCHES': '2',
                    'FLUTTER_ENGINE_SWITCH_1': '--trace-startup', 'FLUTTER_ENGINE_SWITCH_2': '--enable-software-rendering',
                    'ABC_ORIGINAL_WORKLOAD': 'eight cycles, same input'})
        env.update(extra_env or {})
        argv = [str(self.launcher), '--device-vmservice-port=1234', 'a b', 'line\nbreak', '--']
        p = subprocess.Popen(argv, cwd=self.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        stdout, stderr = p.communicate(timeout=5)
        return p, stdout, stderr, argv

    @staticmethod
    def decode(stdout):
        out = {'argv': [], 'env': {}}
        for line in stdout.splitlines():
            key, value = line.split(' ', 1)
            if key == 'PID': out['pid'] = int(value)
            elif key == 'ARG': out['argv'].append(bytes.fromhex(value).decode())
            elif key == 'ENV':
                name, data = bytes.fromhex(value).decode().split('=', 1)
                out['env'][name] = data
            elif key == 'CWD': out['cwd'] = bytes.fromhex(value).decode()
        return out

    def test_exact_argv_engine_environment_pid_target_and_library(self):
        self.build_launcher()
        p, stdout, stderr, argv = self.launch(extra_env={'HEAPPROFILESIGNAL': '12', 'HEAP_PROFILE_TIME_INTERVAL': '2', 'TCMALLOC_SAMPLE_PARAMETER': '99'})
        self.assertEqual((p.returncode, stderr), (0, ''))
        r = self.decode(stdout)
        self.assertEqual((r['pid'], r['argv'], r['cwd']), (p.pid, argv, str(self.root)))
        self.assertEqual(r['env']['LD_PRELOAD'], str(self.library))
        self.assertEqual(r['env']['HEAPPROFILE'], str(self.arms['probe-only']/'heap'))
        self.assertEqual(r['env']['ABC_OFFLINE_DSO_LOADED'], '1')
        self.assertNotIn('HEAPPROFILESIGNAL', r['env'])
        self.assertNotIn('TCMALLOC_SAMPLE_PARAMETER', r['env'])
        self.assertEqual(r['env']['FLUTTER_ENGINE_SWITCH_2'], '--enable-software-rendering')
        self.assertEqual(r['env']['ABC_ORIGINAL_WORKLOAD'], 'eight cycles, same input')
        for key in ['ALLOCATION_INTERVAL', 'DEALLOCATION_INTERVAL', 'INUSE_INTERVAL', 'TIME_INTERVAL', 'CLEANUP', 'MMAP', 'ONLY_MMAP', 'MMAP_LOG']:
            self.assertEqual(r['env']['HEAP_PROFILE_'+key], '0')

    def test_three_internal_attempts_exec_only_once_with_same_launcher_bytes(self):
        self.build_launcher()
        digest = hashlib.sha256(self.launcher.read_bytes()).hexdigest()
        attempts = [self.launch() for _ in range(3)]
        self.assertEqual([a[0].returncode for a in attempts], [0, 78, 78])
        self.assertEqual(sum(bool(a[1]) for a in attempts), 1)
        p, stdout, _, _ = self.launch('product-with-ownership')
        self.assertEqual(p.returncode, 0)
        self.assertTrue(stdout)
        self.assertEqual(hashlib.sha256(self.launcher.read_bytes()).hexdigest(), digest)

    def test_launcher_requires_clean_entry_before_target_preload(self):
        self.build_launcher()
        # This is an empty loader option, not an injected library. The entry
        # contract rejects even it; safe tests never preload a driver/launcher.
        p, stdout, stderr, _ = self.launch(extra_env={'LD_PRELOAD': ''})
        self.assertEqual((p.returncode, stdout), (78, ''))
        self.assertIn('launcher-not-clean', stderr)
        self.assertFalse((self.arms['probe-only']/'launch.once').exists())

    def test_existing_and_symlink_tokens_never_exec_or_modify_evidence(self):
        self.build_launcher()
        token = self.arms['probe-only']/'launch.once'
        token.write_bytes(b'previous failed attempt\n')
        p, stdout, stderr, _ = self.launch()
        self.assertEqual((p.returncode, stdout), (78, ''))
        self.assertIn('once-token', stderr)
        self.assertEqual(token.read_bytes(), b'previous failed attempt\n')
        victim = self.root/'victim';victim.write_bytes(b'keep')
        (self.arms['product-with-ownership']/'launch.once').symlink_to(victim)
        self.assertEqual(self.launch('product-with-ownership')[0].returncode, 78)
        self.assertEqual(victim.read_bytes(), b'keep')

    def test_exec_failure_consumes_token_and_retains_evidence(self):
        invalid = self.root/'invalid-elf'
        invalid.write_bytes(b'\x7fELFdeliberately incomplete inert fixture')
        invalid.chmod(0o700)
        seal(self.config, invalid, self.library, self.arms)
        self.build_launcher()
        p, stdout, stderr, _ = self.launch()
        self.assertEqual((p.returncode, stdout), (78, ''))
        self.assertIn('exec-failed-token-retained', stderr)
        token = self.arms['probe-only']/'launch.once'
        evidence = token.read_bytes()
        self.assertIn(str(p.pid).encode(), evidence)
        p, stdout, stderr, _ = self.launch()
        self.assertEqual((p.returncode, stdout), (78, ''))
        self.assertIn('once-token', stderr)
        self.assertEqual(token.read_bytes(), evidence)

    def test_target_byte_tampering_and_library_byte_tampering_fail(self):
        for which in ('target', 'library'):
            with self.subTest(which=which):
                target, library = self.root/'target-copy', self.root/'library-copy'
                shutil.copy2(self.target, target);shutil.copy2(self.library, library)
                seal(self.config, target, library, self.arms)
                self.build_launcher()
                altered = target if which == 'target' else library
                data = bytearray(altered.read_bytes());data[-1] ^= 1;altered.write_bytes(data)
                p, stdout, stderr, _ = self.launch()
                self.assertEqual((p.returncode, stdout), (78, ''))
                self.assertIn(which+'-identity', stderr)
                self.assertFalse((self.arms['probe-only']/'launch.once').exists())

    def test_symlink_target_library_and_output_rejected(self):
        for which in ('target', 'library', 'output'):
            with self.subTest(which=which):
                link = self.root/('linked-'+which)
                link.symlink_to({'target':self.target,'library':self.library,'output':self.arms['probe-only']}[which])
                arms = dict(self.arms)
                if which=='output': arms['probe-only']=link
                seal(self.config, link if which=='target' else self.target,
                     link if which=='library' else self.library, arms)
                self.build_launcher()
                p, stdout, stderr, _ = self.launch()
                self.assertEqual((p.returncode, stdout), (78, ''))
                self.assertIn(which+'-identity', stderr)

    def test_output_replaced_inode_and_wrong_arm_rejected(self):
        self.build_launcher()
        self.assertEqual(self.launch('arbitrary')[0].returncode, 78)
        output = self.arms['probe-only'];output.rename(self.root/'original-output');output.mkdir(mode=0o700)
        p, stdout, stderr, _ = self.launch()
        self.assertEqual((p.returncode, stdout), (78, ''))
        self.assertIn('output-identity', stderr)

    def test_compiler_driver_and_analyst_environment_is_clean(self):
        dirty = dict(os.environ, LD_PRELOAD='/wrong', LD_AUDIT='/wrong', HEAPPROFILE='/wrong',
                     HEAPPROFILESIGNAL='12', CPUPROFILE='/wrong', TCMALLOC_STATS='1', MALLOC_TRACE='/wrong')
        env = clean_environment(dirty)
        for role in ['compiler', 'driver', 'analyst']:
            self.assertFalse(any(key.startswith(PREFIXES) for key in env), role)

    def test_linux_adapter_receipt_ack_and_no_overwrite(self):
        io = self.root/'io'
        compile_c(io, [ROOT/'native_io_harness.c', ROOT/'quiet_dump_bridge.c'], self.config, ['-ldl'])
        out = self.arms['probe-only']
        r = json.loads(run([str(io), str(out), 'ack']).stdout)
        self.assertEqual((r['first'], r['ack']), (0, 0))
        self.assertEqual((out/'q0.before.maps').read_bytes(), b'known synthetic maps bytes\n')
        receipt = (out/'q0.receipt').read_bytes()
        self.assertRegex(receipt, rb'^ABC_HEAP_RECEIPT_V1 0 0 [0-9]+ 100 200 27 27 heap\.0001\.heap\n$')
        r = json.loads(run([str(io), str(out), 'duplicate']).stdout)
        self.assertEqual((r['first'], r['second']), (-1, -1))
        self.assertEqual((out/'q0.receipt').read_bytes(), receipt)

    def test_linux_helper_builds_as_dso_without_loading_any_profiler(self):
        helper=self.root/'quiet_dump_bridge.so'
        compile_c(helper, [ROOT/'quiet_dump_linux.c', ROOT/'quiet_dump_bridge.c'], self.config,
                  ['-shared','-fPIC','-ldl'])
        self.assertEqual(helper.read_bytes()[:4], b'\x7fELF')

    def test_linux_adapter_bad_ack_and_symlink_map_preserve_files(self):
        io = self.root/'io'
        compile_c(io, [ROOT/'native_io_harness.c', ROOT/'quiet_dump_bridge.c'], self.config, ['-ldl'])
        out = self.arms['probe-only']
        r = json.loads(run([str(io), str(out), 'bad-ack']).stdout)
        self.assertEqual((r['first'], r['ack']), (0, -1))
        other = self.arms['product-with-ownership']
        victim=self.root/'victim';victim.write_bytes(b'keep')
        (other/'q0.before.maps').symlink_to(victim)
        r = json.loads(run([str(io), str(other), 'publish']).stdout)
        self.assertEqual(r['first'], -1)
        self.assertEqual(victim.read_bytes(), b'keep')

    def test_linux_adapter_symlink_fifo_oversize_and_missing_ack_rejected(self):
        io = self.root/'io'
        compile_c(io, [ROOT/'native_io_harness.c', ROOT/'quiet_dump_bridge.c'], self.config, ['-ldl'])
        for kind in ['symlink', 'fifo', 'oversize', 'missing']:
            with self.subTest(kind=kind):
                out=self.root/kind;out.mkdir(mode=0o700)
                ack=out/'q0.ack'
                if kind=='symlink':
                    victim=out/'victim';victim.write_bytes(b'ABC_HEAP_ACK_V1 0 0 OK\n');ack.symlink_to(victim)
                elif kind=='fifo': os.mkfifo(ack)
                elif kind=='oversize': ack.write_bytes(b'x'*513)
                r=json.loads(run([str(io), str(out), 'external-ack']).stdout)
                self.assertEqual((r['first'], r['ack']), (0, -1))

    def test_linux_adapter_stop_closes_three_observer_fds_once(self):
        io=self.root/'io'
        compile_c(io, [ROOT/'native_io_harness.c', ROOT/'quiet_dump_bridge.c'], self.config, ['-ldl'])
        r=json.loads(run([str(io), str(self.arms['probe-only']), 'cleanup-success']).stdout)
        self.assertEqual((r['opened'], r['heldBefore'], r['heldAfter'], r['closed'], r['closeAttempts']), (0,3,0,3,3))
        self.assertEqual((r['stop'], r['again'], r['closeError'], r['mockStopCalls']), (0,0,0,1))
        self.assertEqual((r['reinit'], r['sentinelAlive']), (1,1))

    def test_linux_adapter_partial_init_closes_fd_and_prevents_reinitialization(self):
        library=self.root/'library-copy';shutil.copy2(self.library, library)
        seal(self.config, self.target, library, self.arms)
        io=self.root/'io'
        compile_c(io, [ROOT/'native_io_harness.c', ROOT/'quiet_dump_bridge.c'], self.config, ['-ldl'])
        library.write_bytes(library.read_bytes()+b'changed')
        r=json.loads(run([str(io), str(self.arms['probe-only']), 'cleanup-partial']).stdout)
        self.assertEqual((r['opened'], r['heldBefore'], r['heldAfter'], r['closed'], r['closeAttempts']), (1,1,0,1,1))
        self.assertEqual((r['mockStopCalls'],r['reinit'],r['sentinelAlive']), (0,1,1))

    def test_linux_adapter_failed_fd_cleanup_is_explicit(self):
        io=self.root/'io'
        compile_c(io, [ROOT/'native_io_harness.c', ROOT/'quiet_dump_bridge.c'], self.config, ['-ldl'])
        r=json.loads(run([str(io), str(self.arms['probe-only']), 'cleanup-close-error']).stdout)
        self.assertEqual((r['heldAfter'], r['closed'], r['closeAttempts'], r['mockStopCalls']), (0,2,3,1))
        self.assertGreater(r['closeError'],0)
        self.assertEqual((r['stop'],r['again'],r['sentinelAlive']), (6,6,1))


if __name__ == '__main__':
    unittest.main(verbosity=2)
