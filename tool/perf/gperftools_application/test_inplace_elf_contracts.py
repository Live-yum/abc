"""Synthetic ELF/offline Python tests. Never run a profiler, Flutter or WLD."""
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import time
import unittest
from unittest.mock import patch

import dependencies
from application_contract import (ContractError, INPLACE_ELF_LIMITS, MAX_MODULE,
    MAX_SYSTEM_ELF, MAX_ARM_ELF_INPUT, MAX_ELF_READ, MAX_ELF_METADATA,
    validate_module_records)
from elf_identity import (BoundModules, MetadataReader, elf_metadata,
    elf_metadata_fd, endpoint_delta, file_identity, input_cap, stream_sha)


BUILD_ID = '11223344556677889900aabbccddeeff0011223344'
SYMBOLS = [
    ('outer', 0x1100, 32), ('alias', 0x1100, 32),
    ('overlap', 0x1110, 32), ('zero', 0x1130, 0),
    ('later', 0x1140, 4), ('not_sampled', 0x1180, 16),
]


def fixture(symbols=SYMBOLS, *, build_id=BUILD_ID, debuglink=None,
            supplementary=False, embedded=False):
    """Independent ELF64 byte fixture, with valid half-open function ranges."""
    payload = bytearray(4096)
    payload[:16] = b'\x7fELF\x02\x01\x01' + bytes(9)
    strings = bytearray(b'\x00')
    entries = bytearray(24)
    for name, address, size in symbols:
        offset = len(strings)
        strings.extend(name.encode() + b'\x00')
        entries.extend(struct.pack('<IBBHQQ', offset, 0x12, 0, 1, address, size))
    names = ['', '.text', '.shstrtab', '.strtab', '.symtab', '.dynsym']
    extra = []
    if debuglink:
        name, crc = debuglink
        data = name.encode() + b'\x00'
        data += bytes((-len(data)) % 4) + struct.pack('<I', crc)
        extra.append(('.gnu_debuglink', data))
    if supplementary:
        extra.append(('.gnu_debugaltlink', b'external\x00' + bytes.fromhex(build_id)))
    if embedded:
        extra.append(('.debug_info', bytes(1)))
    names.extend(name for name, _ in extra)
    shnames = b'\x00'.join(name.encode() for name in names) + b'\x00'
    name_offsets, cursor = [], 0
    for name in names:
        name_offsets.append(cursor)
        cursor += len(name) + 1
    def append(data):
        offset = len(payload)
        payload.extend(data)
        return offset, len(data)
    note = struct.pack('<III', 4, len(bytes.fromhex(build_id)), 3) + b'GNU\x00' + bytes.fromhex(build_id)
    note += bytes((-len(note)) % 4)
    note_offset, note_size = append(note)
    names_offset, names_size = append(shnames)
    strings_offset, strings_size = append(strings)
    symbols_offset, symbols_size = append(entries)
    dyn_offset, dyn_size = append(entries)
    extras = [append(data) for _, data in extra]
    shoff = len(payload)
    sections = [
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (name_offsets[1], 1, 6, 0x1000, 0, 4096, 0, 0, 16, 0),
        (name_offsets[2], 3, 0, 0, names_offset, names_size, 0, 0, 1, 0),
        (name_offsets[3], 3, 0, 0, strings_offset, strings_size, 0, 0, 1, 0),
        (name_offsets[4], 2, 0, 0, symbols_offset, symbols_size, 3, 1, 8, 24),
        (name_offsets[5], 11, 0, 0, dyn_offset, dyn_size, 3, 1, 8, 24),
    ]
    for index, (offset, size) in enumerate(extras, 6):
        sections.append((name_offsets[index], 1, 0, 0, offset, size, 0, 0, 1, 0))
    for section in sections:
        payload.extend(struct.pack('<IIQQQQIIQQ', *section))
    struct.pack_into('<HHIQQQIHHHHHH', payload, 16, 3, 62, 1, 0, 64, shoff,
                     0, 64, 56, 2, 64, len(sections), 2)
    struct.pack_into('<IIQQQQQQ', payload, 64, 1, 5, 0, 0x1000, 0,
                     4096, 4096, 4096)
    struct.pack_into('<IIQQQQQQ', payload, 120, 4, 4, note_offset, 0, 0,
                     note_size, note_size, 4)
    return bytes(payload)


class InplaceElfContracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='inplace-elf-contract-')
        self.root = Path(self.tmp.name)
        self.binary = self.root / 'module.so'
        self.binary.write_bytes(fixture())
        self.managers = []

    def tearDown(self):
        for manager in self.managers:
            manager.close()
        self.tmp.cleanup()

    def manager(self):
        manager = BoundModules.__new__(BoundModules)
        manager.held, manager.records, manager.deferred = {}, {}, {}
        manager.files, manager.unique_inputs, manager.endpoint_debug = {}, {}, {}
        manager.debug_selections, manager.indirect_debug = {}, {}
        manager.evidence = self.root / ('evidence-' + str(len(self.managers)))
        manager.evidence.mkdir()
        manager.cap_check = lambda **_: None
        self.managers.append(manager)
        return manager

    def parse(self, offsets):
        with self.binary.open('rb') as stream:
            return elf_metadata_fd(stream.fileno(), self.binary.stat().st_size,
                time.monotonic() + 10, necessary_offsets=offsets)

    def profiles(self, path):
        maps = [dict(start=0x1000, end=0x2000, offset=0, inode=1,
                     path=path, permissions='r-xp')]
        pcs = (0x1100, 0x1110, 0x111f, 0x1120, 0x112f, 0x1130,
               0x113f, 0x1140, 0x1143, 0x1144)
        first = {'maps': maps, 'buckets': [
            {'stack': [pc], 'counters': [0, 0, 2**60 + index, 2**62 + index]}
            for index, pc in enumerate(pcs)]}
        last = copy.deepcopy(first)
        for row in last['buckets']:
            row['counters'][0:2] = [3, 2**55]
        last['buckets'].append({'stack': [0x1100, 0x1130], 'counters': [1, 7, 4, 99]})
        return first, last

    def test_explicit_limits_preserve_built_artifact_and_application_budgets(self):
        self.assertEqual((MAX_SYSTEM_ELF, MAX_ARM_ELF_INPUT, MAX_ELF_READ, MAX_ELF_METADATA),
                         (256 << 20, 1 << 30, 1 << 20, 64 << 20))
        self.assertEqual(input_cap('/usr/lib/x86_64-linux-gnu/libLLVM.so.20.1'), 256 << 20)
        self.assertEqual(input_cap(self.binary), 64 << 20)
        self.assertFalse(INPLACE_ELF_LIMITS['originalApplicationAcceptanceChanged'])
        self.assertFalse(INPLACE_ELF_LIMITS['originalTimeBudgetsChanged'])

    def test_fd_metadata_semantics_equal_independent_complete_fixture(self):
        observed = self.parse(None)
        expected = [{'name': name, 'address': address, 'size': size}
                    for name, address, size in SYMBOLS if size]
        self.assertEqual(observed['dynsym'], expected)
        self.assertEqual(observed['symtab'], expected)
        self.assertEqual(observed['buildId'], BUILD_ID)
        self.assertEqual(observed['ptLoad'], [dict(offset=0, vaddr=0x1000,
            fileSize=4096, memorySize=4096, flags=5, align=4096)])
        compatibility_wrapper = elf_metadata(self.binary.read_bytes())
        self.assertEqual(observed, compatibility_wrapper)

    def test_full_endpoint_delta_equals_unfiltered_all_fields_large_integers(self):
        fixture_path = '/fixture/module.so'
        first, last = self.profiles(fixture_path)
        pcs = {pc for profile in (first, last) for row in profile['buckets'] for pc in row['stack']}
        full, selected = self.parse(None), self.parse(pcs)
        for row in (full, selected):
            row.update(path=fixture_path, loadBias=0)
        a = endpoint_delta(first, last, {fixture_path: full})
        b = endpoint_delta(first, last, {fixture_path: selected})
        # Golden generated from the frozen pre-change parser/endpoint implementation.
        self.assertEqual(hashlib.sha256(json.dumps(b, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                         'bf28feb39621b9a9fcfb577916fd1c99adb6c51c7fe1919986dcf3c303efe656')
        self.assertEqual(a, b)
        self.assertEqual(b['unknownBucketCount'], 4)
        frames = {row['frames'][0]['elfOffset']: row['frames'][0]
                  for row in b['allStackBuckets'] if len(row['frames']) == 1}
        self.assertEqual(frames[0x1110]['exactRangeSymbolCandidates'], ['alias', 'outer', 'overlap'])
        self.assertEqual(frames[0x1120]['exactRangeSymbolCandidates'], ['overlap'])
        self.assertFalse(frames[0x1130]['functionKnown'])
        self.assertFalse(frames[0x1144]['functionKnown'])
        self.assertNotIn('not_sampled', [row['name'] for row in selected['symtab']])

    def test_startup_full_scan_does_not_keep_unsampled_symbol_json(self):
        symbols = [('unsampled_' + str(index), 0x1800 + index * 4, 4) for index in range(30000)]
        self.binary.write_bytes(fixture(symbols))
        empty = self.parse(())
        self.assertEqual(empty['dynsym'], [])
        self.assertEqual(empty['symtab'], [])
        self.assertLess(len(json.dumps(empty)), 10000)
        self.assertTrue(empty['metadataProof']['fullSymbolScanComplete'])
        for table in empty['metadataProof']['symbolTables']:
            self.assertEqual(table['entryCount'], 30001)
            self.assertEqual(table['acceptedFunctionCount'], 30000)
            self.assertEqual(table['matchedFunctionCount'], 0)

    def test_complete_table_source_hashes_and_counts_retained(self):
        data = self.binary.read_bytes()
        result = self.parse([0x1110])
        for row in result['metadataProof']['symbolTables']:
            self.assertEqual(row['sha256'], hashlib.sha256(data[row['offset']:row['offset'] + row['bytes']]).hexdigest())
            self.assertEqual(row['stringsSha256'], hashlib.sha256(data[row['stringsOffset']:row['stringsOffset'] + row['stringsBytes']]).hexdigest())
            self.assertEqual((row['entryCount'], row['acceptedFunctionCount'], row['matchedFunctionCount']), (7, 5, 3))
            self.assertTrue(row['fullScanComplete'])
        self.assertFalse(result['metadataProof']['offlineResymbolizationSelfContained'])

    def test_stream_input_over_old_cap_no_copy_and_reads_at_most_one_mib(self):
        with self.binary.open('r+b') as stream:
            stream.truncate((64 << 20) + 7)
        real_pread, requests = os.pread, []
        def observed(fd, count, offset):
            requests.append(count)
            return real_pread(fd, count, offset)
        manager = self.manager()
        with patch('elf_identity.system_elf', return_value=True), patch('elf_identity.os.pread', side_effect=observed):
            row = manager.seal_file(str(self.binary), time.monotonic() + 10)
        self.assertGreater(row['bytes'], MAX_MODULE)
        self.assertTrue(requests and max(requests) <= 1 << 20)
        self.assertEqual(list(manager.evidence.glob('*.elf')), [])
        self.assertNotIn('preservedElf', row)
        self.assertEqual(sum(manager.unique_inputs.values()), self.binary.stat().st_size)
        self.assertEqual(row['dynsym'], [])

    def test_system_per_file_cap_and_built_file_cap_reject_before_hash(self):
        with self.binary.open('r+b') as stream:
            stream.truncate(MAX_SYSTEM_ELF + 1)
        manager = self.manager()
        with patch('elf_identity.system_elf', return_value=True), patch('elf_identity.os.pread') as reader:
            with self.assertRaisesRegex(ContractError, 'byte/type cap'):
                manager.seal_file(str(self.binary), time.monotonic() + 1)
            reader.assert_not_called()
        with self.assertRaisesRegex(ContractError, '64 MiB/type cap'):
            file_identity(self.binary)

    def test_inclusive_input_boundaries_and_non_system_metadata_cannot_claim_large_cap(self):
        with self.binary.open('r+b') as stream:
            stream.truncate(MAX_SYSTEM_ELF)
        manager = self.manager()
        manager.unique_inputs[(999, 999)] = MAX_ARM_ELF_INPUT - MAX_SYSTEM_ELF
        # Hashing itself is tested with real >64MiB input above; here isolate
        # the inclusive size/aggregate boundaries without hashing another 256MiB.
        with patch('elf_identity.system_elf', return_value=True), patch('elf_identity.stream_sha', return_value='f' * 64):
            manager.seal_file(str(self.binary), time.monotonic() + 1)
        self.assertEqual(sum(manager.unique_inputs.values()), MAX_ARM_ELF_INPUT)
        row = elf_metadata(fixture())
        path = '/usr/lib/libfixture.so'
        row.update(path=path, bytes=143545784, sha256='a' * 64, loadBias=0,
                   inputPolicy='inplace-system-elf')
        bracket = {'fileExecutableMaps': [(0x1000, 0x2000, 'r-xp', 0, 1, path)]}
        validate_module_records(bracket, {path: row})
        row['bytes'] = MAX_SYSTEM_ELF + 1
        with self.assertRaisesRegex(ContractError, 'byte cap'):
            validate_module_records(bracket, {path: row})
        row.update(path='/tmp/non-system.so', bytes=143545784)
        with self.assertRaisesRegex(ContractError, 'byte cap'):
            validate_module_records({'fileExecutableMaps': [(0x1000, 0x2000, 'r-xp', 0, 1, row['path'])]}, {row['path']: row})

    def test_unique_input_total_limit_and_same_inode_count_once(self):
        manager = self.manager()
        manager.unique_inputs[(999, 999)] = MAX_ARM_ELF_INPUT - self.binary.stat().st_size + 1
        with self.assertRaisesRegex(ContractError, '1 GiB'):
            manager.seal_file(str(self.binary), time.monotonic() + 1)
        other = self.manager()
        other.seal_file(str(self.binary), time.monotonic() + 1)
        alias = self.root / 'hardlink.so'
        os.link(self.binary, alias)
        other.seal_file(str(alias), time.monotonic() + 1)
        self.assertEqual(sum(other.unique_inputs.values()), self.binary.stat().st_size)

    def test_metadata_limit_and_read_extent_fail_before_allocation(self):
        reader = MetadataReader(MAX_SYSTEM_ELF, lambda *_: self.fail('oversize must fail before reading'), time.monotonic() + 1)
        with self.assertRaisesRegex(ContractError, '64 MiB'):
            reader.read(0, MAX_ELF_METADATA + 1)
        with self.assertRaisesRegex(ContractError, 'extent'):
            reader.read(MAX_SYSTEM_ELF, 1)
        reader = MetadataReader(MAX_SYSTEM_ELF, lambda off, count: b'x' * count, time.monotonic() + 1)
        reader.extracted = MAX_ELF_METADATA - 1
        self.assertEqual(reader.read(0, 1), b'x')
        with self.assertRaisesRegex(ContractError, '64 MiB'):
            reader.read(1, 1)

    def test_pread_short_reads_accumulate_and_truncation_fails(self):
        data = fixture()
        reader = MetadataReader(len(data), lambda off, count: data[off:off + min(7, count)], time.monotonic() + 1)
        self.assertEqual(reader.read(0, 99), data[:99])
        truncated = MetadataReader(len(data), lambda off, count: b'', time.monotonic() + 1)
        with self.assertRaisesRegex(ContractError, 'Truncated'):
            truncated.read(0, 1)
        with self.binary.open('rb') as stream:
            with self.assertRaisesRegex(ContractError, 'truncated'):
                stream_sha(stream.fileno(), len(data) + 1, time.monotonic() + 1)

    def test_path_replace_inplace_change_and_truncate_detected(self):
        for mutation in ('replace', 'change', 'truncate'):
            with self.subTest(mutation=mutation):
                self.binary.write_bytes(fixture())
                manager = self.manager()
                manager.seal_file(str(self.binary), time.monotonic() + 1)
                if mutation == 'replace':
                    new = self.root / 'replacement'
                    new.write_bytes(self.binary.read_bytes())
                    os.replace(new, self.binary)
                elif mutation == 'change':
                    with self.binary.open('r+b') as stream:
                        stream.seek(2048)
                        stream.write(b'X')
                else:
                    with self.binary.open('r+b') as stream:
                        stream.truncate(64)
                with self.assertRaisesRegex(ContractError, 'metadata changed'):
                    manager.rehash(time.monotonic() + 1)

    def test_hash_mismatch_detected_even_if_stat_check_is_stubbed(self):
        manager = self.manager()
        manager.seal_file(str(self.binary), time.monotonic() + 1)
        with self.binary.open('r+b') as stream:
            stream.seek(2048)
            stream.write(b'X')
        with patch('elf_identity.path_matches_fd'):
            with self.assertRaisesRegex(ContractError, 'bytes changed'):
                manager.rehash(time.monotonic() + 1)

    def test_deadline_expiration_stops_hash_and_metadata(self):
        with self.binary.open('rb') as stream:
            with self.assertRaisesRegex(ContractError, 'deadline'):
                stream_sha(stream.fileno(), self.binary.stat().st_size, time.monotonic() - 1)
            with self.assertRaisesRegex(ContractError, 'deadline'):
                elf_metadata_fd(stream.fileno(), self.binary.stat().st_size, time.monotonic() - 1)

    def test_prepare_symbols_retains_full_union_proof_and_all_candidates(self):
        manager = self.manager()
        row = manager.capture_file(str(self.binary), None, time.monotonic() + 2, manager.cap_check)
        row['loadBias'] = 0
        manager.records[str(self.binary)] = row
        first, last = self.profiles(str(self.binary))
        result = manager.prepare_symbols([first, last], time.monotonic() + 2)
        self.assertFalse(result['pathFdBindingAtomic'])
        self.assertFalse(result['offlineResymbolizationSelfContained'])
        candidates = {item['elfOffset']: item['exactRangeSymbolCandidates']
                      for item in row['metadataProof']['perPcCandidates']}
        self.assertEqual(candidates[0x1110], ['alias', 'outer', 'overlap'])
        self.assertEqual(candidates[0x1130], [])
        self.assertEqual(len(list(manager.evidence.glob('*-endpoint-symbols.json'))), 1)

    def test_debuglink_parser_and_supplementary_input_fail_closed(self):
        self.binary.write_bytes(fixture(debuglink=('module.debug', 123), supplementary=True))
        manager = self.manager()
        row = manager.seal_file(str(self.binary), time.monotonic() + 1)
        self.assertEqual(row['gnuDebuglink'], {'filename': 'module.debug', 'crc32': 123})
        with self.assertRaisesRegex(ContractError, 'Unsupported supplementary'):
            manager.seal_indirect_debug(time.monotonic() + 1)

    def test_indirect_missing_present_matching_and_bad_build_id(self):
        import zlib
        debug = self.root / 'module.debug'
        payload = fixture()
        debug.write_bytes(payload)
        self.binary.write_bytes(fixture(debuglink=(debug.name, zlib.crc32(payload))))
        manager = self.manager()
        manager.seal_file(str(self.binary), time.monotonic() + 2)
        manager.seal_indirect_debug(time.monotonic() + 2)
        candidates = manager.indirect_debug[str(self.binary)]
        self.assertTrue(candidates[0]['regularFile'])
        self.assertFalse(candidates[1]['regularFile'])
        self.assertEqual(candidates[0]['observedCrc32'], zlib.crc32(payload))
        debug.write_bytes(fixture(build_id='99' * 20))
        bad = self.manager()
        bad.seal_file(str(self.binary), time.monotonic() + 2)
        with self.assertRaisesRegex(ContractError, 'BuildID mismatch'):
            bad.seal_indirect_debug(time.monotonic() + 2)

    def test_direct_debug_priority_two_levels_and_availability_change(self):
        one, two = self.root / 'one.debug', self.root / 'two.debug'
        one.write_bytes(fixture())
        two.write_bytes(fixture())
        manager = self.manager()
        paths = {str(self.binary): [str(one), str(self.root / 'missing')],
                 str(one): [str(two), str(self.root / 'missing-two')]}
        with patch.object(manager, 'debug_candidates', side_effect=lambda path: paths[path]):
            levels = manager.seal_debug_selection(str(self.binary), BUILD_ID, time.monotonic() + 2)
        self.assertEqual([row['selected'] for row in levels], [str(one), str(two)])
        manager.verify_metadata()
        (self.root / 'missing').write_bytes(fixture())
        with self.assertRaisesRegex(ContractError, 'selection changed'):
            manager.verify_metadata()

    def test_analysis_bracket_verifies_before_and_after_success(self):
        from run_pair import verified_analysis
        events = []
        def verify():
            events.append('verify')
        def stage():
            events.append('stage')
            return {'returnCode': 0}
        result, record = verified_analysis(stage, verify, self.root / 'bracket.json')
        self.assertEqual(events, ['verify', 'stage', 'verify'])
        self.assertEqual(result['returnCode'], 0)
        self.assertTrue(record['afterCompleted'])

    def test_failed_stage_still_postchecks_and_preserves_first_exception(self):
        from run_pair import verified_analysis
        events = []
        original = RuntimeError('original stage failure')
        def stage():
            events.append('stage')
            raise original
        def verify():
            events.append('verify')
        with self.assertRaises(RuntimeError) as failed:
            verified_analysis(stage, verify, self.root / 'bracket.json')
        self.assertIs(failed.exception, original)
        self.assertEqual(events, ['verify', 'stage', 'verify'])
        record = json.loads((self.root / 'bracket.json').read_text())
        self.assertEqual(record['commandError'], str(original))
        self.assertTrue(record['afterCompleted'])

    def test_failed_stage_and_expired_postcheck_keep_both_failures_no_budget_reset(self):
        from run_pair import verified_analysis
        attempts = []
        original = RuntimeError('original stage failure')
        def stage():
            raise original
        def verify():
            attempts.append(1)
            if len(attempts) == 2:
                raise ContractError('original shared deadline expired')
        with self.assertRaises(RuntimeError) as failed:
            verified_analysis(stage, verify, self.root / 'bracket.json')
        self.assertIs(failed.exception, original)
        record = json.loads((self.root / 'bracket.json').read_text())
        self.assertTrue(record['afterAttempted'])
        self.assertFalse(record['afterCompleted'])
        self.assertEqual(record['commandError'], str(original))
        self.assertIn('deadline expired', record['afterError'])
        self.assertEqual(len(attempts), 2)

    def test_before_failure_prevents_command_and_post_failure_prevents_success(self):
        from run_pair import verified_analysis
        def never():
            self.fail('command must not run')
        with self.assertRaisesRegex(ContractError, 'before'):
            verified_analysis(never, lambda: (_ for _ in ()).throw(ContractError('before')), self.root / 'before.json')
        count = []
        def verify():
            count.append(1)
            if len(count) == 2:
                raise ContractError('after')
        with self.assertRaisesRegex(ContractError, 'after'):
            verified_analysis(lambda: {'returnCode': 0}, verify, self.root / 'after.json')

    def test_unsampled_malformed_function_still_rejected_by_full_scan(self):
        data = bytearray(fixture())
        shoff = struct.unpack_from('<Q', data, 40)[0]
        table_offset = struct.unpack_from('<Q', data, shoff + 4 * 64 + 24)[0]
        struct.pack_into('<I', data, table_offset + 6 * 24, 0xffffffff)
        self.binary.write_bytes(data)
        with self.assertRaisesRegex(ContractError, 'symbol name extent'):
            self.parse(())

    def test_required_symbol_evidence_exceeding_json_cap_fails_without_truncation(self):
        symbols = [('x' * 15000 + str(index), 0x1100, 16) for index in range(200)]
        self.binary.write_bytes(fixture(symbols))
        with self.assertRaisesRegex(ContractError, 'symbol JSON exceeds 4 MiB'):
            self.parse([0x1100])

    def test_indirect_debuglink_crc_mismatch_fails(self):
        debug = self.root / 'module.debug'
        debug.write_bytes(fixture())
        self.binary.write_bytes(fixture(debuglink=(debug.name, 1)))
        manager = self.manager()
        manager.seal_file(str(self.binary), time.monotonic() + 2)
        with self.assertRaisesRegex(ContractError, 'CRC mismatch'):
            manager.seal_indirect_debug(time.monotonic() + 2)

    def test_run_pair_keeps_original_paths_and_shared_deadline_in_bracket(self):
        source = Path(__file__).with_name('run_pair.py').read_text()
        self.assertIn('modules.rehash(analysis_deadline)', source)
        self.assertIn("self.pprof_tools, '--raw'", source)
        self.assertIn('str(self.target), str(sidecar / heap_name)', source)
        self.assertIn('result, verified = verified_analysis(', source)
        self.assertNotIn('/proc/self/fd/', source)


if __name__ == '__main__':
    unittest.main()
