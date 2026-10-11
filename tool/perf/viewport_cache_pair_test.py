"""Offline evidence-validation contracts; no engine, SDK, or benchmark run."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

import viewport_cache_pair as pair


def frame(ordinal):
    return {'physicalPulses':ordinal*128,'mechanicalTicks':ordinal*6,
        'recordsSha256':f'{ordinal:064x}','rgbaSha256':f'{ordinal+100:064x}',
        'nativeTicks':ordinal*6,'netPulses':ordinal*17,'gatesFired':ordinal*3}


def report(index, arm, count=3):
    events=[]
    for n in range(count):
        start=1000+n*100000
        events.extend([
            {'kind':'production-command-and-pixels','phase':'timed-dynamic-15s',
             'status':'completed','startUs':start,'endUs':start+100},
            {'kind':'native-command','phase':'timed-dynamic-15s','words':[2,1],
             'status':'completed','startUs':start+110,'endUs':start+(10000 if n==count-1 else 200),
             'nativeActiveBytes':1024,'nativePeakBytes':2048},
        ])
    modes=[]
    for mode in ('standard','optimized'):
        value={'mode':mode,'sessionCommandTraces':[events],
            'fixedTrace':[frame(1),frame(2)],'liveContinuation':[frame(3),frame(4)],
            'reopenedContinuation':[frame(3),frame(4)],'preSaveRgbaSha256':'pixel',
            'preSaveRamSha256':'ram','savedSha256':f'saved-{count if mode=="optimized" else 0}',
            'viewportQueryProbes':[{'label':label,'wallUs':5,'startUs':10,'endUs':15,
                'recordCount':3072,'recordsSha256':'a'*64} for label in
                ['selected-roi-cold','selected-roi-warm-1','selected-roi-warm-2']]}
        if mode=='optimized':value['dynamicFrames']=[frame(n+3) for n in range(count)]
        modes.append(value)
    return {'status':'passed','runtime':{'commit':arm*40,'hostPid':100+index,'workingTreeDirty':False},
        'preparation':{'derivedSha256':'derived'},'modeResults':modes,'operations':[{'raw':[1,900]}],
        'processRssAtCleanupBytes':4000,'processLifetimePeakRssBytes':9000}


class EvidenceChecks(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name)
        self.runs=[]
        self.payloads=[]
        for index,arm in enumerate(pair.ORDER,1):
            name=f'{index:02}-{arm}/dynamic.json'
            self.runs.append({'index':index,'arm':arm,'commit':arm*40,'status':'passed','report':name})
            self.payloads.append(report(index,arm))
        self.flush()

    def tearDown(self):self.tmp.cleanup()

    def flush(self):
        pair.write(self.root/'pair-execution.json',{'runs':self.runs})
        for row,value in zip(self.runs,self.payloads):pair.write(self.root/row['report'],value)

    def test_all_raw_outliers_retained(self):
        pair.summarize(self.root)
        result=json.loads((self.root/'pair-summary.json').read_text())
        self.assertEqual(len(result['processes']),4)
        self.assertEqual(result['processes'][0]['viewportWallUs']['raw'],[90,90,9890])
        self.assertEqual(result['processes'][0]['operations'],[{'raw':[1,900]}])
        self.assertIn('no automatic acceptance',result['performanceConclusion'])

    def test_same_ordinal_mismatch_is_rejected(self):
        self.payloads[2]['modeResults'][1]['dynamicFrames'][1]['recordsSha256']='changed'
        self.flush()
        with self.assertRaisesRegex(ValueError,'Same pulse/tick'):pair.summarize(self.root)

    def test_different_completed_counts_remain_visible(self):
        self.payloads[2]=report(3,'B',count=4)
        self.flush()
        pair.summarize(self.root)
        result=json.loads((self.root/'pair-summary.json').read_text())
        self.assertEqual(result['ordinalComparisons'][0]['unmatchedOrdinals'][2],[[768,36]])
        self.assertEqual(result['processes'][2]['dynamicBatches'],4)

    def test_dirty_or_wrong_identity_is_rejected(self):
        self.payloads[0]['runtime']['workingTreeDirty']=True
        self.flush()
        with self.assertRaisesRegex(ValueError,'misidentified'):pair.summarize(self.root)

    def test_reused_host_process_is_rejected(self):
        self.payloads[2]['runtime']['hostPid']=self.payloads[1]['runtime']['hostPid']
        self.flush()
        with self.assertRaisesRegex(ValueError,'distinct application'):pair.summarize(self.root)

    def test_reordered_or_replaced_arm_is_rejected(self):
        self.runs[1]['arm']='A'
        self.flush()
        with self.assertRaisesRegex(ValueError,'predeclared ABBA'):pair.summarize(self.root)

    def test_save_continuation_mismatch_is_rejected(self):
        self.payloads[0]['modeResults'][0]['reopenedContinuation'][0]['recordsSha256']='changed'
        self.flush()
        with self.assertRaisesRegex(ValueError,'continuation differs'):pair.summarize(self.root)

    def test_probe_bytes_must_match_across_arms(self):
        self.payloads[1]['modeResults'][0]['viewportQueryProbes'][1]['recordsSha256']='bad'
        self.flush()
        with self.assertRaisesRegex(ValueError,'Cold/warm'):pair.summarize(self.root)

    def test_duplicate_ordinals_are_rejected(self):
        with self.assertRaisesRegex(ValueError,'Duplicate'):pair.ordinal_frames([frame(1),frame(1)])


if __name__=='__main__':unittest.main()
