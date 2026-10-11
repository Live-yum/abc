"""Offline integer/unknown attribution contracts; no app or profiler launch."""
import copy
from pathlib import Path
import unittest
from attribution_coverage import summarize_coverage, verify_coverage_totals, require_engine_coverage, with_cut_presence

ENGINE = '/bundle/lib/libabc_engine.so'
APP = '/bundle/lib/libapp.so'
SYSTEM = '/usr/lib/libglib.so'


def frame(module=ENGINE, known=True, offset=32):
    return {'module': module, 'elfOffset': offset, 'functionKnown': known,
            'exactRangeSymbolCandidates': ['allocation_site'] if known else []}


def row(frames, counts=(2, 320, 3, 400), **extra):
    return {'frames': frames, 'q0': list(counts), 'q7': list(counts), **extra}


def report(rows):
    return summarize_coverage({'allStackBuckets': rows}, application_paths={ENGINE, APP}, engine_path=ENGINE)


class AttributionCoverageContracts(unittest.TestCase):
    def test_exact_engine_known_and_same_profile_totals(self):
        result = report([row([frame()])])
        self.assertEqual(result['cuts']['q0']['engine']['status'], 'exact-ranges-proven')
        self.assertEqual(result['cuts']['q0']['exclusivePartition']['allFunctionsKnown']['counters'], [2,320,3,400])
        self.assertTrue(verify_coverage_totals(result, {'header':(2,320,3,400)}, {'header':(2,320,3,400)}))
        self.assertTrue(require_engine_coverage(result))

    def test_system_unknown_preserves_byte_fraction_not_engine_failure(self):
        result = report([row([frame(SYSTEM, False)])])
        q = result['cuts']['q0']
        self.assertEqual(q['inclusiveUnknown']['unknownSystem']['liveByteFraction'], 1)
        self.assertEqual(q['engine']['status'], 'not-observed')
        self.assertTrue(require_engine_coverage(result))

    def test_mixed_unknown_partition_no_double_count(self):
        result = report([row([frame(SYSTEM,False),frame(APP,False),frame(SYSTEM,False)])])
        q=result['cuts']['q0']
        self.assertEqual(q['inclusiveUnknown']['unknownSystem']['bucketCount'],1)
        self.assertEqual(q['inclusiveUnknown']['unknownApplication']['bucketCount'],1)
        self.assertEqual(q['exclusivePartition']['unknownApplication']['counters'],[2,320,3,400])
        self.assertEqual(q['exclusivePartition']['unknownSystem']['counters'],[0,0,0,0])

    def test_nonfile_unknown_remains_explicit(self):
        result=report([row([{'pc':123,'mapping':'[anon]','functionKnown':False}])])
        self.assertEqual(result['cuts']['q0']['exclusivePartition']['unknownNonFile']['counters'],[2,320,3,400])

    def test_zero_live_historical_bucket_retained_no_false_zero_percent(self):
        result=report([row([frame(SYSTEM,False)], (0,0,7,503))])
        q=result['cuts']['q0']
        self.assertEqual(q['totalCounters'],[0,0,7,503])
        self.assertIsNone(q['inclusiveUnknown']['unknownSystem']['liveByteFraction'])
        self.assertEqual(q['inclusiveUnknown']['unknownSystem']['bucketCount'],1)

    def test_missing_cut_not_falsely_observed(self):
        r=row([frame()],q0Present=False,q7Present=True);r['q0']=[0]*4
        result=report([r])
        self.assertEqual(result['cuts']['q0']['engine']['status'],'not-observed')
        self.assertEqual(result['cuts']['q7']['engine']['status'],'exact-ranges-proven')

    def test_unresolved_engine_keeps_result_but_fails_required_coverage(self):
        result=report([row([frame(ENGINE,False,91)])])
        self.assertEqual(result['cuts']['q7']['engine']['unresolvedElfOffsets'],[91])
        self.assertEqual(result['cuts']['q7']['totalCounters'],[2,320,3,400])
        with self.assertRaisesRegex(ValueError,'Necessary engine'):
            require_engine_coverage(result)

    def test_pprof_decorative_name_cannot_prove_function(self):
        f=frame(ENGINE,False);f['officialPprofName']='allocation_site'
        with self.assertRaises(ValueError):require_engine_coverage(report([row([f])]))
        f['functionKnown']=True
        with self.assertRaisesRegex(ValueError,'exact-range'):report([row([f])])

    def test_known_flag_and_candidates_cannot_disagree(self):
        f=frame();f['functionKnown']=False
        with self.assertRaisesRegex(ValueError,'exact-range'):report([row([f])])

    def test_malformed_candidate_names_cannot_prove_function(self):
        for names in ('fake', [None], ['']):
            f=frame();f['exactRangeSymbolCandidates']=names
            with self.subTest(names=names),self.assertRaises(ValueError):report([row([f])])

    def test_malformed_all_four_counter_fields_fail(self):
        for counts in ([1,2,3],[-1,2,3,4],[True,2,3,4],[1.0,2,3,4]):
            with self.subTest(counts=counts),self.assertRaises(ValueError):report([row([frame()],counts)])

    def test_header_mismatch_fails_in_each_dimension(self):
        result=report([row([frame()])])
        for i in range(4):
            counts=[2,320,3,400];counts[i]+=1
            with self.subTest(i=i),self.assertRaises(ValueError):
                verify_coverage_totals(result,{'header':counts},{'header':(2,320,3,400)})

    def test_missing_engine_identity_empty_stack_or_invalid_offset_fail(self):
        with self.assertRaises(ValueError):summarize_coverage({'allStackBuckets':[]},application_paths={APP},engine_path=ENGINE)
        with self.assertRaises(ValueError):report([row([])])
        with self.assertRaises(ValueError):report([row([frame(offset=-1)])])

    def test_exclusive_partition_four_dimensions_exact_with_mixed_buckets(self):
        rows=[row([frame()]),row([frame(APP,False)]),row([frame(SYSTEM,False)]),
              row([{'pc':123,'functionKnown':False}],(0,0,2,50))]
        q=report(rows)['cuts']['q0']
        self.assertEqual(q['totalCounters'],[6,960,11,1250])
        self.assertEqual([sum(v['counters'][i] for v in q['exclusivePartition'].values()) for i in range(4)],q['totalCounters'])

    def test_cut_presence_keeps_frozen_endpoint_unchanged(self):
        import dependencies
        endpoints={'allStackBuckets':[{'stack':(('unknown:[anon]',123),),
                                      'frames':[{'pc':123,'functionKnown':False}],
                                      'q0':[0,0,0,0],'q7':[1,8,1,8]}]}
        first={'buckets':[],'maps':[]}
        last={'buckets':[{'stack':(123,)}],
              'maps':[{'start':100,'end':200,'permissions':'r-xp','path':'[anon]'}]}
        original=copy.deepcopy(endpoints)
        annotated=with_cut_presence(endpoints,first,last,{})
        self.assertFalse(annotated['allStackBuckets'][0]['q0Present'])
        self.assertTrue(annotated['allStackBuckets'][0]['q7Present'])
        self.assertEqual(endpoints,original)

    def test_missing_or_extra_endpoint_stack_fails_presence(self):
        import dependencies
        profile={'buckets':[{'stack':(123,)}],
                 'maps':[{'start':100,'end':200,'permissions':'r-xp','path':'[anon]'}]}
        with self.assertRaisesRegex(ValueError,'union'):
            with_cut_presence({'allStackBuckets':[]},profile,profile,{})
        with self.assertRaisesRegex(ValueError,'absent'):
            with_cut_presence({'allStackBuckets':[{'stack':(('unknown:[anon]',124),)}]},profile,profile,{})

    def test_presence_requires_unique_executable_mapping(self):
        import dependencies
        profile={'buckets':[{'stack':(123,)}],'maps':[]}
        with self.assertRaisesRegex(ValueError,'exactly one'):
            with_cut_presence({'allStackBuckets':[]},profile,profile,{})

    def test_runner_keeps_ack_and_lazy_receipts_before_symbol_failures(self):
        source=Path(__file__).with_name('run_pair.py').read_text()
        for key in ("('receipts-' + name", "('lazy-module-bindings-' + name"):
            self.assertEqual(source.count(key),1)
            self.assertLess(source.index(key),source.index('modules.prepare_symbols('))

    def test_runner_retains_coverage_before_official_analysis_and_gate_after(self):
        source=Path(__file__).with_name('run_pair.py').read_text()
        self.assertLess(source.index("('coverage-' + name"),source.index("f'pprof-{name}-{cut}-{mode}'"))
        self.assertLess(source.index("('analysis-' + name"),source.index('require_engine_coverage(coverage)'))
        self.assertIn("'pathFdBindingAtomic': False",source)

if __name__ == '__main__':unittest.main()
