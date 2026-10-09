"""Small adapter for the existing verified-PID request/ack and OS observer.

No launcher is defined here. A reviewed single-process CI runner constructs
RetentionRequestProtocol with its newly launched process group's PID. Only
existing owned-process status/smaps_rollup reads are used. No map paths,
addresses, environment values, stacks or contents are recorded.
"""
import hashlib
import json
from pathlib import Path

from memory_probe_control_os import ExternalOsSampler, _memory_fields
from memory_probe_control_run import RequestProtocol

PRODUCT_COMMIT = '661f9f17531e87f0b3f9f7028d70a94814c21234'
PRODUCT_TREE = '9ff4ca286afa3e545901c498de167ee0c5dfc61d'
FIELDS = ('arena', 'ordblks', 'smblks', 'hblks', 'hblkhd', 'usmblks',
          'fsmblks', 'uordblks', 'fordblks', 'keepcost')
CATEGORY_FIELDS = ('Pss_Anon', 'Pss_File', 'Pss_Shmem', 'Anonymous', 'Swap',
                   'Private_Hugetlb')


def allocator_boundary(phase):
    return phase == 'baseline.pre' or phase.endswith('-quiet.end')


def parse_rollup_categories(text):
    values = _memory_fields(text, ('Rss', 'Pss', 'Private_Clean', 'Private_Dirty'),
                            CATEGORY_FIELDS)
    return {
        # Missing optional kernel fields stay null, including on old kernels.
        'pssAnonymousBytes': values.get('Pss_Anon'),
        'pssFileBytes': values.get('Pss_File'),
        'pssSharedMemoryBytes': values.get('Pss_Shmem'),
        'anonymousBytes': values.get('Anonymous'),
        'swapBytes': values.get('Swap'),
        'privateHugetlbBytes': values.get('Private_Hugetlb'),
        'smapsRssBytes': values['Rss'],
        'pssBytes': values['Pss'],
        'privateCleanBytes': values['Private_Clean'],
        'privateDirtyBytes': values['Private_Dirty'],
    }


class RetentionOsSampler(ExternalOsSampler):
    """Existing periodic sampler plus 18 bounded named category reads.

    The extra rollup read has its own clocks and raw journal. Never replace the
    original row with this later observation or call it an atomic snapshot.
    """
    def __init__(self, pid, expected_pgid, output_file):
        super().__init__(pid, expected_pgid, output_file)
        self.category_file = Path(output_file).with_name('native-retention-categories.jsonl')
        self._category_output = None
        self._category_count = self._category_bytes = 0
        self._category_hash = hashlib.sha256()

    def start(self):
        self._category_output = self.category_file.open('x', encoding='ascii')
        try:
            return super().start()
        except BaseException:
            self._category_output.close()
            raise

    def point(self, phase, metadata=None):
        with self._lock:
            row = super().point(phase, metadata)
            if not allocator_boundary(phase):
                return {'os': row, 'categories': None}
            try:
                if self._category_count >= 18:
                    raise ValueError('More than the predeclared 18 allocator boundaries')
                text, started, ended = self._process.read('smaps_rollup')
                category = {
                    'schema': 'abc.native-retention-categories.v1',
                    'sequence': self._category_count,
                    'externalOsSequence': row['sequence'],
                    'phase': phase, 'metadata': metadata,
                    'clockDomain': row['clockDomain'], 'atomic': False,
                    'startNs': started, 'endNs': ended,
                    **parse_rollup_categories(text),
                }
                encoded = json.dumps(category, separators=(',', ':'),
                                     allow_nan=False, ensure_ascii=True) + '\n'
                self._category_output.write(encoded)
                self._category_output.flush()
                self._category_hash.update(encoded.encode('ascii'))
                self._category_bytes += len(encoded)
                self._category_count += 1
                # The original OS row already persisted, without this field.
                # Keep it nested so exact original-row reconciliation is clear.
                return {'os': row, 'categories': category}
            except Exception as error:
                self._fail(error)
                self.check()

    @property
    def manifest(self):
        result = super().manifest
        result['retentionCategories'] = {
            'file': self.category_file.name,
            'sha256': self._category_hash.hexdigest(),
            'bytes': self._category_bytes, 'count': self._category_count,
            'complete': result['complete'] and self._category_count == 18,
            'rawAddressesOrPaths': False,
        }
        return result

    def finish(self):
        try:
            return super().finish()
        finally:
            if self._category_output is not None:
                self._category_output.close()


class RetentionRequestProtocol(RequestProtocol):
    def __init__(self, requests, acks, external_os, pgid):
        super().__init__(requests, acks, external_os, pgid, 'native-retention',
                         sampler_factory=RetentionOsSampler)

    def descriptor(self):
        result = super().descriptor()
        if result is not None:
            # The base implementation is intentionally untouched and still
            # describes its original fixed-product experiment when used there.
            result['baseProductCommit'] = PRODUCT_COMMIT
        return result


def validate_allocator_sample(value, expected_sequence):
    if not isinstance(value, dict) or value.get('schema') != 'abc.native-retention-mallinfo2.v1':
        raise ValueError('Missing allocator sample schema')
    if value.get('sequence') != expected_sequence or value.get('atomic') is not False:
        raise ValueError('Allocator sequence or atomicity mismatch')
    if value.get('clockDomain') != 'dart:developer.Timeline.now':
        raise ValueError('Allocator clock domain mismatch')
    if (type(value.get('startUs')) is not int or type(value.get('endUs')) is not int
            or not 0 <= value['startUs'] <= value['endUs']):
        raise ValueError('Invalid allocator call timing')
    fields = value.get('fields')
    if not isinstance(fields, dict) or set(fields) != set(FIELDS):
        raise ValueError('Allocator field contract mismatch')
    if value.get('status') == 'unsupported':
        if (value.get('reason') not in ('unsupported-build-headers',
                'runtime-mallinfo2-unavailable', 'allocator-symbols-interposed',
                'libc-symbol-identity-unverified')
                or any(x is not None for x in fields.values())):
            raise ValueError('Unsupported allocator data must be explicit null')
    elif value.get('status') == 'available':
        if (value.get('reason') is not None
                or value.get('sizeTBytes') not in (4, 8)
                or value.get('mallinfo2StructBytes') != 10 * value['sizeTBytes']
                or any(type(x) is not int or x < 0 for x in fields.values())):
            raise ValueError('Invalid available allocator data or ABI')
        if fields['arena'] != fields['uordblks'] + fields['fordblks']:
            raise ValueError('glibc arena accounting identity mismatch')
    else:
        raise ValueError('Unknown allocator availability status')


def validate_report_contract(report):
    """Validate the new protocol only, not frames/product/source/build integrity.

    native_retention_validate applies the inherited full evidence checks to
    the original journals and exact pinned product, without acceptance claims.
    """
    if (report.get('schema') != 'abc.native-retention.v1'
            or report.get('baseProductCommit') != PRODUCT_COMMIT
            or report.get('arm') != 'native-retention'
            or report.get('status') != 'observed'
            or report.get('plannedCycles') != 8 or report.get('completedCycles') != 8
            or report.get('plannedAllocatorBoundaries') != 18
            or report.get('plannedAllocatorCalls') != 37
            or report.get('allocatorBufferBytes') != 128
            or report.get('warmupCycles') != [0, 1, 2, 3]
            or report.get('repeatCycles') != [4, 5, 6, 7]
            or report.get('plateauEstablished') is not False
            or report.get('vmProbeCalls') != 0):
        raise ValueError('Fixed diagnostic plan mismatch')
    cycles = report.get('cycles', [])
    if len(cycles) != 8:
        raise ValueError('Exactly eight complete operation cycles required')
    for i, cycle in enumerate(cycles):
        if (cycle.get('cycle') != i or cycle.get('status') != 'completed'
                or cycle.get('mode') != ('optimized' if i % 2 else 'standard')
                or cycle.get('scenario') != ('save-reopen' if i // 2 % 2 else 'reset-original')
                or cycle.get('predeclaredRole') != ('warm-up-variant' if i < 4 else 'single-repeat-variant')):
            raise ValueError('Cycle identity or predeclared role mismatch')
    expected = [(-1, 'baseline.pre')]
    expected += [(i, phase) for i in range(8)
                 for phase in ('retained-quiet.end', 'released-quiet.end')]
    expected += [(8, 'final-quiet.end')]
    validate_allocator_sample(report.get('allocatorInitialization'), 0)
    calls = report.get('allocatorCalls')
    if not isinstance(calls, list) or len(calls) != 37:
        raise ValueError('Complete raw allocator call list required')
    for i, call in enumerate(calls):
        validate_allocator_sample(call, i)
    if calls[0] != report['allocatorInitialization']:
        raise ValueError('Initialization and raw call list disagree')
    found = []
    sequence = 1
    for endpoint in report.get('externalEndpoints', []):
        selected = allocator_boundary(endpoint.get('phase', ''))
        before, after = endpoint.get('allocatorBefore'), endpoint.get('allocatorAfter')
        if not selected:
            if before is not None or after is not None:
                raise ValueError('Unexpected allocator call outside declared boundary')
            if endpoint.get('mappingCategories') is not None:
                raise ValueError('Unexpected category read outside declared boundary')
            continue
        found.append((endpoint.get('cycle'), endpoint['phase']))
        validate_allocator_sample(before, sequence)
        validate_allocator_sample(after, sequence + 1)
        if before != calls[sequence] or after != calls[sequence + 1]:
            raise ValueError('Endpoint and raw allocator call list disagree')
        sequence += 2
        if not (before['endUs'] <= endpoint['dartTimeUs'] <= after['startUs']
                <= after['endUs'] <= endpoint['acknowledgedDartTimeUs']):
            raise ValueError('Allocator calls do not bracket external request/ack')
        category = endpoint.get('mappingCategories')
        row = endpoint.get('os', {})
        if (not isinstance(category, dict)
                or category.get('schema') != 'abc.native-retention-categories.v1'
                or category.get('sequence') != len(found) - 1
                or category.get('externalOsSequence') != row.get('sequence')
                or category.get('phase') != endpoint['phase']
                or category.get('atomic') is not False
                or category.get('clockDomain') != 'python.time.monotonic_ns'
                or type(category.get('startNs')) is not int
                or type(category.get('endNs')) is not int
                or not 0 <= category['startNs'] <= category['endNs']):
            raise ValueError('Missing or mismatched category observation')
    if found != expected or sequence != 37:
        raise ValueError('Missing, duplicated or reordered allocator boundaries')
    return {'status': 'protocol-contract-valid', 'allocatorCalls': sequence,
            'plateauEstablished': False, 'causalAttribution': 'requires-analysis'}
