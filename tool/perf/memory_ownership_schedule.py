#!/usr/bin/env python3
"""Derive timing only from the immutable, public 9d4 eight-cycle report.

No SDK, application, GC, network or benchmark is invoked. The output is an
idle/probe schedule, not replayed product work or a claim of timing equivalence.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile

BASE = '9d4cd5a0f9db03042a3986689fea374ba92d78b8'
ARTIFACT_ID = 11698070273
ARTIFACT_BYTES = 22561972
ARTIFACT_SHA256 = 'dd8246ab2b5c2c07c30bd08c5136a19ebefd4b0bc462ccecfea931299c031323'
REPORT_SHA256 = '8d108ddfc2edef3d4bb2c21f52275213a4aa46f0676e8776edc6b36a86bba287'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def derive(report, source):
    if (report.get('schema') != 'abc.generic-world-memory.v1'
            or report.get('workloadId') != 'generic-wld-controls-v1'
            or report.get('runtime', {}).get('commit') != BASE
            or report.get('status') != 'observed'
            or report.get('completedCycles') != 8):
        raise ValueError('The completed frozen generic 9d4 report is required')
    points = report.get('memoryPoints', [])
    expected = [('baseline', -1)] + [(p, c) for c in range(8)
                                    for p in ('after-close-retained', 'after-close-released')]
    if [(p.get('phase'), p.get('cycle')) for p in points] != expected:
        raise ValueError('Exactly the original 17 ordered probe slots are required')
    origin = points[0]['startUs']
    boundaries = report['raw']['boundaries']
    cycles = report['cycles']
    if [c.get('cycle') for c in cycles] != list(range(8)):
        raise ValueError('Eight original cycles in order are required')
    schedule = {'schema': 'abc.memory-ownership-schedule.v1', 'source': source,
                'workloadId': 'generic-wld-controls-v1', 'originTimeUs': origin,
                'plannedCycles': 8, 'plannedCheckpoints': 17, 'plannedVmProbes': 17,
                'plannedGauges': 52, 'points': [], 'cycles': [], 'quietWindows': [],
                'gaugeSchedule': [{'id': 'initialization', 'offsetUs': 0,
                                   'sourceAnchor': 'new-gauge-aligned-to-original-baseline'}],
                'drainPolicy': report['drainPolicy'],
                'interpretation': 'Timing-only idle companion; no historical product work is replayed. Product keeps full work and quiet durations; overruns are retained.'}

    def gauge(name, timestamp, anchor):
        schedule['gaugeSchedule'].append({'id': name, 'offsetUs': timestamp-origin,
                                          'sourceAnchor': anchor})

    def probe(p):
        if not p['startUs'] <= p['vmStartUs'] <= p['vmEndUs'] <= p['endUs']:
            raise ValueError('Invalid original probe interval')
        prefix = 'baseline' if p['cycle'] == -1 else f"cycle-{p['cycle']}.{p['phase']}"
        schedule['points'].append({'phase': p['phase'], 'cycle': p['cycle'],
                                  'offsetUs': p['startUs']-origin,
                                  'sourceVmDurationUs': p['vmEndUs']-p['vmStartUs'],
                                  'sourcePointDurationUs': p['endUs']-p['startUs']})
        gauge(prefix+'.before-gc', p['startUs'], 'memoryPoint.startUs')
        gauge(prefix+'.after-gc', p['endUs'], 'memoryPoint.endUs')

    probe(points[0])
    for c in range(9):
        starts = [b for b in boundaries if b['cycle'] == c and b['phase'] == 'drain-start']
        ends = [b for b in boundaries if b['cycle'] == c and b['phase'] == 'drain-end']
        if len(starts) != (2 if c < 8 else 1) or len(ends) != len(starts):
            raise ValueError('Original quiet endpoints missing or duplicated')
        if c < 8:
            cs = [b for b in boundaries if b['cycle'] == c and b['phase'] == 'cycle-start']
            ce = [b for b in boundaries if b['cycle'] == c and b['phase'] == 'cycle-disposed']
            if len(cs) != 1 or len(ce) != 1 or cs[0]['timeUs'] > ce[0]['timeUs']:
                raise ValueError('Original work slot is ambiguous')
            schedule['cycles'].append({'cycle': c, 'mode': cycles[c]['mode'],
                                       'scenario': cycles[c]['scenario'],
                                       'startOffsetUs': cs[0]['timeUs']-origin,
                                       'workloadEndOffsetUs': ce[0]['timeUs']-origin,
                                       'workloadDurationUs': ce[0]['timeUs']-cs[0]['timeUs']})
        for index, (start, end) in enumerate(zip(starts, ends)):
            if not start['timeUs'] < end['timeUs']:
                raise ValueError('Invalid quiet interval')
            phase = ('retained', 'released')[index] if c < 8 else 'final'
            name = f'cycle-{c}.{phase}-quiet-end' if c < 8 else 'final-quiet-end'
            schedule['quietWindows'].append({'id': name, 'cycle': c, 'phase': phase,
                                            'startOffsetUs': start['timeUs']-origin,
                                            'endOffsetUs': end['timeUs']-origin})
            gauge(name, end['timeUs'], 'raw.boundaries.drain-end')
            if c < 8:
                probe(points[1+c*2+index])
    gauges = schedule['gaugeSchedule']
    if len(gauges) != 52 or len({g['id'] for g in gauges}) != 52:
        raise ValueError('Exactly 52 unique gauge IDs are required')
    if any(b['offsetUs'] < a['offsetUs'] for a, b in zip(gauges, gauges[1:])):
        raise ValueError('Historical boundary order differs from the declared protocol')
    schedule['sourceDurationUs'] = gauges[-1]['offsetUs']
    return schedule


def from_archive(path):
    data = Path(path).read_bytes()
    if len(data) != ARTIFACT_BYTES or sha(data) != ARTIFACT_SHA256:
        raise ValueError('Official 9d4 artifact identity differs')
    with zipfile.ZipFile(path) as archive:
        report_bytes = archive.read('memory.json')
        if sha(report_bytes) != REPORT_SHA256:
            raise ValueError('Original report identity differs')
        report = json.loads(report_bytes)
        rows = report['raw']['frameChunks'] + report['raw']['os']['files']
        raw = {}
        for row in rows:
            name = row['file']
            if str(PurePosixPath(name)) != name or '/' in name or '\\' in name or name in raw:
                raise ValueError('Invalid raw member name')
            member = archive.getinfo('memory.raw/' + name)
            if member.file_size != row['bytes'] or member.file_size > 8*1024*1024:
                raise ValueError('Original raw member size differs')
            content = archive.read(member)
            if sha(content) != row['sha256']:
                raise ValueError('Original raw member hash differs')
            raw[name] = {'sha256': sha(content), 'bytes': len(content)}
    return derive(report, {'commit': BASE, 'runId': 38125999949,
                           'artifactId': ARTIFACT_ID, 'artifactBytes': ARTIFACT_BYTES,
                           'artifactSha256': ARTIFACT_SHA256, 'reportSha256': REPORT_SHA256,
                           'rawFiles': raw})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = from_archive(args.archive)
    with args.output.open('x') as out:
        out.write(json.dumps(result, indent=2, allow_nan=False)+'\n')
    print(json.dumps({'output': str(args.output), 'sha256': sha(args.output.read_bytes()),
                      'points': len(result['points']), 'gauges': len(result['gaugeSchedule']),
                      'sourceDurationUs': result['sourceDurationUs']}))


if __name__ == '__main__':
    main()
