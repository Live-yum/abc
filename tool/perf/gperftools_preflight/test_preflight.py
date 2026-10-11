"""Offline hand-authored positive/negative contracts; no profiler, APT or SDK."""
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest

from profile_contract import (ContractError, CUT_IDS, SITE_LIFETIMES, expected_sites,
                              parse_profile, validate_profile, validate_official, read_fixture)
from run_preflight import (Runner, MAX_PROFILE, check_trace_caps, check_official_diagnostics,
    target_environment, validate_policy, parse_mirror_list, validate_download_log,
    validate_source_stanza, validate_index_targets, validate_redirect_overrides,
    protected_identity, fixed_path_identity, validate_keyring_package, bind_archive,
    deb_fields, MIRROR_URI, MIRROR_PATH, SOURCE_PATH, KEYRING_PATH, PACKAGE_VERSION,
    PACKAGES, PACKAGE_ARCH, PACKAGE_COMPONENT)

# Independently hand-authored integer buckets. Order matches names below.
SITES = ('abc_alloc_baseline', 'abc_alloc_pre_calloc', 'abc_alloc_q0_transient',
         'abc_alloc_baseline_grow', 'abc_alloc_zero503', 'abc_alloc_gap',
         'abc_alloc_q7_calloc', 'abc_alloc_gap_grow')
GOLDEN = (
    ((1,101,1,101),(1,219,1,219),(0,0,0,0),(0,0,0,0),(0,0,0,0),(0,0,0,0),(0,0,0,0),(0,0,0,0)),
    ((0,0,1,101),(0,0,1,219),(1,307,1,307),(1,409,1,409),(0,0,1,503),(0,0,0,0),(0,0,0,0),(0,0,0,0)),
    ((0,0,1,101),(0,0,1,219),(0,0,1,307),(1,409,1,409),(0,0,1,503),(1,601,1,601),(0,0,0,0),(0,0,0,0)),
    ((0,0,1,101),(0,0,1,219),(0,0,1,307),(0,0,1,409),(0,0,1,503),(0,0,1,601),(1,749,1,749),(1,809,1,809)),
    ((0,0,1,101),(0,0,1,219),(0,0,1,307),(0,0,1,409),(0,0,1,503),(0,0,1,601),(0,0,1,749),(0,0,1,809)),
)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.binary = Path(self.temp.name) / 'native_contract'
        self.binary.write_bytes(b'offline identity only')
        self.path = Path(self.temp.name) / 'profile.heap'
        self.symbols = {site: (0x401000+0x100*i,0x80) for i,site in enumerate(SITES)}

    def content(self, cut=1, golden=None):
        rows = GOLDEN[cut] if golden is None else golden
        total = [sum(row[i] for row in rows)+[1,13,2,39][i] for i in range(4)]
        def counts(row): return f'{row[0]}: {row[1]} [{row[2]}: {row[3]}] @'
        lines = ['heap profile: '+counts(total)+' heapprofile']
        lines += [counts(row)+f' 0x{self.symbols[site][0]+4:08x} 0x00501004' for site,row in zip(SITES,rows) if row[2]]
        lines += ['1: 13 [2: 39] @ 0x00501004', '', 'MAPPED_LIBRARIES:',
                  f'00401000-00402000 r-xp 00001000 00:00 {self.binary.stat().st_ino} {self.binary}',
                  '00501000-00502000 r-xp 00000000 00:00 123 /usr/lib/example.so']
        return '\n'.join(lines)+'\n'

    def parse(self, text=None, cut=1):
        self.path.write_text(self.content(cut) if text is None else text)
        return parse_profile(self.path)

    def official(self, profile, mode):
        i = 1 if mode == 'inuse_space' else 0
        return {'total': profile['header'][i],
                'stacks': {tuple(pc-(j>0) for j,pc in enumerate(row['stack'])): row['counters'][i] for row in profile['buckets']},
                'symbols': {start+4: site for site,(start,_) in self.symbols.items()}}

    def test_independent_five_cut_oracle(self):
        results=[]
        for i,cut in enumerate(CUT_IDS):
            profile=self.parse(cut=i)
            row=validate_profile(profile,cut,self.binary,self.symbols)
            self.assertEqual(row['authoredSites'], dict(zip(SITES,map(list,GOLDEN[i]))))
            results.append(row['authoredLiveBytes'])
            for mode in ('inuse_space','inuse_objects'):
                validate_official(self.official(profile,mode),profile,cut,self.symbols,mode)
        self.assertEqual(results,[320,716,1010,1558,0])
        self.assertEqual([sum(r[2] for r in g) for g in GOLDEN],[2,5,6,8,8])
        self.assertEqual([sum(r[3] for r in g) for g in GOLDEN],[320,1539,2140,3698,3698])

    def test_each_header_counter_checked(self):
        for index in range(4):
            text=self.content()
            header=text.splitlines()[0]
            values=[sum(row[i] for row in GOLDEN[1])+[1,13,2,39][i] for i in range(4)]
            values[index]+=1
            bad=f'heap profile: {values[0]}: {values[1]} [{values[2]}: {values[3]}] @ heapprofile'
            with self.subTest(index=index), self.assertRaises(ContractError): self.parse(text.replace(header,bad))

    def test_missing_freed_bucket_detected_despite_equal_live_totals(self):
        text=self.content()
        line=next(line for line in text.splitlines(True) if '[1: 503]' in line)
        with self.assertRaisesRegex(ContractError,'four bucket'): self.parse(text.replace(line,''))

    def test_missing_zero503_pair_cannot_rewrite_oracle(self):
        golden=list(GOLDEN[1]);golden[4]=(0,0,0,0)
        profile=self.parse(self.content(golden=golden))
        with self.assertRaisesRegex(ContractError,'per-site'): validate_profile(profile,CUT_IDS[1],self.binary,self.symbols)

    def test_false503_live_residual_rejected(self):
        golden=list(GOLDEN[1]);golden[4]=(1,503,1,503)
        profile=self.parse(self.content(golden=golden))
        with self.assertRaisesRegex(ContractError,'per-site'): validate_profile(profile,CUT_IDS[1],self.binary,self.symbols)

    def test_failed_realloc_preserves_old_live_block(self):
        golden=list(GOLDEN[1]);golden[3]=(0,0,1,409)
        profile=self.parse(self.content(golden=golden))
        with self.assertRaisesRegex(ContractError,'per-site'): validate_profile(profile,CUT_IDS[1],self.binary,self.symbols)

    def test_successful_realloc_adds_requested_cumulative_count(self):
        golden=list(GOLDEN[1]);golden[3]=(1,409,2,818)
        profile=self.parse(self.content(golden=golden))
        with self.assertRaisesRegex(ContractError,'per-site'): validate_profile(profile,CUT_IDS[1],self.binary,self.symbols)

    def test_missing_cross_first_boundary_site_fails(self):
        golden=list(GOLDEN[0]);golden[0]=(0,0,0,0)
        profile=self.parse(self.content(cut=0,golden=golden))
        with self.assertRaises(ContractError): validate_profile(profile,CUT_IDS[0],self.binary,self.symbols)

    def test_profile_truncated_map_and_bucket_fail(self):
        text=self.content()
        for bad in (text[:-1], text.replace('0x00401004','0x'),text.replace('MAPPED_LIBRARIES:',''),text+'unexpected\n'):
            with self.subTest(bad=bad[-60:]),self.assertRaises((ContractError,UnicodeError)):self.parse(bad)

    def test_unknown_stack_mapping_fails(self):
        with self.assertRaisesRegex(ContractError,'Stack PC'):self.parse(self.content().replace('0x00401004','0x00601004'))

    def test_unknown_author_stack_not_forced_to_nearest_symbol(self):
        profile=self.parse(self.content().replace('0x00401004','0x00401ff0'))
        with self.assertRaisesRegex(ContractError,'per-site'):validate_profile(profile,CUT_IDS[1],self.binary,self.symbols)

    def test_duplicate_bucket_and_negative_count_fail(self):
        text=self.content();line=text.splitlines(True)[1]
        for bad in (text.replace(line,line+line),text.replace('0: 0','-1: 0',1)):
            with self.assertRaises(ContractError):self.parse(bad)

    def test_profile_size_limit_and_extra_dump_fail(self):
        self.path.write_bytes(b'x'*MAX_PROFILE)
        with self.assertRaises(ContractError):parse_profile(self.path)
        with tempfile.TemporaryDirectory() as d:
            for i in range(6):(Path(d)/str(i)).write_bytes(b'x')
            with self.assertRaises(ContractError):check_trace_caps(d)

    def test_official_exact_integer_and_author_symbol_checks(self):
        profile=self.parse()
        raw=self.official(profile,'inuse_space')
        for mutate in ('total','symbol','missing503'):
            bad=copy.deepcopy(raw)
            if mutate=='total':bad['total']+=1
            elif mutate=='symbol':bad['symbols'][self.symbols[SITES[0]][0]+4]='??'
            else:del bad['stacks'][(self.symbols[SITES[4]][0]+4,0x501003)]
            with self.subTest(mutate=mutate),self.assertRaises(ContractError):validate_official(bad,profile,CUT_IDS[1],self.symbols,'inuse_space')

    def test_official_author_swap_cannot_hide_behind_equal_totals(self):
        profile=self.parse();raw=self.official(profile,'inuse_space')
        a=(self.symbols[SITES[2]][0]+4,0x501003);b=(self.symbols[SITES[3]][0]+4,0x501003)
        raw['stacks'][a],raw['stacks'][b]=raw['stacks'][b],raw['stacks'][a]
        with self.assertRaises(ContractError):validate_official(raw,profile,CUT_IDS[1],self.symbols,'inuse_space')

    def test_symlink_profile_rejected(self):
        self.parse();link=self.path.with_name('symlink');link.symlink_to(self.path)
        with self.assertRaises(ContractError):parse_profile(link)


class PackageTests(unittest.TestCase):
    MIRRORS=(b'http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n'
             b'https://archive.ubuntu.com/ubuntu/\tpriority:2\n'
             b'https://security.ubuntu.com/ubuntu/\tpriority:3\n')
    SOURCE=('Types: deb\nURIs: '+MIRROR_URI+'\nSuites: noble noble-updates noble-backports\n'
            'Components: main restricted universe multiverse\nSigned-By: '+KEYRING_PATH+'\n')
    def policy(self,component):
        return f'x:\n Installed: {PACKAGE_VERSION}\n Version table:\n *** {PACKAGE_VERSION} 500\n  500 {MIRROR_URI} noble/{component} amd64 Packages\n  100 /var/lib/dpkg/status\n'
    def index(self,component):
        return ('Identifier: Packages\nTarget-Of: deb\nRepo-URI: '+MIRROR_URI+'/\nRelease: noble\nSuite: noble\nComponent: '+component+
                '\nArchitecture: amd64\nTrusted: yes\nOrigin: Ubuntu\nLabel: Ubuntu\nCodename: noble\nMetaKey: '+component+
                '/binary-amd64/Packages\nFilename: /var/lib/apt/lists/test_'+component+'\nSourcesentry: '+SOURCE_PATH+':1\n')
    def download(self):
        return ''.join(f'Get:{i+1} http://azure.archive.ubuntu.com/ubuntu noble/{PACKAGE_COMPONENT[p]} amd64 {p} {PACKAGE_ARCH[p]} {PACKAGE_VERSION} [123 kB]\n' for i,p in enumerate(PACKAGES))

    def test_main_and_universe_fixed_indexes(self):
        source=validate_source_stanza(self.SOURCE);mirrors=parse_mirror_list(self.MIRRORS)
        combined=self.index('main')+'\n'+self.index('universe')
        for component in ('main','universe'):
            validate_policy(self.policy(component),mirrors=mirrors,component=component)
            validate_index_targets(combined,source,component)
        with self.assertRaises(ContractError):validate_policy(self.policy('universe'),mirrors=mirrors,component='main')
        with self.assertRaises(ContractError):validate_index_targets(self.index('main'),source,'universe')

    def test_fixed_packages_all_architecture_bound(self):
        mirrors=parse_mirror_list(self.MIRRORS)
        rows=validate_download_log(self.download(),mirrors)
        self.assertEqual(rows['google-perftools']['architecture'],'all')
        for old,new in [('google-perftools all','google-perftools amd64'),('noble/universe','noble/main'),
                        ('2.15-3build1','2.15-3build2'),('azure.archive.ubuntu.com','evil.invalid')]:
            with self.subTest(new=new),self.assertRaises(ContractError):validate_download_log(self.download().replace(old,new),mirrors)
        with self.assertRaises(ContractError):validate_download_log(self.download()+self.download(),mirrors)

    def test_mirror_metadata_and_hosts_restricted(self):
        for old,new in [(b'azure.archive.ubuntu.com',b'evil.invalid'),(b'\tpriority:1',b' priority:1'),
                        (b'priority:1',b'priority:4'),(b'/ubuntu/',b'/ubuntu/../evil/'),(b'http://azure',b'http://user@azure')]:
            with self.assertRaises(ContractError):parse_mirror_list(self.MIRRORS.replace(old,new))
        with self.assertRaises(ContractError):parse_mirror_list(b'\n'*65)

    def test_source_stanza_no_override_and_both_components(self):
        for suffix in ('Trusted: yes\n','Allow-Insecure: yes\n','Allow-Weak: yes\n','Check-Valid-Until: no\n'):
            with self.assertRaises(ContractError):validate_source_stanza(self.SOURCE+suffix)
        for old,new in [('main restricted','restricted'),('universe multiverse','multiverse'),(KEYRING_PATH,'/tmp/keyring')]:
            with self.assertRaises(ContractError):validate_source_stanza(self.SOURCE.replace(old,new))

    def test_index_must_match_authenticated_source(self):
        source=validate_source_stanza(self.SOURCE)
        for old,new in [('Trusted: yes','Trusted: no'),('Origin: Ubuntu','Origin: Other'),(SOURCE_PATH+':1',SOURCE_PATH+':2')]:
            with self.assertRaises(ContractError):validate_index_targets(self.index('main').replace(old,new),source,'main')

    def test_redirect_enabling_rejected(self):
        validate_redirect_overrides("APT_REDIRECT_0='false'\nAPT_REDIRECT_1='0'\n")
        for value in ('true','yes','1','unexpected'):
            with self.assertRaises(ContractError):validate_redirect_overrides(f"APT_REDIRECT_0='{value}'\n")

    def test_archive_hash_mismatch_or_ambiguity_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'x.deb';p.write_bytes(b'offline')
            h=hashlib.sha256(p.read_bytes()).hexdigest()
            self.assertEqual(bind_archive([p],[{'SHA256':h}],'test'),(p,h))
            for meta in ([{}],[{'SHA256':'0'*64}],[{'SHA256':h},{'SHA256':'0'*64}]):
                with self.assertRaises(ContractError):bind_archive([p],meta,'test')
        with self.assertRaises(ContractError):deb_fields('Package: x\nPackage: y\n')

    def test_keyring_bootstrap_exception_preserved(self):
        values=SimpleNamespace(st_uid=0,st_gid=0,st_dev=1,st_ino=2,st_size=10,st_mode=stat.S_IFDIR|0o777)
        self.assertTrue(fixed_path_identity(KEYRING_PATH,values,True)['groupOrWorldWritable'])
        for name in (SOURCE_PATH,MIRROR_PATH):
            with self.assertRaises(ContractError):fixed_path_identity(name,values,True)
        values.st_mode=stat.S_IFLNK|0o777
        with self.assertRaises(ContractError):fixed_path_identity(KEYRING_PATH,values)

    def test_keyring_installed_consistency_not_fake_authentication(self):
        data=b'offline-public-key';digest=hashlib.md5(data,usedforsecurity=False).hexdigest()
        args=['ubuntu-keyring: '+KEYRING_PATH,'ubuntu-keyring\t2023.11.28.1\tall\tinstall ok installed',digest+' '+KEYRING_PATH.lstrip('/'),data]
        result=validate_keyring_package(*args)
        self.assertIn('not independent',result['trustBasis'])
        for index,value in [(0,'other: '+KEYRING_PATH),(2,'0'*32+' '+KEYRING_PATH.lstrip('/')),(3,data+b'bad')]:
            bad=args.copy();bad[index]=value
            with self.assertRaises(ContractError):validate_keyring_package(*bad)


class MixedIndexSelectorTests(unittest.TestCase):
    FIXTURE = Path(__file__).with_name('apt-index-targets-97b7dbe.txt')
    HASH = '61ecf219759260f992be493fbfed4b5d22098b72b9bb87131bf62251b161145c'

    def setUp(self):
        self.raw = self.FIXTURE.read_bytes()
        self.assertEqual(len(self.raw), 4730)
        self.assertEqual(hashlib.sha256(self.raw).hexdigest(), self.HASH)
        self.text = self.raw.decode('utf-8')
        self.stanzas = self.text.strip().split('\n\n')
        self.assertEqual(len(self.stanzas), 5)
        self.source = validate_source_stanza(PackageTests.SOURCE)

    def test_exact_real_mixed_list_selects_only_fixed_ubuntu(self):
        self.assertIn('Origin: microsoft-ubuntu-noble-prod noble', self.stanzas[0])
        for component in ('main', 'universe'):
            row = validate_index_targets(self.text, self.source, component)
            self.assertEqual(row['Repo-URI'], MIRROR_URI + '/')
            self.assertEqual(row['Sourcesentry'], SOURCE_PATH + ':1')
            self.assertEqual(row['Origin'], 'Ubuntu')
            self.assertEqual(row['Component'], component)

    def test_microsoft_only_cannot_satisfy_package_index(self):
        for component in ('main', 'universe'):
            with self.assertRaisesRegex(ContractError, 'Unique fixed Ubuntu'):
                validate_index_targets(self.stanzas[0], self.source, component)

    def test_untrusted_source_claiming_ubuntu_is_not_a_candidate(self):
        spoof = self.stanzas[0].replace('microsoft-ubuntu-noble-prod noble', 'Ubuntu')
        with self.assertRaisesRegex(ContractError, 'Unique fixed Ubuntu'):
            validate_index_targets(spoof, self.source, 'main')
        # Even either half of the fixed source tuple is insufficient.
        for old, new in [('Repo-URI: https://packages.microsoft.com/ubuntu/24.04/prod/',
                          'Repo-URI: ' + MIRROR_URI + '/'),
                         ('Sourcesentry: /etc/apt/sources.list.d/microsoft-prod.list:1',
                          'Sourcesentry: ' + SOURCE_PATH + ':1')]:
            with self.assertRaisesRegex(ContractError, 'Unique fixed Ubuntu'):
                validate_index_targets(spoof.replace(old, new), self.source, 'main')

    def test_duplicate_fixed_candidate_fails_before_accepting_either(self):
        with self.assertRaisesRegex(ContractError, 'duplicated'):
            validate_index_targets(self.text + self.stanzas[1] + '\n\n', self.source, 'main')

    def test_fixed_tuple_does_not_bypass_remaining_identity_checks(self):
        row = self.stanzas[1]
        changes = [('Trusted: yes', 'Trusted: no'), ('Origin: Ubuntu', 'Origin: Microsoft'),
                   ('Label: Ubuntu', 'Label: Other'), ('Release: noble', 'Release: jammy'),
                   ('Suite: noble', 'Suite: jammy'), ('Codename: noble', 'Codename: jammy'),
                   ('Architecture: amd64', 'Architecture: arm64'),
                   ('Identifier: Packages', 'Identifier: Sources'), ('Target-Of: deb', 'Target-Of: deb-src'),
                   ('Filename: /var/lib/apt/lists/', 'Filename: /tmp/'),
                   ('MetaKey: main/binary-amd64/Packages', 'MetaKey: universe/binary-amd64/Packages')]
        for old, new in changes:
            with self.subTest(field=old), self.assertRaises(ContractError):
                validate_index_targets(row.replace(old, new), self.source, 'main')

    def test_forged_fixed_tuple_with_microsoft_identity_is_rejected(self):
        forged = self.stanzas[0].replace(
            'Repo-URI: https://packages.microsoft.com/ubuntu/24.04/prod/', 'Repo-URI: '+MIRROR_URI+'/').replace(
            'Sourcesentry: /etc/apt/sources.list.d/microsoft-prod.list:1', 'Sourcesentry: '+SOURCE_PATH+':1')
        with self.assertRaisesRegex(ContractError, 'authenticated fixed Ubuntu'):
            validate_index_targets(forged, self.source, 'main')

    def test_unknown_source_cannot_replace_missing_fixed_source(self):
        forged = self.stanzas[1].replace('Repo-URI: '+MIRROR_URI+'/', 'Repo-URI: https://unknown.invalid/ubuntu/')
        with self.assertRaisesRegex(ContractError, 'Unique fixed Ubuntu'):
            validate_index_targets(forged, self.source, 'main')
        with self.assertRaisesRegex(ContractError, 'Unexpected fixed package component'):
            validate_index_targets(self.text, self.source, 'unknown')


class EnvironmentTests(unittest.TestCase):
    def test_target_environment_never_mutates_driver(self):
        with tempfile.TemporaryDirectory() as d:
            runner=Runner(Path(d))
            before=dict(runner.env)
            env=target_environment(runner,'/usr/lib/example.so',Path(d)/'profiles'/'unique')
            self.assertEqual(runner.env,before)
            self.assertNotIn('LD_PRELOAD',runner.env)
            self.assertNotIn('HEAPPROFILESIGNAL',env)
            self.assertEqual(env['HEAP_PROFILE_CLEANUP'],'0')
            self.assertEqual([env['HEAP_PROFILE_'+n+'_INTERVAL'] for n in ('ALLOCATION','DEALLOCATION','INUSE','TIME')],['0']*4)

    def test_tool_diagnostics_fail_closed(self):
        check_official_diagnostics('Starting tracking the heap\nDumping heap profile to /tmp/p.0001.heap (q0.begin)\n')
        for line in ('WARNING failed', 'No symbols found', 'Truncated output', 'unknown address'):
            with self.assertRaises(ContractError):check_official_diagnostics(line)


class OwnedProcessTests(unittest.TestCase):
    def make_runner(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Runner(Path(directory.name))

    def test_fast_exit_profile_cap_is_still_checked(self):
        runner = self.make_runner()
        watched = runner.output / 'profiles'
        watched.mkdir()
        path = watched / 'oversized.heap'
        code = 'p=open(' + repr(str(path)) + ',"wb"); p.truncate(' + str(MAX_PROFILE) + '); p.close()'
        with self.assertRaisesRegex(ContractError, '1 MiB buffer cap'):
            runner.command('fast-oversize', [sys.executable, '-c', code], seconds=2, watch=watched)
        self.assertTrue(runner.manifest['commands'][-1]['ownedGroupCleanupVerified'])

    def test_successful_child_group_is_cleaned(self):
        runner = self.make_runner()
        runner.command('short-child', [sys.executable, '-c', 'print("ok")'], seconds=2)
        self.assertTrue(runner.manifest['commands'][-1]['ownedGroupCleanupVerified'])

    def test_timeout_terminates_own_group(self):
        runner = self.make_runner()
        with self.assertRaisesRegex(ContractError, 'timeout'):
            runner.command('timed-child', [sys.executable, '-c', 'import time; time.sleep(5)'], seconds=0.05)
        self.assertTrue(runner.manifest['commands'][-1]['ownedGroupCleanupVerified'])

    def test_leader_exit_does_not_skip_sigkill_for_term_ignoring_child(self):
        runner = self.make_runner()
        # The test temporarily acts as a Linux child subreaper solely so that
        # it can reap its own synthetic orphan after asserting group cleanup.
        # The production runner does not change the subreaper setting.
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        prior = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(prior), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        pidfile = runner.output / 'child.pid'
        child = 'import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(' + repr(str(pidfile)) + ',"w").write(str(os.getpid())); time.sleep(30)'
        leader = ('import subprocess,time; subprocess.Popen([' + repr(sys.executable) + ',"-c",' + repr(child)
                  + ']); p=' + repr(str(pidfile))
                  + '; from pathlib import Path\nwhile not Path(p).exists(): time.sleep(0.005)\n')
        try:
            # A dead adopted child remains a zombie until this test reaps it,
            # so the runner must report cleanup unverified instead of success.
            with self.assertRaisesRegex(ContractError, 'group remains'):
                runner.command('orphan-child', [sys.executable, '-c', leader], seconds=3)
            child_pid = int(pidfile.read_text())
            pid, status = os.waitpid(child_pid, 0)
            self.assertEqual(pid, child_pid)
            self.assertTrue(os.WIFSIGNALED(status))
            self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)
            self.assertFalse(runner.manifest['commands'][-1]['ownedGroupCleanupVerified'])
        finally:
            self.assertEqual(libc.prctl(36, prior.value, 0, 0, 0), 0)


if __name__ == '__main__':
    unittest.main()
