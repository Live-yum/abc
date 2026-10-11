"""Offline bounded maps-read evidence contracts; never opens another process."""
import json
import os
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import dependencies
from application_contract import ContractError, MAX_MAPS
from elf_identity import target_maps, BoundModules
from capture_contract import sidecar_caps, CutWatcher

ROW = b'00001000-00002000 r-xp 00000000 08:01 1 /lib/example.so\n'

class FakeIdentity:
    def __init__(self, root, fail_after=False):
        self.proc_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        self.calls = 0
        self.fail_after = fail_after
    def verify(self):
        self.calls += 1
        if self.fail_after and self.calls == 2:
            raise ContractError('Identity changed after read')

class MapsCaptureContracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.proc = self.root / 'proc'; self.proc.mkdir()
        self.out = self.root / 'out'; self.out.mkdir()
        self.identity = FakeIdentity(self.proc)
        self.addCleanup(os.close, self.identity.proc_fd)
        self.addCleanup(self.tmp.cleanup)
    def capture(self, data, name='startup.maps', cap=lambda: None):
        (self.proc / 'maps').write_bytes(data)
        return target_maps(self.identity, self.out / name, cap)
    def test_saved_before_parse_and_post_identity(self):
        with patch('elf_identity.parse_maps') as parse:
            def check(data):
                self.assertEqual((self.out/'startup.maps').read_bytes(), data)
                self.assertEqual(self.identity.calls, 2)
                return []
            parse.side_effect=check
            self.assertEqual(self.capture(ROW), (ROW, []))
        meta=json.loads((self.out/'startup.capture.json').read_text())
        self.assertTrue(meta['complete']); self.assertTrue(meta['savedBeforeParse'])
    def test_malformed_bytes_preserved(self):
        with self.assertRaises(ContractError): self.capture(b'not maps\n')
        self.assertEqual((self.out/'startup.maps').read_bytes(), b'not maps\n')
    def test_executable_deleted_preserved_but_rejected(self):
        row=ROW.rstrip()+b' (deleted)\n'
        with self.assertRaises(ContractError): self.capture(row)
        self.assertEqual((self.out/'startup.maps').read_bytes(),row)
    def test_over_cap_bounded_prefix_explicit_incomplete(self):
        with self.assertRaises(ContractError): self.capture(b'x'*(MAX_MAPS+2))
        self.assertEqual((self.out/'startup.maps').stat().st_size,MAX_MAPS)
        meta=json.loads((self.out/'startup.capture.json').read_text())
        self.assertFalse(meta['complete']); self.assertEqual(meta['readBytes'],MAX_MAPS+1)
    def test_empty_preserved_and_rejected(self):
        with self.assertRaises(ContractError): self.capture(b'')
        self.assertEqual((self.out/'startup.maps').read_bytes(),b'')
    def test_post_read_identity_failure_keeps_raw(self):
        self.identity.fail_after=True
        with self.assertRaises(ContractError): self.capture(ROW)
        self.assertEqual((self.out/'startup.maps').read_bytes(),ROW)
    def test_cap_failure_keeps_raw_and_never_parses(self):
        def fail(): raise ContractError('aggregate cap')
        with patch('elf_identity.parse_maps') as parse:
            with self.assertRaises(ContractError): self.capture(ROW,cap=fail)
            parse.assert_not_called()
        self.assertEqual((self.out/'startup.maps').read_bytes(),ROW)
    def test_repeat_and_symlink_outputs_rejected(self):
        self.capture(ROW)
        with self.assertRaises(FileExistsError): self.capture(ROW)
        (self.out/'startup-consistency.maps').symlink_to(self.out/'startup.maps')
        with self.assertRaises(FileExistsError): self.capture(ROW,'startup-consistency.maps')
        self.assertEqual((self.out/'startup.maps').read_bytes(),ROW)
    def test_two_reads_two_distinct_raw_files(self):
        self.capture(ROW)
        self.capture(ROW.replace(b'example',b'changed'),'startup-consistency.maps')
        self.assertEqual(self.identity.calls,4)
        self.assertEqual(len(list(self.out.glob('*.maps'))),2)
    def test_aggregate_twelve_maps_ten_mib(self):
        roots=[]
        for arm in ('control','product'):
            root=self.out/arm; root.mkdir(); roots.append(root)
            for name in ('startup.maps','startup-consistency.maps','q0.before.maps','q0.after.maps','q7.before.maps','q7.after.maps'):
                (root/name).write_bytes(ROW)
        self.assertEqual(sidecar_caps(roots),len(ROW)*12)
        (roots[0]/'extra.maps').write_bytes(ROW)
        with self.assertRaises(ContractError): sidecar_caps(roots)
    def test_aggregate_byte_limit_not_raised(self):
        roots=[]
        for arm in ('control','product'):
            root=self.out/arm;root.mkdir();roots.append(root)
            for name in ('startup.maps','startup-consistency.maps','q0.before.maps','q0.after.maps','q7.before.maps','q7.after.maps'):
                (root/name).write_bytes(b'x'*MAX_MAPS)
        with self.assertRaises(ContractError):sidecar_caps(roots)

    def test_startup_second_parse_failure_closes_owned_elf_fd(self):
        held=[]
        def capture(manager,path,sealed,deadline,cap):
            fd=os.open(self.proc/'maps',os.O_RDONLY);held.append(fd)
            manager.held[path]=(fd,None)
            return {'sha256':'0'*64,'path':path}
        def bind(manager,row,mapped):
            (self.proc/'maps').write_bytes(b'bad reread\n')
        (self.proc/'maps').write_bytes(ROW)
        with patch.object(BoundModules,'capture_file',capture), \
             patch.object(BoundModules,'bind_mappings',bind), \
             patch.object(BoundModules,'verify_metadata'), \
             patch('elf_identity.validate_module_records'):
            with self.assertRaises(ContractError):
                BoundModules(self.identity,{},self.root/'modules',self.out/'capture',
                             deadline=float('inf'),cap_check=lambda:None)
        self.assertEqual(len(held),1)
        with self.assertRaises(OSError):os.fstat(held[0])
        self.assertEqual((self.out/'capture/startup.maps').read_bytes(),ROW)
        self.assertEqual((self.out/'capture/startup-consistency.maps').read_bytes(),b'bad reread\n')
        self.assertEqual(self.identity.calls,4)

    def test_read_open_failure_metadata_no_parse_or_retry(self):
        with patch('elf_identity.parse_maps') as parse:
            with self.assertRaises(FileNotFoundError):
                target_maps(self.identity,self.out/'startup.maps',lambda:None)
            parse.assert_not_called()
        meta=json.loads((self.out/'startup.capture.json').read_text())
        self.assertFalse(meta['rawAvailable']);self.assertFalse(meta['complete'])
        self.assertEqual(meta['readErrorType'],'FileNotFoundError')
        self.assertEqual(meta['stage'],'startup')
        self.assertLessEqual(meta['readStartMonotonicNs'],meta['readEndMonotonicNs'])
        self.assertFalse((self.out/'startup.maps').exists())
        self.assertEqual(self.identity.calls,1)
    def test_read_failure_closes_fd_and_records_failure(self):
        (self.proc/'maps').mkdir()
        with patch('elf_identity.parse_maps') as parse, patch('elf_identity.os.close', wraps=os.close) as close:
            with self.assertRaises(IsADirectoryError):
                target_maps(self.identity,self.out/'startup.maps',lambda:None)
            parse.assert_not_called()
        meta=json.loads((self.out/'startup.capture.json').read_text())
        self.assertEqual(meta['readErrorType'],'IsADirectoryError')
        self.assertFalse(meta['rawAvailable'])
        close.assert_called_once()
        with self.assertRaises(OSError): os.fstat(close.call_args.args[0])
    def test_raw_write_and_metadata_failure_never_parse(self):
        (self.out/'startup.maps').mkdir()
        with patch('elf_identity.parse_maps') as parse:
            with self.assertRaises(FileExistsError):self.capture(ROW)
            parse.assert_not_called()
        (self.out/'startup.maps').rmdir()
        with patch('elf_identity.save',side_effect=OSError('write failure')), \
             patch('elf_identity.parse_maps') as parse:
            with self.assertRaises(OSError):self.capture(ROW)
            parse.assert_not_called()
        self.assertEqual((self.out/'startup.maps').read_bytes(),ROW)

    def test_post_ack_record_preserves_mapping_classification_and_diffs(self):
        (self.out/'q0.receipt').write_text('fixture')
        now=time.monotonic()
        gauges=SimpleNamespace(read_new=lambda:None,cuts={'q0':{'observed':now}})
        modules=SimpleNamespace(verify_cut=lambda bracket:None)
        bracket={'mappingRoles':{'before':{'file-executable':1}},
                 'mapDifferences':{'beforeToProfile':{'added':[{'role':'deleted-file-non-executable'}]}},
                 'beforeSha256':'a'*64,'afterSha256':'b'*64}
        receipt={'dumpEndNs':time.monotonic_ns()}
        watcher=CutWatcher(self.out,gauges,123,modules)
        with patch('capture_contract.validate_cut',return_value={'receipt':receipt,'bracket':bracket}), \
             patch('capture_contract.acknowledge') as ack:
            watcher.check()
        ack.assert_called_once()
        self.assertEqual(watcher.records[0]['mappingEvidence'],bracket)
        self.assertEqual(json.loads(json.dumps(watcher.records))[0]['mappingEvidence'],bracket)
