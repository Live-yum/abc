"""Offline fixed-byte and fault-injection tests; no profiler or application run."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest.mock import patch

import application_contract as a

FIXTURES = a.ROOT / 'fixtures'
BINARY = '/home/runner/work/abc/abc/build/gperftools-preflight/native_contract'


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.heap = self.copy('historical-q0.heap', 'heap.0001.heap')
        self.before = self.copy('reconstructed-q0.before.maps', 'q0.before.maps')
        self.after = self.copy('reconstructed-q0.after.maps', 'q0.after.maps')
        self.profile = a.parse_heap(self.heap)

    def copy(self, source, name):
        target = self.root / name
        shutil.copyfile(FIXTURES / source, target)
        return target

    def mutation(self, path, replace, new):
        path.write_bytes(path.read_bytes().replace(replace, new, 1))

    def receipt(self, **kw):
        vals = dict(slot=0, cycle=0, pid=42, start=1000, end=2000,
                    before=self.before.stat().st_size, after=self.after.stat().st_size,
                    heap='heap.0001.heap')
        vals.update(kw)
        path = self.root / 'q0.receipt'
        path.write_text('ABC_HEAP_RECEIPT_V1 {slot} {cycle} {pid} {start} {end} '
                        '{before} {after} {heap}\n'.format(**vals))
        return path

    def test_fixture_manifest_provenance_hashes_and_non_application_label(self):
        manifest = json.loads((FIXTURES / 'fixture-manifest.json').read_text())
        self.assertFalse(manifest['applicationEvidence'])
        for name, row in manifest['files'].items():
            data = (FIXTURES / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), row['sha256'])
            self.assertEqual(len(data), row['bytes'])
            if name.endswith('.maps'):
                self.assertIn('NOT captured', row['kind'])

    def test_actual_static_heap_raw_both_modes_complete_for_two_cuts(self):
        for cut, expected in [('q0', (2, 320, 3, 324)), ('q7', (2, 1558, 9, 3702))]:
            profile = a.parse_heap(FIXTURES / f'historical-{cut}.heap')
            self.assertEqual(profile['header'], expected)
            bracket = a.validate_map_bracket(profile, FIXTURES / f'reconstructed-{cut}.before.maps',
                                             FIXTURES / f'reconstructed-{cut}.after.maps')
            self.assertTrue(bracket['complete'])
            self.assertFalse(bracket['atomicObjectSnapshot'])
            for mode in ('inuse_space', 'inuse_objects'):
                result = a.validate_official_raw(FIXTURES / f'historical-{cut}.{mode}.raw',
                                                BINARY, profile, mode)
                self.assertFalse(result['functionAttributionProvenByRawSymbols'])

    def test_whole_line_bucket_truncation_detected_by_all_four_sums(self):
        lines = self.heap.read_bytes().splitlines(keepends=True)
        self.heap.write_bytes(b''.join(lines[:3] + lines[4:]))  # zero-live, cumulative-positive bucket
        with self.assertRaisesRegex(a.ContractError, 'four bucket'):
            a.parse_heap(self.heap)

    def test_header_counter_corruption_all_four_dimensions(self):
        original = self.heap.read_bytes()
        for old, new in [(b'2:', b'3:'), (b'320', b'321'), (b'3:', b'4:'), (b'324', b'325')]:
            self.heap.write_bytes(original.replace(old, new, 1))
            with self.assertRaises(a.ContractError):
                a.parse_heap(self.heap)

    def test_unknown_necessary_pc_and_unresolved_map_fail(self):
        self.mutation(self.heap, b'0x00401982', b'0x00601982')
        with self.assertRaisesRegex(a.ContractError, 'Necessary PC'):
            a.parse_heap(self.heap)
        self.mutation(self.before, b'/usr/lib/x86_64-linux-gnu/libc.so.6', b'unknown-module')
        with self.assertRaisesRegex(a.ContractError, 'Unknown'):
            a.validate_map_bracket(self.profile, self.before, self.after)

    def test_heap_limit_is_exclusive_and_no_symlink_or_fifo(self):
        self.heap.write_bytes(b'x' * a.MAX_HEAP)
        with self.assertRaisesRegex(a.ContractError, 'cap'):
            a.parse_heap(self.heap)
        link = self.root / 'link'
        link.symlink_to(self.before)
        with self.assertRaises(a.ContractError):
            a.bounded_bytes(link, a.MAX_MAPS)
        import os
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        with self.assertRaisesRegex(a.ContractError, 'regular'):
            a.bounded_bytes(fifo, a.MAX_MAPS)

    def test_bad_heap_ascii_nul_line_and_partial_tail_rejected(self):
        original = self.heap.read_bytes()
        for bad in (original[:-1], original + b'\0\n', original + b'\xff\n',
                    original.replace(b'heap profile:', b'heap\rprofile:', 1),
                    original + b'x' * a.MAX_LINE + b'\n'):
            self.heap.write_bytes(bad)
            with self.assertRaises(a.ContractError):
                a.parse_heap(self.heap)

    def test_whole_line_map_tail_truncation_rejected_even_no_pc_in_tail(self):
        self.heap.write_bytes(b'\n'.join(self.heap.read_bytes().split(b'\n')[:-2]) + b'\n')
        profile = a.parse_heap(self.heap)
        with self.assertRaisesRegex(a.ContractError, 'full maps'):
            a.validate_map_bracket(profile, self.before, self.after)

    def test_missing_executable_map_in_pre_or_post_fails(self):
        data = self.after.read_bytes()
        self.after.write_bytes(b''.join(line for line in data.splitlines(keepends=True)
                                        if b'libstdc++' not in line))
        with self.assertRaisesRegex(a.ContractError, 'executable map'):
            a.validate_map_bracket(self.profile, self.before, self.after)

    def test_changed_device_inode_provider_path_and_necessary_pc_fail(self):
        original = self.after.read_bytes()
        for old, new in [(b'08:01', b'08:02'), (b'9175282', b'9175283'),
                         (b'libtcmalloc.so.4.5.16', b'libtcmalloc.so.4.5.17')]:
            self.after.write_bytes(original.replace(old, new))
            with self.assertRaises(a.ContractError):
                a.validate_map_bracket(self.profile, self.before, self.after)
        self.after.write_bytes(original)
        with self.assertRaisesRegex(a.ContractError, 'Necessary PC'):
            a.validate_map_bracket(self.profile, self.before, self.after, necessary_pcs=[0x999999])

    def test_anonymous_jit_kernel_pc_retained_without_elf_claim(self):
        pc = int(next(row['start'] for row in self.profile['maps'] if row['path'] == '[vdso]'))
        bracket = a.validate_map_bracket(self.profile, self.before, self.after, necessary_pcs=[pc])
        self.assertEqual(bracket['nonElfFrames'][0]['mapping']['path'], '[vdso]')

    def test_maps_overcap_and_partial_line_rejected(self):
        original = self.after.read_bytes()
        for bad in (original[:-1], b'x' * (a.MAX_MAPS + 1)):
            self.after.write_bytes(bad)
            with self.assertRaises(a.ContractError):
                a.validate_map_bracket(self.profile, self.before, self.after)

    def test_receipt_cut_validation_and_exact_ack(self):
        self.receipt()
        cut = a.validate_cut(self.root, slot=0, pid=42)
        path = a.acknowledge(self.root, cut['receipt'], hook_started=1, receipt_seen=2, now=3)
        self.assertEqual(path.read_bytes(), b'ABC_HEAP_ACK_V1 0 0 OK\n')
        with self.assertRaises(FileExistsError):
            a.acknowledge(self.root, cut['receipt'], hook_started=1, receipt_seen=2, now=3)

    def test_receipt_wrong_slot_cycle_pid_heap_size_timing_rejected(self):
        for kw in (dict(slot=1), dict(cycle=7), dict(pid=43), dict(heap='../heap.0001.heap'),
                   dict(before=0), dict(end=0), dict(end=20_000_000_000)):
            with self.subTest(kw=kw), self.assertRaises(a.ContractError):
                a.parse_receipt(self.receipt(**kw), expected_slot=0, expected_pid=42)
        self.receipt(before=1)
        with self.assertRaisesRegex(a.ContractError, 'size mismatch'):
            a.validate_cut(self.root, slot=0, pid=42)

    def test_receipt_corruption_multiline_oversized_fails(self):
        path = self.receipt()
        original = path.read_bytes()
        for bad in (original[:-1], original + original, original + b'x' * 512,
                    original.replace(b' 42 ', b' +42 '), original.replace(b'V1', b'V2')):
            path.write_bytes(bad)
            with self.assertRaises(a.ContractError):
                a.parse_receipt(path, expected_slot=0, expected_pid=42)

    def test_ack_timeout_never_creates_ack(self):
        receipt = a.parse_receipt(self.receipt(), expected_slot=0, expected_pid=42)
        for times in ((0, 8, 10.001), (0, 2, 4.001), (0, 2, 1)):
            with self.assertRaisesRegex(a.ContractError, 'deadline'):
                a.acknowledge(self.root, receipt, hook_started=times[0], receipt_seen=times[1], now=times[2])
        self.assertFalse((self.root / 'q0.ack').exists())

    def test_official_raw_whole_zero_record_loss_and_counter_swap_fail(self):
        path = self.copy('historical-q0.inuse_space.raw', 'bad.raw')
        data = path.read_bytes()
        marker = b'--- profile\n'
        start = data.index(marker) + len(marker) + 40
        value, depth = struct.unpack_from('<2Q', data, start)
        self.assertEqual(value, 0)
        path.write_bytes(data[:start] + data[start + 16 + 8 * depth:])
        with self.assertRaisesRegex(a.ContractError, 'historical zero'):
            a.validate_official_raw(path, BINARY, self.profile, 'inuse_space')
        changed = bytearray(data)
        second = start + 16 + 8 * depth
        _, second_depth = struct.unpack_from('<2Q', data, second)
        third = second + 16 + 8 * second_depth
        second_value = struct.unpack_from('<Q', data, second)[0]
        third_value = struct.unpack_from('<Q', data, third)[0]
        struct.pack_into('<Q', changed, second, third_value)
        struct.pack_into('<Q', changed, third, second_value)
        path.write_bytes(changed)
        with self.assertRaisesRegex(a.ContractError, 'full stack'):
            a.validate_official_raw(path, BINARY, self.profile, 'inuse_space')
        path.write_bytes(data + b'x')
        with self.assertRaises(a.raw_parser.PprofRawError):
            a.validate_official_raw(path, BINARY, self.profile, 'inuse_space')

    def test_raw_16_mib_acceptance_never_64_mib(self):
        raw = self.root / 'too-big.raw'
        with raw.open('wb') as stream:
            stream.truncate(a.MAX_RAW + 1)
        with self.assertRaisesRegex(a.raw_parser.PprofRawError, 'byte limit'):
            a.validate_official_raw(raw, BINARY, self.profile, 'inuse_space')
        with self.assertRaisesRegex(a.ContractError, '16 MiB'):
            a.inspect_sidecar(self.root)

    def test_sidecar_extra_file_third_dump_and_nonregular_fail(self):
        expected = {'heap.0001.heap', 'q0.before.maps', 'q0.after.maps'}
        self.assertEqual(len(a.inspect_sidecar(self.root, expected_files=expected)['files']), 3)
        (self.root / 'unexpected').write_bytes(b'x')
        with self.assertRaisesRegex(a.ContractError, 'Unexpected/missing'):
            a.inspect_sidecar(self.root, expected_files=expected)
        (self.root / 'heap.0002.heap').write_bytes(b'x')
        (self.root / 'heap.0003.heap').write_bytes(b'x')
        with self.assertRaisesRegex(a.ContractError, 'total cap'):
            a.inspect_sidecar(self.root, max_heaps=2)

    def test_sidecar_256_mib_count_and_no_deletion_of_evidence(self):
        path = self.root / 'oversized-symbols'
        with path.open('wb') as stream:
            stream.truncate(a.MAX_SIDECAR + 1)
        with self.assertRaisesRegex(a.ContractError, '256 MiB'):
            a.inspect_sidecar(self.root)
        self.assertTrue(path.exists())
        self.assertTrue(self.heap.exists())

    def test_runtime_metadata_only_allows_in_progress_zero_then_complete(self):
        self.heap.write_bytes(b'')
        self.before.write_bytes(b'')
        with patch('application_contract.bounded_bytes', side_effect=AssertionError('No polling payload reads')):
            for _ in range(3):
                inventory = a.check_sidecar_caps(self.root)
                self.assertEqual(inventory['files']['heap.0001.heap']['bytes'], 0)
        with self.assertRaisesRegex(a.ContractError, 'empty'):
            a.inspect_sidecar(self.root)
        shutil.copyfile(FIXTURES / 'historical-q0.heap', self.heap)
        shutil.copyfile(FIXTURES / 'reconstructed-q0.before.maps', self.before)
        self.assertTrue(a.inspect_sidecar(self.root)['files']['heap.0001.heap']['sha256'])

    def test_symbol_metadata_missing_or_oversized_module_fails(self):
        bracket = a.validate_map_bracket(self.profile, self.before, self.after)
        paths = {key[-1] for key in bracket['fileExecutableMaps']}
        records = {}
        for start, end, perms, offset, inode, path in bracket['fileExecutableMaps']:
            records[path] = dict(path=path, bytes=offset + end - start, sha256='a' * 64,
                                 buildId='a' * 40, loadBias=start-offset,
                                 ptLoad=[dict(offset=offset, vaddr=offset, fileSize=end-start,
                                              memorySize=end-start, flags=5, align=4096)],
                                 dynsym=[], symtab=[], debugInfo=None)
        result = a.validate_module_records(bracket, records)
        self.assertFalse(result['loadedIdentityProven'])
        first_map = next(m for m in self.profile['maps'] if m['path'] in records and 'x' in m['permissions'])
        identity = a.normalized_file_pc(first_map['start'] + 4, first_map, records[first_map['path']])
        self.assertEqual(identity, ('a' * 40, first_map['offset'] + 4))
        bad = copy.deepcopy(records)
        bad[next(iter(paths))]['loadBias'] += 4096
        with self.assertRaisesRegex(a.ContractError, 'PT_LOAD/load bias'):
            a.validate_module_records(bracket, bad)
        records[next(iter(paths))]['bytes'] = a.MAX_MODULE + 1
        with self.assertRaisesRegex(a.ContractError, 'ELF byte cap'):
            a.validate_module_records(bracket, records)

    def test_arm_completion_preserves_legacy_failure_and_null_allocator(self):
        legacy = {'passed': False, 'errors': ['image coverage missing'],
                  'libc': {'status': 3, 'liveBytes': None}}
        path = self.root / 'legacy.json'
        path.write_text(json.dumps(legacy))
        result = a.arm_completion(workload_complete=True, heap_files_complete=True,
                                  attribution_available=True, original_report=path)
        self.assertEqual(result['originalValidatorReport'], legacy)
        self.assertFalse(result['claimsObjectIdentity'])
        self.assertFalse(result['claimsProductNetLeak'])
        with self.assertRaises(a.ContractError):
            a.arm_completion(workload_complete=False, heap_files_complete=True,
                             attribution_available=True, original_report=path)


class OsLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'os-0000.jsonl'
        self.tail = a.OsLogTail(self.path)

    def row(self, sequence, rss=1):
        return json.dumps({'type': 'os', 'sequence': sequence, 'rssBytes': rss}).encode() + b'\n'

    def test_incremental_existing_sampler_only_with_partial_line(self):
        data = self.row(0)
        self.path.write_bytes(data[:-3])
        self.assertEqual(self.tail.read_new(), 0)
        with self.path.open('ab') as stream:
            stream.write(data[-3:] + self.row(1, a.RSS_STOP))
        self.assertEqual(self.tail.read_new(final=True), 2)
        self.assertEqual(self.tail.max_rss, a.RSS_STOP)
        self.assertEqual(self.tail.read_new(final=True), 0)

    def test_observed_rss_stop_and_sequence_fail(self):
        self.path.write_bytes(self.row(0, a.RSS_STOP + 1))
        with self.assertRaisesRegex(a.ContractError, '2 GiB'):
            self.tail.read_new()
        self.path.write_bytes(self.row(1))
        with self.assertRaisesRegex(a.ContractError, 'sequence'):
            a.OsLogTail(self.path).read_new()

    def test_missing_final_replaced_truncated_duplicate_json_fail(self):
        self.assertEqual(self.tail.read_new(), 0)
        with self.assertRaises(a.ContractError):
            self.tail.read_new(final=True)
        self.path.write_bytes(self.row(0))
        self.tail.read_new()
        self.path.write_bytes(b'')
        with self.assertRaisesRegex(a.ContractError, 'truncated'):
            self.tail.read_new()
        self.path.write_bytes(b'{"type":"os","sequence":0,"rssBytes":1,"rssBytes":2}\n')
        with self.assertRaisesRegex(a.ContractError, 'Invalid'):
            a.OsLogTail(self.path).read_new()

    def test_partial_final_line_and_line_cap_fail(self):
        for data in (self.row(0)[:-1], b'x' * a.MAX_LINE):
            self.path.write_bytes(data)
            with self.assertRaises(a.ContractError):
                a.OsLogTail(self.path).read_new(final=True)

    def test_original_rotated_chunks_keep_sequence_and_rss_stop(self):
        root = Path(self.tmp.name)
        (root / 'os-0.jsonl').write_bytes(self.row(0))
        journal = a.OsJournalTail(root)
        self.assertEqual(journal.read_new(), 1)
        (root / 'os-1.jsonl').write_bytes(self.row(1, 12))
        journal.read_new()
        self.assertEqual(journal.read_new(), 1)
        result = journal.finish(['os-0.jsonl', 'os-1.jsonl'])
        self.assertEqual(result['sampleCount'], 2)
        self.assertEqual(result['observedMaxRssBytes'], 12)
        self.assertFalse(result['newSamplingPerformed'])
        (root / 'os-2.jsonl').write_bytes(self.row(2, a.RSS_STOP + 1))
        journal.read_new()
        with self.assertRaisesRegex(a.ContractError, '2 GiB'):
            journal.read_new()


if __name__ == '__main__':
    unittest.main()
