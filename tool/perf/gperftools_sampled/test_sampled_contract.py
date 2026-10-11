import copy
import json
import math
from pathlib import Path
import tempfile
import unittest

from sampled_contract import (PERIOD, MAX_HEAP, parse_sample, parse_sample_bytes,
                              validate_sampled_bracket, estimate_samples)
from application_contract import ContractError

MAP = b'00001000-00002000 r-xp 00000000 00:00 1 /lib/test.so\n'
PROC = MAP.replace(b'00:00', b'08:01')

def fixture(records=((1, 64, (0x1100,)),), maps=MAP):
    count=sum(x[0] for x in records); size=sum(x[1] for x in records)
    lines=[f'heap profile: {count}: {size} [{count}: {size}] @ heap_v2/{PERIOD}']
    for n,b,stack in records:
        lines.append(f'{n}: {b} [{n}: {b}] @'+''.join(f' 0x{x:x}' for x in stack))
    return ('\n'.join(lines)+'\n\nMAPPED_LIBRARIES:\n').encode()+maps

class SampledContracts(unittest.TestCase):
    def test_distinct_schema_and_internal_counts(self):
        s=parse_sample_bytes(fixture())
        self.assertEqual(s['rawSampleHeader'], (1,64,1,64))
        self.assertNotIn('header',s);self.assertNotIn('buckets',s)
        self.assertFalse(s['fullHeapCoverage']);self.assertFalse(s['mappingIdentityValidated'])
    def test_same_stack_individual_samples_preserved_and_weighted_before_aggregate(self):
        s=parse_sample_bytes(fixture(((1,64,(0x1100,)),(1,524288,(0x1100,)))))
        self.assertEqual(len(s['sampleRecords']),2)
        e=estimate_samples(s);self.assertEqual(e['byStack'][0]['records'],2)
        expected=64/(1-math.exp(-64/PERIOD))+524288/(1-math.exp(-1))
        self.assertAlmostEqual(e['estimatedBytes'],expected,places=5)
        wrong=524352/(1-math.exp(-(524352/2)/PERIOD))
        self.assertGreater(abs(e['estimatedBytes']-wrong),1000)
    def test_known_probability_reference(self):
        e=estimate_samples(parse_sample_bytes(fixture(((1,PERIOD,(0x1100,)),))))
        self.assertAlmostEqual(e['estimatedObjects'],1.5819767068693265)
        self.assertTrue(e['estimateNotExact']);self.assertFalse(e['confidenceIntervalAvailable'])
        self.assertFalse(e['cumulativeAllocationEstimateAvailable'])
    def test_small_and_large_weights_remain_finite(self):
        for size in (1,8,64,PERIOD,32*PERIOD,2**62):
            with self.subTest(size=size):
                e=estimate_samples(parse_sample_bytes(fixture(((1,size,(0x1100,)),))))
                self.assertTrue(math.isfinite(e['estimatedBytes']))
                self.assertGreaterEqual(e['estimatedBytes'],size)
    def test_zero_sample_not_no_leak_or_full_coverage(self):
        s=parse_sample_bytes(fixture(()));self.assertEqual(s['rawSampleHeader'],(0,0,0,0))
        e=estimate_samples(s);self.assertEqual(e['estimatedBytes'],0)
        self.assertFalse(e['zeroMeansNoLeak']);self.assertFalse(e['fullHeapCoverage'])
    def test_zero_requested_size_raw_preserved_weight_explicitly_unsupported(self):
        s=parse_sample_bytes(fixture(((1,0,(0x1100,)),)))
        self.assertEqual(s['rawSampleHeader'],(1,0,1,0))
        with self.assertRaisesRegex(ContractError,'finite official'):estimate_samples(s)
    def test_full_old_v1_wrong_or_disabled_period_rejected(self):
        for kind in (b'heapprofile',b'heap_v2/0',b'heap_v2/1',b'heap_v2/1048576',b'heap/524288',b'growth'):
            with self.subTest(kind=kind),self.assertRaisesRegex(ContractError,'heap_v2'):
                parse_sample_bytes(fixture().replace(b'heap_v2/524288',kind))
    def test_no_double_weight_input_allowed(self):
        e=estimate_samples(parse_sample_bytes(fixture()))
        with self.assertRaises(ContractError):estimate_samples(e)
    def test_replicated_columns_not_cumulative(self):
        for old,new in [(b'[1: 64]',b'[2: 128]'),(b'1: 64 [1: 64] @ 0x',b'1: 64 [1: 128] @ 0x')]:
            with self.subTest(new=new),self.assertRaises(ContractError):parse_sample_bytes(fixture().replace(old,new))
    def test_incomplete_header_body_fails_all_counters(self):
        for data in (fixture().replace(b'heap profile: 1: 64 [1: 64]',b'heap profile: 2: 128 [2: 128]'),fixture()+b'junk\n'):
            with self.assertRaises(ContractError):parse_sample_bytes(data)
    def test_no_marker_only_completeness_claim(self):
        for data in (fixture().split(b'MAPPED_LIBRARIES:')[0],fixture().split(MAP)[0],fixture().replace(b'\n\nMAPPED',b'\nMAPPED'),fixture()+b'MAPPED_LIBRARIES:\n'):
            with self.assertRaises(ContractError):parse_sample_bytes(data)
    def test_truncation_nul_nonascii_and_line_limit(self):
        for data in (fixture()[:-1],fixture()+b'\0',fixture()+b'\xff',b'x'*16384+b'\n'):
            with self.assertRaises(ContractError):parse_sample_bytes(data)
    def test_original_one_mib_output_limit_retained(self):
        with self.assertRaises(ContractError):parse_sample_bytes(b'x'*MAX_HEAP)
        with self.assertRaises(ContractError):parse_sample_bytes(b'')
    def test_integer_range_negative_pc_null_depth_rejected(self):
        for data in (fixture(((1,2**63,(0x1100,)),)), fixture(((1,1,(0,)),)),fixture(((1,1,tuple(range(1,34))),)),fixture().replace(b'0x1100',b'0xfffffffffffffffff'),fixture().replace(b'1: 64',b'-1: 64')):
            with self.assertRaises(ContractError):parse_sample_bytes(data)
    def test_official_maximum_31_stack_frames(self):
        s=parse_sample_bytes(fixture(((1,64,tuple(range(1,32))),)))
        self.assertEqual(len(s['sampleRecords'][0]['stack']),31)
        with self.assertRaises(ContractError):parse_sample_bytes(fixture(((1,64,tuple(range(1,33))),)))
    def test_preaggregated_record_rejected_before_mean_size_weighting(self):
        with self.assertRaisesRegex(ContractError,'preaggregation'):
            parse_sample_bytes(fixture(((2,524352,(0x1100,)),)))
    def test_nonempty_record_cannot_claim_zero_objects(self):
        with self.assertRaises(ContractError):parse_sample_bytes(fixture(((0,0,(0x1100,)),)))
    def test_bounded_file_symlink_or_replacement_protection(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'q0.sample.heap';p.write_bytes(fixture())
            self.assertEqual(parse_sample(p)['rawSampleHeader'],(1,64,1,64))
            link=Path(t)/'link';link.symlink_to(p)
            with self.assertRaises(ContractError):parse_sample(link)
    def test_actual_pc_bracket_passes_only_stable_executable(self):
        with tempfile.TemporaryDirectory() as t:
            before=Path(t)/'before.maps';after=Path(t)/'after.maps'
            before.write_bytes(PROC);after.write_bytes(PROC)
            s=parse_sample_bytes(fixture());r=validate_sampled_bracket(s,before,after)
            self.assertTrue(r['mappingIdentityValidated']);self.assertFalse(r['fullHeapCoverage'])
            after.write_bytes(PROC.replace(b'08:01',b'08:02'))
            with self.assertRaises(ContractError):validate_sampled_bracket(s,before,after)
    def test_nonfile_pc_unknown_retained_and_not_owner(self):
        anon=b'00003000-00004000 rwxp 00000000 00:00 0\n'
        with tempfile.TemporaryDirectory() as t:
            before=Path(t)/'before.maps';after=Path(t)/'after.maps'
            before.write_bytes(PROC+anon);after.write_bytes(PROC+anon)
            s=parse_sample_bytes(fixture(((1,64,(0x3100,)),),MAP+anon))
            r=validate_sampled_bracket(s,before,after)
            self.assertEqual(r['bracket']['nonElfFrames'][0]['pc'],0x3100)
            self.assertFalse(r['fullHeapCoverage'])
    def test_unmapped_sample_pc_and_missing_necessary_pc_fail(self):
        with tempfile.TemporaryDirectory() as t:
            before=Path(t)/'before.maps';after=Path(t)/'after.maps'
            before.write_bytes(PROC);after.write_bytes(PROC)
            with self.assertRaises(ContractError):validate_sampled_bracket(parse_sample_bytes(fixture(((1,64,(0x3100,)),))),before,after)
            with self.assertRaises(ContractError):validate_sampled_bracket(parse_sample_bytes(fixture()),before,after,necessary_pcs=(0x3100,))
    def test_internally_consistent_estimates_stay_explicit_in_json(self):
        e=json.loads(json.dumps(estimate_samples(parse_sample_bytes(fixture())),allow_nan=False))
        self.assertIn('pprof-v2-reference-only',e['weighting'])
        self.assertTrue(any('glibc' in x for x in e['limitations']))

if __name__=='__main__':unittest.main()
