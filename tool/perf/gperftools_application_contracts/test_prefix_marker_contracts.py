#!/usr/bin/env python3
"""Offline native prefix compatibility contracts; no SDK or actual profiler.

Compile and load the real quiet helper into an inert C target. A clearly fake
provider forwards allocation to glibc and exposes only synthetic running/Stop
state. Dump exits with failure if ever reached. The original launcher and every
real helper identity/environment/provider check are exercised. This is not
official-profiler or application-entry evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
CONTRACTS = HERE
ADAPTER = HERE / 'quiet_dump_linux.c'
PREFIXES = ('LD_', 'HEAP', 'TCMALLOC', 'CPUPROFILE', 'MALLOC')


def clean_environment():
    return {k: v for k, v in os.environ.items()
            if not k.startswith(PREFIXES) and k != 'ABC_STACK_OUTPUT'}


def run(argv, *, env=None):
    return subprocess.run(argv, env=clean_environment() if env is None else env,
                          check=True, capture_output=True, text=True, timeout=15)


def compile_c(output, sources, config=None, extra=()):
    args = [shutil.which('cc') or 'cc', '-std=c11', '-O2', '-Wall', '-Wextra',
            '-Werror', '-I', str(CONTRACTS)]
    if config:
        args += [f'-DABC_SEALED_CONFIG={json.dumps(str(config))}', '-DABC_OFFLINE_TESTING=1']
    run(args + [str(p) for p in sources] + list(extra) + ['-o', str(output)])


def identity(path, *, mismatch=False):
    stat = path.stat()
    sha = hashlib.sha256(path.read_bytes()).hexdigest()
    if mismatch:
        sha = ('0' if sha[0] != '0' else '1') + sha[1:]
    return '{%s,%dULL,%dULL,%dULL,%s}' % (
        json.dumps(str(path)), stat.st_dev, stat.st_ino, stat.st_size, json.dumps(sha))


def seal(path, target, library, arms, mismatch=None):
    data = 'static const struct abc_file_identity abc_sealed_target=%s;\n' % identity(target, mismatch=mismatch == 'target')
    data += 'static const struct abc_file_identity abc_sealed_library=%s;\n' % identity(library, mismatch=mismatch == 'library')
    data += 'static const struct abc_arm_identity abc_sealed_arms[2]={\n'
    for name, directory in arms.items():
        stat = directory.stat()
        inode = stat.st_ino + (1 if mismatch == 'output' else 0)
        data += '{%s,%s,%dULL,%dULL},\n' % (json.dumps(name), json.dumps(str(directory)), stat.st_dev, inode)
    path.write_text(data + '};\n')


FAKE_PROVIDER = r'''
#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t,size_t);
extern void *__libc_realloc(void *,size_t);
extern void __libc_free(void *);
void *malloc(size_t n) {return __libc_malloc(n);}
void *calloc(size_t n,size_t s) {return __libc_calloc(n,s);}
void *realloc(void *p,size_t n) {return __libc_realloc(p,n);}
void free(void *p) {__libc_free(p);}
static int running=1,stops;
void HeapProfilerDump(const char *reason) {(void)reason;_exit(97);}
void HeapProfilerStop(void) {++stops;running=0;}
int IsHeapProfilerRunning(void) {return running;}
int abc_fake_stops(void) {return stops;}
/* Test input construction only. The production comparison never writes env. */
__attribute__((constructor)) static void test_input(void) {
    char *prefix=getenv("HEAPPROFILE");
    const char *mode=getenv("ABC_OFFLINE_CASE");
    if(!prefix || !mode) _exit(98);
    size_t size=strlen(prefix);
    if(!strcmp(mode,"original")) return;
    if(!strcmp(mode,"missing")) {(void)unsetenv("HEAPPROFILE");return;}
    if(!strcmp(mode,"empty")) {prefix[0]=0;return;}
    if(!strcmp(mode,"different-path")) {prefix[size-1]^=1;return;}
    if(!strcmp(mode,"nonfirst-marker")) {prefix[1]=(char)((unsigned char)prefix[1]|0x80u);return;}
    if(!strcmp(mode,"truncated")) {prefix[size-1]=0;return;}
    if(!strcmp(mode,"multibit")) {prefix[0]=(char)((unsigned char)prefix[0]|0xc0u);return;}
    prefix[0]=(char)((unsigned char)prefix[0]|0x80u);
    if(!strcmp(mode,"marked-different-tail")) prefix[size-1]^=1;
    else if(!strcmp(mode,"bad-flag")) (void)setenv("HEAP_PROFILE_TIME_INTERVAL","1",1);
    else if(!strcmp(mode,"signal")) (void)setenv("HEAPPROFILESIGNAL","12",1);
    else if(!strcmp(mode,"bad-preload")) (void)setenv("LD_PRELOAD","/not/the/sealed/provider",1);
    else if(!strcmp(mode,"bad-arm")) (void)setenv("ABC_STACK_ARM","other-arm",1);
    else if(strcmp(mode,"marked")) _exit(99);
}
'''

INERT_TARGET = r'''
#define _GNU_SOURCE
#include "quiet_dump_bridge.h"
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    const char *path=getenv("ABC_OFFLINE_HELPER");
    if(!path) return 2;
    void *helper=dlopen(path,RTLD_NOW|RTLD_LOCAL);
    if(!helper) {fprintf(stderr,"%s\n",dlerror());return 3;}
    int (*initialize)(void)=(int (*)(void))dlsym(helper,"abc_quiet_initialize");
    int (*stop)(void)=(int (*)(void))dlsym(helper,"abc_quiet_stop");
    const struct abc_quiet_metadata *(*metadata)(void)=
        (const struct abc_quiet_metadata *(*)(void))dlsym(helper,"abc_quiet_metadata");
    int (*fake_stops)(void)=(int (*)(void))dlsym(RTLD_DEFAULT,"abc_fake_stops");
    if(!initialize || !stop || !metadata || !fake_stops) return 4;
    const char *before=getenv("HEAPPROFILE");char saved[PATH_MAX];
    int existed=before!=NULL,first=before?(unsigned char)before[0]:-1;
    size_t length=before?strlen(before):0;
    if(length>=sizeof saved) return 5;
    if(before) memcpy(saved,before,length+1);
    int result=initialize();
    const struct abc_quiet_metadata *m=metadata();
    unsigned held=m->observer_held_fds;
    const char *after=getenv("HEAPPROFILE");
    int unchanged=existed ? after && strlen(after)==length && !memcmp(saved,after,length+1) : after==NULL;
    int cleared=after==NULL;
    int stopped=stop(),again=stop();
    printf("{\"offline\":true,\"realProfilerInvoked\":false,\"init\":%d,"
           "\"first\":%d,\"envUnchanged\":%d,\"envCleared\":%d,"
           "\"initialized\":%d,\"failure\":%d,\"heldBeforeStop\":%u,"
           "\"heldAfterStop\":%u,\"closed\":%u,\"closeAttempts\":%u,"
           "\"dumps\":%u,\"stopCalls\":%u,\"stopVerified\":%d,"
           "\"stop\":%d,\"stopAgain\":%d,\"fakeStops\":%d}\n",
           result,first,unchanged,cleared,m->initialized,m->failure,held,
           m->observer_held_fds,m->observer_closed_fds,m->observer_fd_close_attempts,
           m->dump_count,m->stop_calls,m->stop_verified,stopped,again,fake_stops());
    return 0;
}
'''

READ_ONLY_COMPARER = r'''
#define _GNU_SOURCE
#include "ADAPTER_PATH"
int main(void) {
    const char expected[]="/fixed/sealed/output/heap";
    char value[sizeof expected],saved[sizeof expected];
    unsigned accepted=0,cases=0;
    for(unsigned first=0;first<256;first++) {
        memcpy(value,expected,sizeof value);value[0]=(char)first;
        if(setenv("HEAPPROFILE",value,1)) return 4;
        const char *observed=getenv("HEAPPROFILE");
        size_t bytes=strlen(observed)+1;memcpy(saved,observed,bytes);
        int result=profile_prefix_matches(observed,expected);
        if(result!=(first=='/' || first==('/'|0x80u)) ||
           memcmp(saved,getenv("HEAPPROFILE"),bytes)) return 1;
        accepted+=(unsigned)result;++cases;
    }
    for(size_t i=1;i<sizeof expected-1;i++) {
        memcpy(value,expected,sizeof value);value[0]=(char)('/'|0x80u);value[i]^=1;
        if(setenv("HEAPPROFILE",value,1)) return 4;
        memcpy(saved,getenv("HEAPPROFILE"),sizeof saved);
        if(profile_prefix_matches(getenv("HEAPPROFILE"),expected) ||
           memcmp(saved,getenv("HEAPPROFILE"),sizeof saved)) return 2;
        ++cases;
    }
    if(profile_prefix_matches(NULL,expected) || profile_prefix_matches("",expected) ||
       profile_prefix_matches(expected,NULL) || profile_prefix_matches(expected,"relative")) return 3;
    printf("{\"acceptedFirstBytes\":%u,\"cases\":%u,\"environmentUnchanged\":true}\n",accepted,cases);
    return 0;
}
'''


class PrefixMarkerContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='abc-prefix-offline-')
        cls.root = Path(cls.tmp.name)
        target_source, provider_source = cls.root / 'target.c', cls.root / 'fake-provider.c'
        target_source.write_text(INERT_TARGET)
        provider_source.write_text(FAKE_PROVIDER)
        cls.target, cls.provider = cls.root / 'inert-target', cls.root / 'fake-provider.so'
        compile_c(cls.target, [target_source], extra=['-ldl'])
        compile_c(cls.provider, [provider_source], extra=['-fPIC', '-shared', '-Wl,-z,defs'])
        cls.sequence = 0

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def case(self, mode, mismatch=None):
        type(self).sequence += 1
        root = self.root / str(self.sequence)
        root.mkdir()
        arms = {name: root / name for name in ('probe-only', 'product-with-ownership')}
        for directory in arms.values():
            directory.mkdir(mode=0o700)
        config, helper_config = root / 'launcher-seal.h', root / 'helper-seal.h'
        seal(config, self.target, self.provider, arms)
        seal(helper_config, self.target, self.provider, arms, mismatch)
        launcher, helper = root / 'launcher', root / 'quiet.so'
        compile_c(launcher, [CONTRACTS / 'target_launcher.c'], config)
        compile_c(helper, [ADAPTER, CONTRACTS / 'quiet_dump_bridge.c'], helper_config,
                  ['-fPIC', '-shared', '-ldl', '-Wl,-z,defs'])
        env = clean_environment()
        env.update(ABC_STACK_ARM='probe-only', ABC_OFFLINE_HELPER=str(helper), ABC_OFFLINE_CASE=mode)
        result = run([str(launcher)], env=env)
        self.assertEqual(result.stderr, '')
        value = json.loads(result.stdout)
        self.assertTrue(value['offline'])
        self.assertFalse(value['realProfilerInvoked'])
        self.assertEqual(value['dumps'], 0)
        token = (arms['probe-only'] / 'launch.once').read_text()
        self.assertTrue(token.startswith('ABC_LAUNCH_ONCE_V1 '))
        self.assertFalse(any(p.suffix == '.heap' for p in root.rglob('*')))
        return value

    def assert_success(self, value):
        self.assertEqual((value['init'], value['initialized'], value['failure']), (0, 1, 0))
        self.assertEqual((value['heldBeforeStop'], value['heldAfterStop'], value['closed'], value['closeAttempts']), (3, 0, 3, 3))
        self.assertEqual((value['stop'], value['stopAgain'], value['stopCalls'], value['fakeStops'], value['stopVerified']), (0, 0, 1, 1, 1))
        # Existing initializer cleanup still removes inheritance variables.
        self.assertEqual(value['envCleared'], 1)

    def assert_rejected(self, value, closed=0):
        self.assertEqual((value['init'], value['initialized'], value['failure']), (1, 0, 1))
        self.assertEqual((value['heldBeforeStop'], value['heldAfterStop'], value['closed'], value['closeAttempts']), (0, 0, closed, closed))
        self.assertEqual((value['stopCalls'], value['fakeStops'], value['stopVerified']), (0, 0, 0))
        self.assertEqual(value['envUnchanged'], 1)

    def test_original_prefix_passes_real_helper(self):
        value = self.case('original')
        self.assertEqual(value['first'], ord('/'))
        self.assert_success(value)

    def test_official_first_byte_marker_passes_real_helper(self):
        value = self.case('marked')
        self.assertEqual(value['first'], ord('/') | 128)
        self.assert_success(value)

    def test_different_path_is_rejected_without_environment_rewrite(self):
        self.assert_rejected(self.case('different-path'))

    def test_nonfirst_byte_marker_is_rejected_without_environment_rewrite(self):
        self.assert_rejected(self.case('nonfirst-marker'))

    def test_truncated_prefix_is_rejected_without_environment_rewrite(self):
        self.assert_rejected(self.case('truncated'))

    def test_multiple_first_byte_bits_are_rejected_without_environment_rewrite(self):
        self.assert_rejected(self.case('multibit'))

    def test_marked_prefix_with_changed_tail_is_rejected(self):
        self.assert_rejected(self.case('marked-different-tail'))

    def test_missing_and_empty_prefix_are_rejected(self):
        for mode in ['missing', 'empty']:
            with self.subTest(mode=mode):
                self.assert_rejected(self.case(mode))

    def test_valid_marker_cannot_bypass_sealed_target_identity(self):
        self.assert_rejected(self.case('marked', 'target'))

    def test_valid_marker_cannot_bypass_sealed_library_identity(self):
        self.assert_rejected(self.case('marked', 'library'), closed=1)

    def test_valid_marker_cannot_bypass_sealed_output_identity(self):
        self.assert_rejected(self.case('marked', 'output'), closed=2)

    def test_valid_marker_cannot_bypass_zero_flag_or_absent_signal_checks(self):
        for mode in ['bad-flag', 'signal']:
            with self.subTest(mode=mode):
                self.assert_rejected(self.case(mode))

    def test_valid_marker_cannot_bypass_exact_preload_or_arm(self):
        for mode in ['bad-preload', 'bad-arm']:
            with self.subTest(mode=mode):
                self.assert_rejected(self.case(mode))

    def test_native_comparer_accepts_exactly_two_first_bytes_and_never_mutates(self):
        root = self.root / 'comparer'
        root.mkdir()
        arms = {name: root / name for name in ('probe-only', 'product-with-ownership')}
        for directory in arms.values():
            directory.mkdir(mode=0o700)
        config = root / 'seal.h'
        seal(config, self.target, self.provider, arms)
        source, binary = root / 'comparer.c', root / 'comparer'
        source.write_text(READ_ONLY_COMPARER.replace('ADAPTER_PATH', str(ADAPTER)))
        compile_c(binary, [source, CONTRACTS / 'quiet_dump_bridge.c'], config, ['-ldl'])
        value = json.loads(run([str(binary)]).stdout)
        self.assertEqual(value['acceptedFirstBytes'], 2)
        self.assertGreater(value['cases'], 256)
        self.assertTrue(value['environmentUnchanged'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--contracts', type=Path, default=CONTRACTS)
    parser.add_argument('--adapter', type=Path, default=ADAPTER)
    args, remaining = parser.parse_known_args()
    CONTRACTS, ADAPTER = args.contracts.resolve(), args.adapter.resolve()
    unittest.main(argv=[__file__, *remaining], verbosity=2)
