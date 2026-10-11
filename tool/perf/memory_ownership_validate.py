#!/usr/bin/env python3
"""Fail-closed validation of the separately identified owner diagnostic.

This is an evidence-integrity validator, never a leak/stability acceptance test.
The original counter-OFF validator keeps its default policy. This subclass
changes only the named diagnostic policy and reuses every generic workload,
frame, lifecycle, OS and recorder check for the product arm.

All fixtures in the companion test are fabricated contract data, not measured
memory evidence. Missing optional observations are explicit inconclusive data.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys

import computer_memory_validate as original
from computer_memory_validate import digest, integer, require, sha

BASE_COMMIT = '9d4cd5a0f9db03042a3986689fea374ba92d78b8'
REPORT_SCHEMA = 'abc.memory-ownership.v1'
VALIDATION_SCHEMA = 'abc.memory-ownership-validation.v1'
ARMS = ('probe-only', 'product-with-ownership')
CLOCK = 'dart:developer.Timeline.now'
SCHEDULE_SHA256 = 'fd5b0ca2ab01d96923512d6574ffc49c7318ebe1e23e315215251b70669ef5e0'
LIBC_HELPER_SOURCE_SHA256 = 'cdedeb679d128bee9c513f2cd0ad92f2941ab74a705d67f9d99b9dc4b8906c03'
UINT32_MAX = 2 ** 32 - 1
# Verified 9d4 report SHA-256 8d108ddfc2edef3d4bb2c21f52275213a4aa46f0676e8776edc6b36a86bba287.
FIXED_REGION = {'x': 1688, 'y': 258, 'width': 32, 'height': 32}
FIXED_TRIGGER = {'x': 1704, 'y': 274, 'mask': 15, 'direct': True}
POINT_KEYS = [(-1, 'baseline')] + [(cycle, phase) for cycle in range(8)
              for phase in ('after-close-retained', 'after-close-released')]
NATIVE_FIELDS = ('nativeTotalLiveBytes', 'nativeLiveBytes', 'nativeBridgeLiveBytes',
                 'nativeAllocatorPeakBytes', 'nativeWorldOpenCount',
                 'nativeStreamTaskPresent', 'nativeCheckpointActive',
                 'nativeCircuitSessionCount', 'nativeCircuitVmCount')
HOST_FIELDS = ('hostSessionCount', 'hostClosingSessions', 'hostWorldHandles',
               'hostCircuitHandles', 'hostOpenFiles', 'hostOutputLeases',
               'ffiHashWindowOutstandingBytes', 'ffiReadWindowOutstandingBytes')
HOST_FIELDS += tuple(f'ffi{kind}Window{suffix}' for kind in ('Hash', 'Read')
                     for suffix in ('AllocatedBytes', 'FreedBytes', 'CleanupFailures', 'AccountingCertain'))
HOST_FIELDS += ('startUs', 'endUs')
MALLINFO_FIELDS = ('arena', 'ordblks', 'smblks', 'hblks', 'hblkhd', 'usmblks',
                  'fsmblks', 'uordblks', 'fordblks', 'keepcost')
IMAGE_FIELDS = {'installedUs', 'createdHandles', 'disposedHandles',
                'observedHandleBalance', 'peakObservedHandleBalance', 'active',
                'callbacksIntact', 'priorCallbackFailures', 'stoppedUs',
                'everReplaced', 'preInstallationHandlesUnknown'}
WRAPPER_FIELDS = {'present', 'recordsLength', 'worldLength', 'objectsLength',
                  'statsLength', 'worldSourcePresent', 'sourceTokenPresent'}
PROFILE_FIELDS = {'startUs', 'endUs', 'gcRequested', 'classCount',
                  'dateLastServiceGC', 'profileReportedHeapUsage',
                  'profileReportedHeapCapacity', 'profileReportedExternalUsage'}
TELEMETRY_FIELDS = {'measurementStartUs', 'measurementEndUs', 'responseMessages',
                    'responseWireUtf8Bytes', 'largestResponseWireUtf8Bytes',
                    'responseScope', 'allocationProfiles', 'retainedResponseBodies',
                    'gcGuarantee'}


def exact_keys(value, expected, label):
    require(isinstance(value, dict) and set(value) == set(expected),
            f'{label}: missing or unexpected fields (scalar/privacy contract)')


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f'duplicate JSON key: {key}')
            result[key] = value
        return result
    value = json.loads(text, object_pairs_hook=pairs,
                       parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
    require(isinstance(value, dict), 'JSON object required')
    return value


def load_json(path):
    return strict_json(Path(path).read_bytes())


def span(value, start='startUs', end='endUs'):
    a, b = integer(value[start], start), integer(value[end], end)
    require(a <= b, f'{start}/{end}: reversed timestamp interval')
    return a, b


def gauge_plan():
    rows = [('initialization', -1, 'initialization'),
            ('baseline.before-gc', -1, 'baseline.before-gc'),
            ('baseline.after-gc', -1, 'baseline.after-gc')]
    for cycle in range(8):
        for phase in ('retained-quiet-end', 'after-close-retained.before-gc',
                      'after-close-retained.after-gc', 'released-quiet-end',
                      'after-close-released.before-gc', 'after-close-released.after-gc'):
            rows.append((f'cycle-{cycle}.{phase}', cycle, phase))
    return rows + [('final-quiet-end', 8, 'final-quiet-end')]


def validate_native(native):
    exact_keys(native, {'status', 'abiVersion', 'wordCount', 'censoredMask', 'values',
                        'observerBufferBytes', 'startUs', 'endUs', 'rawWords'}, 'native snapshot')
    span(native)
    require(native['status'] == 'available' and native['abiVersion'] == 1
            and native['wordCount'] == 16 and native['observerBufferBytes'] == 128,
            'required native owner ABI/symbols unavailable or incompatible')
    for field in ('abiVersion', 'wordCount', 'censoredMask', 'observerBufferBytes'):
        integer(native[field], field)
    words = native['rawWords']
    require(isinstance(words, list) and len(words) == 16, 'native raw ABI word count differs')
    for value in words:
        require(type(value) is int and 0 <= value < 2 ** 64, 'native raw ABI word invalid')
    require(words[:2] == [1, 16] and words[12:] == [0] * 4, 'native ABI/reserved words differ')
    require(all(value <= UINT32_MAX for value in words[2:11]), 'native uint32 metric overflow')
    mask = sum(1 << i for i, value in enumerate(words[2:6]) if value == UINT32_MAX)
    require(words[11] == native['censoredMask'] == mask, 'native saturation/censored mask differs')
    exact_keys(native['values'], NATIVE_FIELDS, 'native values')
    for field in NATIVE_FIELDS:
        integer(native['values'][field], field)
    require([native['values'][field] for field in NATIVE_FIELDS] == words[2:11],
            'native named metrics disagree with raw ABI words')
    total, current, bridge, peak, world, stream, checkpoint, sessions, vms = words[2:11]
    if not mask & 7:
        require(total == current + bridge, 'native live-byte components disagree')
    require(peak >= total and stream in (0, 1) and checkpoint in (0, 1)
            and 0 <= vms <= sessions <= 4, 'native owner invariants invalid')
    return mask != 0


def validate_allocator(row, sequence):
    exact_keys(row, {'schema', 'sequence', 'status', 'reason', 'startUs', 'endUs',
                     'clockDomain', 'atomic', 'sizeTBytes', 'mallinfo2StructBytes',
                     'glibcVersion', 'fields', 'observerWireBufferBytes'}, 'allocator observation')
    require(row['schema'] == 'abc.native-retention-mallinfo2.v1' and row['sequence'] == sequence
            and row['clockDomain'] == CLOCK and row['atomic'] is False,
            'allocator identity/sequence/atomicity differs')
    require(row['observerWireBufferBytes'] == 52 * 128, 'allocator observer fixed buffer differs')
    span(row)
    exact_keys(row['fields'], MALLINFO_FIELDS, 'allocator fields')
    require(type(row['sizeTBytes']) is int and row['sizeTBytes'] in (4, 8), 'allocator size_t invalid')
    if row['status'] == 'unsupported':
        require(row['reason'] in ('unsupported-build-headers', 'runtime-mallinfo2-unavailable',
                                 'allocator-symbols-interposed', 'libc-symbol-identity-unverified')
                and all(value is None for value in row['fields'].values()),
                'unsupported allocator data must remain null with a controlled reason')
        require(row['mallinfo2StructBytes'] in (None, 10 * row['sizeTBytes']),
                'unsupported allocator struct identity invalid')
        return True
    require(row['status'] == 'available' and row['reason'] is None,
            'unknown allocator status or unexpected failure')
    require(row['mallinfo2StructBytes'] == 10 * row['sizeTBytes']
            and isinstance(row['glibcVersion'], str)
            and re.fullmatch(r'[0-9]+\.[0-9]+', row['glibcVersion']), 'allocator ABI/libc identity invalid')
    for field, value in row['fields'].items():
        require(integer(value, field) < 2 ** (8 * row['sizeTBytes']), 'allocator field exceeds size_t')
    return False


def validate_images(images, previous=None):
    exact_keys(images, IMAGE_FIELDS, 'image observer')
    for key in IMAGE_FIELDS - {'active', 'callbacksIntact', 'stoppedUs', 'everReplaced',
                              'preInstallationHandlesUnknown', 'observedHandleBalance'}:
        integer(images[key], key)
    # Disposals of handles created before installation can make this delta negative.
    require(type(images['observedHandleBalance']) is int, 'observedHandleBalance: signed integer required')
    require(images['active'] is True and images['callbacksIntact'] is True
            and images['priorCallbackFailures'] == 0 and images['stoppedUs'] is None
            and images['everReplaced'] is False and images['preInstallationHandlesUnknown'] is True,
            'required image callbacks incomplete or failed')
    require(images['createdHandles'] - images['disposedHandles'] == images['observedHandleBalance']
            and images['peakObservedHandleBalance'] >= images['observedHandleBalance'],
            'image handle balance is inconsistent')
    if previous is not None:
        require(images['installedUs'] == previous['installedUs'], 'image observer reinstalled')
        require(all(images[key] >= previous[key] for key in
                    ('createdHandles', 'disposedHandles', 'peakObservedHandleBalance')),
                'image cumulative counts moved backwards')


def validate_wrapper(wrapper):
    exact_keys(wrapper, WRAPPER_FIELDS, 'wrapper')
    for field in ('present', 'worldSourcePresent', 'sourceTokenPresent'):
        require(type(wrapper[field]) is bool, 'wrapper presence must be Boolean')
    for field in ('recordsLength', 'worldLength', 'objectsLength', 'statsLength'):
        integer(wrapper[field], field)
    if not wrapper['present']:
        require(not wrapper['worldSourcePresent'] and not wrapper['sourceTokenPresent']
                and all(wrapper[field] == 0 for field in
                        ('recordsLength', 'worldLength', 'objectsLength', 'statsLength')),
                'absent wrapper has retained result fields')


def validate_fd(row, host_pid):
    exact_keys(row, {'status', 'hostPid', 'startUs', 'enumerationEndUs', 'classificationStartUs',
                     'endUs', 'fdEntriesEnumerated', 'categories', 'vanished', 'unreadable',
                     'ignoredNonnumeric', 'atomic', 'probeDescriptorMayBeIncluded',
                     'maximumEntries', 'errorKind', 'errorCode'}, 'FD observation')
    a, b = span(row)
    require(row['hostPid'] == host_pid and row['atomic'] is False
            and row['probeDescriptorMayBeIncluded'] is True and row['maximumEntries'] == 4096,
            'FD owned-PID/observer/ceiling contract differs')
    if row['status'] == 'unsupported':
        require(row['errorKind'] == 'platform' and row['errorCode'] is None
                and all(row[name] is None for name in ('enumerationEndUs', 'classificationStartUs',
                    'fdEntriesEnumerated', 'categories', 'vanished', 'unreadable', 'ignoredNonnumeric')),
                'unsupported FD values must remain null with explicit reason')
        return True
    require(row['status'] == 'observed', 'FD incomplete/ceiling failure cannot pass a complete arm')
    require(row['errorKind'] is None and row['errorCode'] is None, 'FD error concealed by observed status')
    enum_end = integer(row['enumerationEndUs'], 'FD enumeration end')
    class_start = integer(row['classificationStartUs'], 'FD classification start')
    require(a <= enum_end <= class_start <= b, 'FD enumeration/classification timestamp order invalid')
    exact_keys(row['categories'], {'socket', 'pipe', 'anonymous-inode', 'path-like', 'other'}, 'FD categories')
    count = integer(row['fdEntriesEnumerated'], 'enumerated FD count')
    require(count + integer(row['ignoredNonnumeric'], 'ignored FD entries') <= 4096,
            'FD enumeration ceiling exceeded')
    total = sum(integer(value, 'FD category count') for value in row['categories'].values())
    require(total + integer(row['vanished'], 'vanished FDs') + integer(row['unreadable'], 'unreadable FDs') == count
            and row['unreadable'] == 0, 'FD raw enumeration/category counts do not reconcile')
    return False


def validate_telemetry(point):
    telemetry, vm = point['probeTelemetry'], point['vm']
    exact_keys(telemetry, TELEMETRY_FIELDS, 'VM scalar telemetry')
    start, end = span(telemetry, 'measurementStartUs', 'measurementEndUs')
    require(point['vmStartUs'] <= start <= end <= point['vmEndUs'], 'VM telemetry outside original slot')
    messages = integer(telemetry['responseMessages'], 'VM response messages', 1)
    size = integer(telemetry['responseWireUtf8Bytes'], 'VM response bytes', 1)
    largest = integer(telemetry['largestResponseWireUtf8Bytes'], 'largest VM response', 1)
    require(largest <= size and messages <= size, 'VM transport byte totals inconsistent')
    require(telemetry['responseScope'] == 'all VM-service responses during this checkpoint'
            and type(telemetry['retainedResponseBodies']) is int and telemetry['retainedResponseBodies'] == 0
            and telemetry['gcGuarantee'] == 'request-only; dateLastServiceGC is recorded when available',
            'VM bodies retained or GC guarantee overstated')
    profiles = telemetry['allocationProfiles']
    require(isinstance(profiles, list) and vm['sampledIsolateGroups'] <= len(profiles)
            <= vm['sampledIsolateGroups'] + vm['exitedIsolateGroupsDuringProbe']
            and len(profiles) <= messages,
            'allocation-profile calls do not reconcile to live/exited isolate groups')
    previous = start
    for profile in profiles:
        exact_keys(profile, PROFILE_FIELDS, 'allocation profile scalar metadata')
        a, b = span(profile)
        require(previous <= a <= b <= end, 'duplicate/overlapping/out-of-slot allocation-profile call')
        previous = b
        require(profile['gcRequested'] is True, 'allocation-profile GC request missing')
        for field in PROFILE_FIELDS - {'startUs', 'endUs', 'gcRequested'}:
            if profile[field] is not None:
                integer(profile[field], field)


def validate_allocator_build(provenance, execution):
    """Build-process libc identity stays separate from measured Dart support."""
    build = provenance['allocatorBuild']
    # This is the exact byte format used by the fixed helper-build producer.
    payload = (json.dumps(build, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()
    require(hashlib.sha256(payload).hexdigest() == sha(provenance['allocatorBuildSha256'])
            == execution['allocatorBuildSha256'], 'allocator build file/embedded object digest differs')
    require(build['schema'] == 'abc.native-retention-helper-build.v1' and build['status'] == 'built'
            and build['outsideApplicationCheckout'] is True and build['applicationLaunched'] is False
            and build['downloadedDependencies'] is False, 'allocator helper build was not the isolated declared build')
    require(build['source']['sha256'] == LIBC_HELPER_SOURCE_SHA256
            and build['helperSha256'] == provenance['allocatorHelperSha256'], 'allocator helper source/binary digest differs')
    integer(build['helperBytes'], 'allocator helper bytes', 1)
    compiler = build['compiler']
    sha(compiler['sha256'])
    require(bool(compiler['version']) and bool(compiler['target']), 'compiler version/target metadata missing')
    headers = build['headers']
    require(isinstance(headers, dict) and headers, 'actual compiler header dependency inventory missing')
    for header in headers.values():
        sha(header['sha256'])
        integer(header['bytes'], 'header bytes', 1)
    malloc = build['mallocHeader']
    require([name for name in headers if Path(name).name == 'malloc.h'] == [malloc['path']]
            and {key: malloc[key] for key in ('sha256', 'bytes')} == headers[malloc['path']],
            'official malloc.h identity differs from actual compiler dependencies')
    sha(build['dependencySha256'])
    for name in ('sourceSha256', 'executableSha256'):
        sha(build['buildContract'][name])
    runtime = build['runtime']
    require(runtime['scope'] == 'fresh-native-build-contract-process-only',
            'native ABI preflight cannot impersonate Dart-process allocator support')
    sha(runtime['libcSha256'])
    require(isinstance(runtime['runtimeLibcVersion'], str)
            and re.fullmatch(r'[0-9]+\.[0-9]+', runtime['runtimeLibcVersion']), 'runtime libc version missing')
    for field in ('headerGlibcMajor', 'headerGlibcMinor', 'sizeTBytes', 'mallinfo2StructBytes', 'helperStatus'):
        integer(runtime[field], field)
    require(runtime['sizeTBytes'] in (4, 8) and runtime['helperStatus'] in range(5)
            and runtime['mallinfo2StructBytes'] in (0, runtime['sizeTBytes'] * 10), 'build libc ABI invalid')
    require(runtime['abiContractMatched'] is True if runtime['helperStatus'] == 0
            else runtime['abiContractMatched'] is None, 'fresh C ABI result inconsistent with support')
    reviewed = runtime['runtimeLibcVersion'] in ('2.39', '2.41')
    require(runtime['inspectedUpstreamFamily'] is reviewed and runtime['sourceReviewRequired'] is (not reviewed),
            'libc source review status falsely promoted')
    incomplete = ['libc-source-family-unreviewed'] if not reviewed else []
    for name, package in (('compiler', compiler['package']), ('headers', malloc['package']),
                          ('runtime-libc', runtime['package'])):
        require(package['status'] in ('available', 'unavailable'), 'unknown package identity availability')
        if package['status'] == 'available':
            require(isinstance(package['packages'], list) and package['packages'] and package['metadata']
                    and package['queryReturnCode'] == 0, 'available package/source identity is empty or failed')
        else:
            require(package.get('reason') or package.get('queryReturnCode') != 0,
                    'missing package identity needs explicit reason')
            incomplete.append(f'libc-build-{name}-package-unavailable')
    return incomplete


def validate_execution(execution, report, build, expected_commit, build_sha256,
                       schedule_sha256, report_sha256):
    require(execution['schema'] == 'abc.memory-ownership-execution.v1'
            and execution['arm'] == report['arm'] and execution['status'] == 'completed'
            and type(execution['exitCode']) is int and execution['exitCode'] == 0
            and integer(execution['processInvocations'], 'process invocations') == 1
            and execution['ownedProcess'] is True, 'arm execution incomplete, rerun or wrong process')
    require(execution['sourceCommit'] == expected_commit
            and execution['buildSha256'] == sha(build_sha256)
            and execution['scheduleSha256'] == sha(schedule_sha256)
            and execution['reportSha256'] == sha(report_sha256), 'execution source/build/report/schedule identity differs')
    identity = execution['processIdentity']
    for field in ('pid', 'starttimeTicks', 'processGroupId', 'groupLeaderStarttimeTicks',
                  'runnerPid', 'runnerStarttimeTicks'):
        integer(identity[field], field, 1)
    integer(identity['uid'], 'process UID')
    require(identity['pid'] == report['hostPid'] and identity['pid'] != identity['runnerPid']
            and identity['processGroupId'] != identity['runnerPid'], 'process is not distinct runner-owned PID/group')
    require(identity['runnerStarttimeTicks'] <= identity['groupLeaderStarttimeTicks'] <= identity['starttimeTicks'],
            'process start identity predates its owning runner/group')
    start, end = span(execution, 'launchedMonotonicNs', 'exitedMonotonicNs')
    require(end - start <= 900_000_000_000, 'arm hard 900-second limit exceeded')
    hello = integer(execution['helloMonotonicNs'], 'owned hello time')
    gate_time = integer(execution['identityGatePassedMonotonicNs'], 'identity release time')
    require(execution['identityGatePassed'] is True and execution['measurementReleased'] is True
            and start <= hello <= gate_time <= end, 'measurement began without verified owned-process binary release')
    require(execution['timeoutSeconds'] == 900 and execution['runtimeTimeoutSeconds'] == 600
            and execution['buildHelloTimeoutSeconds'] == 300, 'predeclared arm timeout budgets differ')
    require(execution['symbols'] == {'perfAbi': 1, 'ownerAbi': 1, 'requiredSymbolsVerified': True},
            'required native symbol/ABI preflight missing')
    for field in ('perfAbi', 'ownerAbi'):
        integer(execution['symbols'][field], field)
    require(execution['binarySha256'] == build['artifacts']['terraforge']['sha256'],
            'executed binary digest differs from build artifact')
    require(sha(execution['loadedExecutableSha256']) == build['artifacts']['terraforge']['sha256']
            and integer(execution['loadedExecutableBytes'], 'loaded executable bytes', 1)
            == build['artifacts']['terraforge']['bytes'],
            'actual owned child executable differs from archived build')
    sha(execution['sourceProvenanceSha256'])
    require(execution['nativeEngineSha256'] == build['artifacts']['libabc_engine.so']['sha256'],
            'native engine digest differs from build artifact')
    sha(execution['allocatorHelperSha256'])
    provenance = build['ownershipProvenance']
    exact_keys(provenance, {'baseProductCommit', 'sourceProvenanceSha256', 'allocatorHelperSha256',
                            'ownerAbi', 'perfAbi', 'allocatorBuild', 'allocatorBuildSha256'}, 'owner build provenance')
    require(provenance['baseProductCommit'] == BASE_COMMIT
            and provenance['sourceProvenanceSha256'] == execution['sourceProvenanceSha256']
            and provenance['allocatorHelperSha256'] == execution['allocatorHelperSha256']
            and provenance['ownerAbi'] == provenance['perfAbi'] == 1,
            'build/source-overlay/helper provenance differs')
    integer(provenance['ownerAbi'], 'provenance owner ABI')
    integer(provenance['perfAbi'], 'provenance perf ABI')
    binaries = execution['binaries']
    helper = provenance['allocatorBuild']
    exact_keys(binaries, {'terraforge', 'libapp.so', 'libabc_engine.so', 'libabc_native_owner_libc.so'},
               'archived execution binaries')
    for name in ('terraforge', 'libapp.so', 'libabc_engine.so'):
        require(binaries[name] == build['artifacts'][name], 'archived binary bytes/hash differ from measured build')
    require(binaries['libabc_native_owner_libc.so'] == {'sha256': provenance['allocatorHelperSha256'],
                                                      'bytes': helper['helperBytes']},
            'archived helper bytes/hash differ from compiler provenance')
    gate = report['startupIdentityGate']
    exact_keys(gate, {'schema', 'arm', 'hostPid', 'sourceCommit', 'baseProductCommit', 'buildSha256', 'readyReceivedUs'},
               'startup binary identity acknowledgement')
    require({key: gate[key] for key in gate if key != 'readyReceivedUs'} == {
                'schema': 'abc.memory-ownership-ready.v1', 'arm': report['arm'], 'hostPid': report['hostPid'],
                'sourceCommit': expected_commit, 'baseProductCommit': BASE_COMMIT, 'buildSha256': build_sha256},
            'Dart startup acknowledgement differs from runner-owned build release')
    received = integer(gate['readyReceivedUs'], 'Dart READY reception')
    require(report['allocatorInitialization']['endUs'] <= received <= report['ownershipGauges'][0]['startUs'],
            'initial gauge preceded startup identity acknowledgement')
    return identity


class OwnershipValidator(original.Validator):
    accepted_report_schemas = (REPORT_SCHEMA,)

    def guard(self, label, function):
        def checked():
            try:
                return function()
            except StopIteration:
                raise ValueError('required source boundary or VM slot missing') from None
        return super().guard(label, checked)

    def __init__(self, report, raw_directory, build, expected_commit, build_sha256,
                 execution, schedule, schedule_sha256, report_sha256):
        super().__init__(report, raw_directory, build, expected_commit, build_sha256)
        self.generic = True
        self.world_sha = (report.get('fixture') or {}).get('wldSha256')
        self.world_bytes = (report.get('fixture') or {}).get('wldBytes')
        self.arm = report.get('arm')
        self.execution, self.schedule = execution, schedule
        self.schedule_sha256, self.report_sha256 = schedule_sha256, report_sha256
        self.inconclusive = []
        self.worker_identity = None
        self.owner_peak = -1
        self.previous_host = None
        self.gauge_bytes = []

    def validate_counter_build_mode(self):
        for flag in ('ABC_PERF_COUNTERS', 'ABC_OWNER_DIAGNOSTICS'):
            require(str(self.build['cmake'][flag]).upper() in ('ON', 'TRUE', '1'),
                    f'{flag} must be explicitly enabled for this distinct diagnostic')

    def validate_point_owner_state(self, point, retained):
        require(point['wrapperLatestRetained'] is (retained and self.arm == ARMS[1]),
                'arm wrapper retained/released state differs')
        require(point['nativeCounters'] == {'status': 'recorded-in-owner-gauges',
                'gaugeBeforeId': point['gaugeBeforeId'], 'gaugeAfterId': point['gaugeAfterId'],
                'values': None}, 'point native counters must reference the actual owner gauges')

    def validate_header(self):
        require(not self.root.is_symlink(), 'raw directory cannot be a symbolic link')
        allowed = {'schema', 'workloadId', 'status', 'arm', 'hostPid', 'baseProductCommit',
                   'buildMode', 'inputFormat', 'circuitAbi', 'plannedCycles', 'completedCycles',
                   'ticksPerCycle', 'excludedWarmupCycles', 'plannedCheckpoints', 'vmProbeCalls',
                   'plannedOwnershipGauges', 'expectedNativeWorkers', 'inProcessOsSamplerRetained',
                   'externalOsSamplerEnabled', 'fixture', 'runtime', 'scheduleSha256', 'scheduleOriginUs',
                   'scheduleObservations', 'memoryPoints', 'ownershipGauges', 'imageObserverSummary',
                   'cycles', 'raw', 'drainPolicy', 'failure', 'failureStack', 'limits',
                   'ownershipGaugeWrites', 'allocatorInitialization', 'startupIdentityGate'}
        require(set(self.report) <= allowed, 'unexpected report payload outside scalar diagnostic contract')
        exact_keys(self.report['raw'], {'directory', 'frameChunks', 'os', 'boundaries', 'finalCounts',
                                       'recordingStoppedUs', 'ownershipGauges', 'allocatorCaptures'}, 'raw inventory')
        if self.arm == ARMS[1]:
            super().validate_header()
            require(self.report['fixture'] == {'sourceRevision': original.SOURCE_REVISION,
                    'wldBytes': original.WLD_BYTES, 'wldSha256': original.WLD_SHA},
                    'owner diagnostic fixed public WLD identity differs')
        else:
            report = self.report
            require(report['schema'] == REPORT_SCHEMA and self.arm == ARMS[0], 'wrong ownership schema/arm')
            require(report['status'] == 'observed' and report.get('failure') is None
                    and report.get('failureStack') is None, 'failed/partial ownership run cannot pass')
            require(report['inputFormat'] == 'none' and report['buildMode'] == 'profile',
                    'probe-only must be real profile with no product input')
            require(report['fixture'] is None and report['ticksPerCycle'] == 0
                    and report['excludedWarmupCycles'] == 0 and report['circuitAbi'] == 2,
                    'probe-only includes product fixture/ticks or wrong runtime ABI')
            require(report['plannedCycles'] == report['completedCycles'] == 8, 'eight idle cycles required')
            require(self.root.is_dir() and report['raw']['directory'] == self.root.name,
                    'raw directory missing or wrong arm')
            require(report['drainPolicy'] == self.schedule['drainPolicy'], 'probe drain policy differs')
        require(self.report['baseProductCommit'] == BASE_COMMIT
                and self.expected_commit != BASE_COMMIT, 'ownership needs a separately identified derived source')
        for field in ('plannedCycles', 'completedCycles', 'ticksPerCycle', 'excludedWarmupCycles',
                      'plannedCheckpoints', 'vmProbeCalls', 'plannedOwnershipGauges', 'expectedNativeWorkers', 'circuitAbi'):
            integer(self.report[field], field)
        require(self.report['workloadId'] == original.GENERIC_WORKLOAD, 'wrong owner diagnostic workload')
        require(self.report['plannedCheckpoints'] == len(self.report['memoryPoints']) == 17
                and self.report['vmProbeCalls'] == 17, 'exactly 17 original VM probe slots required')
        require(self.report['plannedOwnershipGauges'] == 52
                and self.report['expectedNativeWorkers'] == (0 if self.arm == ARMS[0] else 1)
                and self.report['inProcessOsSamplerRetained'] is True
                and self.report['externalOsSamplerEnabled'] is False,
                'owner observer budget/topology differs')
        integer(self.report['hostPid'], 'host PID', 1)

    def validate_provenance(self):
        super().validate_provenance()
        require(self.report['scheduleSha256'] == sha(self.schedule_sha256), 'report schedule digest differs')
        files = self.build['sourceFilesSha256']
        require(files['tool/perf/memory_ownership_schedule.json'] == self.schedule_sha256,
                'build schedule digest differs')
        required = {'integration_test/computer_memory_ownership_test.dart',
                    'tool/perf/memory_ownership_validate.py', 'tool/perf/memory_ownership_run.py'}
        require(required <= set(files), 'ownership diagnostic source hashes missing')
        targets = self.build['actualOwnerCompilationTargets']
        require(set(targets) == {'abc_owner_diagnostics.c.o', 'abc_perf.c.o',
                                'terra_circuit_world.c.o', 'terra_circuit_vm.c.o'},
                'actual owner/perf compilation targets missing')
        for name, row in targets.items():
            require('-O3' in row['FLAGS'].split() and '-DNDEBUG' in row['FLAGS'].split(),
                    'actual owner build optimization flags differ')
            if name != 'terra_circuit_vm.c.o':
                require('-DABC_OWNER_DIAGNOSTICS=1' in row['DEFINES'].split(),
                        'owner macro missing on compiled native target')
        self.inconclusive.extend(validate_allocator_build(self.build['ownershipProvenance'], self.execution))

    def scan_file(self, descriptor, consume):
        """Same streaming contract with duplicate JSON keys rejected as well."""
        name = descriptor['file']
        require(isinstance(name, str) and Path(name).name == name and name.endswith('.jsonl'),
                'unsafe raw file path')
        path = self.root / name
        require(path.is_file() and not path.is_symlink() and path.resolve().parent == self.root.resolve(),
                'missing or unsafe raw file')
        require(name not in self.files, 'duplicate raw file')
        integer(descriptor['bytes'], 'raw file byte count', 1)
        if 'sampleCount' in descriptor:
            integer(descriptor['sampleCount'], 'raw file sample count', 1)
        self.files.append(name)
        hasher, size, count = hashlib.sha256(), 0, 0
        with path.open('rb') as stream:
            for line in stream:
                hasher.update(line)
                size += len(line)
                count += 1
                require(line.endswith(b'\n'), 'incomplete JSONL final line')
                self.last_raw_line_bytes = len(line)
                consume(strict_json(line), count)
        require(count > 0 and size == descriptor['bytes'] and hasher.hexdigest() == sha(descriptor['sha256']),
                'raw bytes/SHA-256 mismatch or empty file')
        return hasher.hexdigest(), size

    def validate_boundaries(self):
        if self.arm == ARMS[1]:
            return super().validate_boundaries()
        expected = [(cycle, phase) for cycle in range(8) for phase in (
            'cycle-start', 'cycle-disposed', 'drain-start', 'drain-end', 'retained-point',
            'released-prefix', 'drain-start', 'drain-end', 'released-point', 'cycle-end')]
        expected += [(8, 'drain-start'), (8, 'drain-end')]
        require([(row['cycle'], row['phase']) for row in self.boundaries] == expected,
                'probe-only boundary order differs or contains product work')
        prior, quiet = (-1, -1, -1), None
        final = self.report['raw']['finalCounts']
        for row in self.boundaries:
            current = tuple(integer(row[key], key) for key in ('timeUs', 'receivedFrames', 'receivedBatches'))
            require(all(a <= b for a, b in zip(prior, current)), 'probe boundary clock/counts reversed')
            require(current[1] <= final['receivedFrames'] and current[2] <= final['receivedBatches'],
                    'probe boundary reception totals differ')
            prior = current
            if row['phase'] == 'drain-start':
                require(quiet is None, 'overlapping quiet intervals')
                quiet = row['timeUs']
            elif row['phase'] == 'drain-end':
                require(quiet is not None and row['timeUs'] - quiet >= 1_200_000, 'short real quiet interval')
                quiet = None
        require(quiet is None and self.report['raw']['recordingStoppedUs'] >= prior[0], 'unfinished quiet/capture')
        for cycle in range(8):
            rows = [row for row in self.boundaries if row['cycle'] == cycle]
            self.cycle_bounds[cycle] = rows[0], rows[-1]

    def validate_cycle(self, row, cycle):
        integer(row['cycle'], 'cycle index')
        if self.arm == ARMS[1]:
            super().validate_cycle(row, cycle)
            require(row['worldWidth'] == 15200 and row['worldHeight'] == 7200
                    and row['displayRegion'] == FIXED_REGION and row['trigger'] == FIXED_TRIGGER,
                    'fixed 9d4 world dimensions/ROI/trigger differ')
            return
        require(isinstance(row, dict) and set(row) in (
            {'cycle', 'mode', 'scenario', 'status', 'productOperations'},
            {'cycle', 'mode', 'scenario', 'status', 'productOperations', 'events'}), 'probe cycle has unexpected fields')
        require(row['cycle'] == cycle and row['mode'] == ('optimized' if cycle % 2 else 'standard')
                and row['scenario'] == 'no-world-no-edit' and row['status'] == 'completed'
                and type(row['productOperations']) is int and row['productOperations'] == 0
                and row.get('events', []) == [], 'probe-only cycle contains product work or wrong mode')

    def validate_records(self):
        if self.arm == ARMS[1]:
            return super().validate_records()
        require(all(not rows for rows in self.records.values()), 'probe-only contains product records')

    def validate_os(self):
        if self.arm == ARMS[1]:
            return super().validate_os()
        os_report = self.report['raw']['os']
        require(os_report['hostPid'] == self.report['hostPid'] and os_report.get('error') is None,
                'probe OS PID/error differs')
        require(len(os_report['files']) == 9, 'nine OS rotations required')
        for descriptor in os_report['files']:
            count = 0
            def consume(row, line):
                nonlocal count
                count += 1
                self.validate_os_row(row)
            self.scan_file(descriptor, consume)
            require(count == descriptor['sampleCount'], 'OS raw file sample count differs')
        expected = Counter({'baseline.before-gc': 1, 'baseline.after-gc': 1,
                            'after-close-retained.before-gc': 8, 'after-close-retained.after-gc': 8,
                            'after-close-released.before-gc': 8, 'after-close-released.after-gc': 8,
                            'recording-stopped': 1})
        expected.update(f'cycle-{cycle}.end' for cycle in range(8))
        require(self.os_count == os_report['sampleCount'] and self.os_periodic > 0 and self.os_smaps >= 34,
                'missing OS samples')
        require(Counter({key: count for key, count in self.os_phases.items() if key != 'periodic'}) == expected,
                'probe OS boundaries missing, duplicated or wrong phase')

    def validate_schedule(self):
        schedule = self.schedule
        require(self.schedule_sha256 == SCHEDULE_SHA256, 'schedule is not the frozen 9d4 derivation')
        path = Path(__file__).with_name('memory_ownership_schedule.json')
        require(digest(path) == SCHEDULE_SHA256 and schedule == load_json(path),
                'schedule document differs from exact pinned bytes')
        require(schedule['schema'] == 'abc.memory-ownership-schedule.v1'
                and schedule['source']['commit'] == BASE_COMMIT
                and schedule['source']['artifactId'] == 11698070273,
                'schedule uses wrong source artifact')
        require([(row['cycle'], row['phase']) for row in schedule['points']] == POINT_KEYS
                and [row['id'] for row in schedule['gaugeSchedule']] == [row[0] for row in gauge_plan()],
                'schedule slots/gauges differ')
        origin = integer(self.report['scheduleOriginUs'], 'schedule origin', 1)
        observations = self.report['scheduleObservations']
        if self.arm == ARMS[1]:
            require(observations == [], 'product arm must retain real work rather than replay timing waits')
            return
        expected = [(-1, 'baseline', schedule['points'][0]['offsetUs'])]
        for cycle, planned in enumerate(schedule['cycles']):
            expected += [(cycle, 'cycle-start', planned['startOffsetUs']),
                         (cycle, 'idle-workload-slot-end', planned['workloadEndOffsetUs'])]
            for phase in ('retained', 'released'):
                quiet = next(row for row in schedule['quietWindows'] if row['cycle'] == cycle and row['phase'] == phase)
                point = next(row for row in schedule['points'] if row['cycle'] == cycle
                             and row['phase'] == f'after-close-{phase}')
                expected += [(cycle, f'{phase}-quiet-start', quiet['startOffsetUs']),
                             (cycle, f'after-close-{phase}', point['offsetUs'])]
        expected += [(8, 'final-quiet-start', schedule['quietWindows'][-1]['startOffsetUs'])]
        require([(row['cycle'], row['phase'], row['plannedOffsetUs']) for row in observations] == expected,
                'probe replay waits missing, duplicate, reordered or changed')
        prior = -1
        quiet_seen = Counter()
        for row in observations:
            exact_keys(row, {'cycle', 'phase', 'plannedOffsetUs', 'actualOffsetUs', 'lateUs'}, 'schedule wait')
            actual = integer(row['actualOffsetUs'], 'actual offset')
            require(actual >= prior and actual >= row['plannedOffsetUs']
                    and integer(row['lateUs'], 'wait lateness') == actual - row['plannedOffsetUs'],
                    'probe wait compressed or lateness concealed')
            prior = actual
            cycle, phase = row['cycle'], row['phase']
            if phase in ('baseline', 'after-close-retained', 'after-close-released'):
                at = next(point['startUs'] for point in self.report['memoryPoints']
                          if (point['cycle'], point['phase']) == (cycle, phase))
            elif phase.endswith('-quiet-start'):
                matches = [boundary for boundary in self.boundaries
                           if boundary['cycle'] == cycle and boundary['phase'] == 'drain-start']
                at = matches[quiet_seen[cycle]]['timeUs']
                quiet_seen[cycle] += 1
            else:
                boundary_phase = 'cycle-start' if phase == 'cycle-start' else 'cycle-disposed'
                at = next(boundary['timeUs'] for boundary in self.boundaries
                          if boundary['cycle'] == cycle and boundary['phase'] == boundary_phase)
            require(origin + actual <= at, 'schedule wait follows its corresponding boundary')

    def validate_worker(self, worker, sequence):
        fields = {'status', 'workerGeneration', 'requestUs', 'ackUs',
                  'productionPendingBefore', 'productionPendingAfter', 'owner'}
        if worker.get('status') == 'acknowledged':
            fields.add('diagnosticRequestExcluded')
        exact_keys(worker, fields, 'worker snapshot')
        start, end = span(worker, 'requestUs', 'ackUs')
        for field in ('productionPendingBefore', 'productionPendingAfter'):
            integer(worker[field], field)
        if worker['status'] == 'worker-not-started':
            require(worker['owner'] is None and worker['workerGeneration'] is None,
                    'unstarted worker owners must be unavailable/null')
            require(worker['productionPendingBefore'] == worker['productionPendingAfter'] == 0,
                    'unstarted worker has production requests')
            require(self.worker_identity is None, 'worker disappeared after acknowledgement')
            require(self.arm == ARMS[0] or sequence < 3, 'product owner missing after first workload')
            return
        require(worker['status'] == 'acknowledged' and worker['diagnosticRequestExcluded'] is True
                and self.arm == ARMS[1] and sequence >= 3, 'worker topology or diagnostic exclusion differs')
        identity = integer(worker['workerGeneration'], 'worker generation', 1)
        require(identity == 1 and self.worker_identity in (None, identity), 'native owner silently restarted')
        self.worker_identity = identity
        owner = worker['owner']
        exact_keys(owner, {'startUs', 'endUs', 'ordinaryDocumentHandles', 'worldCircuitBindingInitialized',
                           'host', 'native'}, 'owner envelope')
        a, b = span(owner)
        require(start <= a <= b <= end, 'worker queue/owner/ack timestamp order invalid')
        integer(owner['ordinaryDocumentHandles'], 'ordinary document handles')
        require(type(owner['worldCircuitBindingInitialized']) is bool, 'binding status must be Boolean')
        require(sequence < 3 or owner['worldCircuitBindingInitialized'] is True,
                'product circuit binding unexpectedly absent after original workload')
        if owner['worldCircuitBindingInitialized']:
            host = owner['host']
            exact_keys(host, HOST_FIELDS, 'host owner scalars')
            for key in HOST_FIELDS:
                if not key.endswith('AccountingCertain'):
                    integer(host[key], key)
            host_start, host_end = span(host)
            require(a <= host_start <= host_end <= owner['native']['startUs'], 'host/native owner source order differs')
            require(host['hostClosingSessions'] <= host['hostSessionCount']
                    and host['hostWorldHandles'] <= host['hostSessionCount']
                    and host['hostCircuitHandles'] <= host['hostSessionCount'], 'host owner counts disagree')
            for kind in ('Hash', 'Read'):
                prefix = f'ffi{kind}Window'
                require(host[prefix + 'AllocatedBytes'] - host[prefix + 'FreedBytes']
                        == host[prefix + 'OutstandingBytes'], 'FFI allocated/freed/outstanding accounting differs')
                require(host[prefix + 'AccountingCertain'] is (host[prefix + 'CleanupFailures'] == 0),
                        'FFI cleanup ambiguity must not become exact physical ownership')
                if not host[prefix + 'AccountingCertain']:
                    self.inconclusive.append(f'ffi-{kind.lower()}-cleanup-uncertain')
                if self.previous_host:
                    require(all(host[prefix + field] >= self.previous_host[prefix + field]
                                for field in ('AllocatedBytes', 'FreedBytes', 'CleanupFailures')),
                            'FFI lifetime cumulative accounting moved backwards')
            self.previous_host = host
        else:
            require(owner['host'] is None and self.previous_host is None,
                    'uninitialized/disappeared bindings must remain unavailable/null')
        if validate_native(owner['native']):
            self.inconclusive.append('native-uint32-censored')
        native_start, native_end = span(owner['native'])
        require(a <= native_start <= native_end <= b, 'native snapshot outside worker owner interval')
        peak = owner['native']['values']['nativeAllocatorPeakBytes']
        require(peak >= self.owner_peak, 'native lifetime peak moved backwards')
        self.owner_peak = peak

    def validate_gauges(self):
        rows = self.report['ownershipGauges']
        require(isinstance(rows, list) and len(rows) == 52, 'exactly 52 owner gauges required')
        require([(row['id'], row['cycle'], row['phase']) for row in rows] == gauge_plan(),
                'ownership gauge IDs missing, duplicate, reordered or changed')
        descriptor = self.report['raw']['ownershipGauges']
        count = 0
        def consume(row, line):
            nonlocal count
            require(count < len(rows) and row == rows[count], 'ownership gauge differs from raw journal')
            self.gauge_bytes.append(self.last_raw_line_bytes)
            count += 1
        self.scan_file(descriptor, consume)
        require(count == descriptor['sampleCount'] == 52, 'ownership raw sample count differs')
        self.validate_allocator_initialization(rows[0]['startUs'])
        self.validate_allocator_captures(rows)
        self.validate_gauge_writes(rows)
        previous_end, previous_images = -1, None
        for index, row in enumerate(rows):
            exact_keys(row, {'id', 'sequence', 'cycle', 'phase', 'startUs', 'mainStartUs', 'mainEndUs', 'endUs',
                             'captureEndUs', 'serializedAfterUs', 'images', 'imageCache', 'wrapper',
                             'worker', 'fd', 'allocator', 'atomic'}, 'ownership gauge')
            require(integer(row['sequence'], 'gauge sequence') == index and row['atomic'] is False,
                    'gauge sequence/atomicity differs')
            integer(row['cycle'], 'gauge cycle', -1)
            start, end = span(row)
            main_start, main_end = span(row, 'mainStartUs', 'mainEndUs')
            capture_end = integer(row['captureEndUs'], 'gauge capture end')
            serialized = integer(row['serializedAfterUs'], 'gauge serialization start')
            allocator = row['allocator']
            allocator_start, allocator_end = span(allocator)
            require(previous_end <= start and start <= main_start <= main_end <= capture_end <= serialized <= end,
                    'gauge source ordering, capture or serialization timestamps invalid')
            previous_end = capture_end
            validate_images(row['images'], previous_images)
            require(row['images']['installedUs'] <= start, 'image gauge before observer installation')
            previous_images = row['images']
            exact_keys(row['imageCache'], {'currentSize', 'currentSizeBytes', 'liveImageCount', 'pendingImageCount'},
                       'image cache')
            for field, value in row['imageCache'].items():
                integer(value, 'ImageCache ' + field)
            validate_wrapper(row['wrapper'])
            retained = '.after-close-retained.' in row['id'] or row['phase'] == 'retained-quiet-end'
            require(row['wrapper']['present'] is (retained and self.arm == ARMS[1]),
                    'wrapper scalar presence differs from lifecycle phase')
            self.validate_worker(row['worker'], index)
            require(start <= row['worker']['requestUs'] <= row['worker']['ackUs'] <= main_start
                    <= main_end <= row['fd']['startUs'],
                    'main/worker/FD source sequence differs')
            if validate_fd(row['fd'], self.report['hostPid']):
                self.inconclusive.append('fd-unsupported')
            require(row['fd']['endUs'] <= capture_end, 'FD sampling leaves gauge capture interval')
            if validate_allocator(allocator, index):
                self.inconclusive.append('allocator-unsupported')
            else:
                runtime = self.build['ownershipProvenance']['allocatorBuild']['runtime']
                require(allocator['glibcVersion'] == runtime['runtimeLibcVersion']
                        and allocator['sizeTBytes'] == runtime['sizeTBytes']
                        and allocator['mallinfo2StructBytes'] == runtime['mallinfo2StructBytes'],
                        'Dart allocator identity differs from archived header/libc build identity')
            if row['phase'].endswith('after-gc'):
                require(start == allocator_start <= allocator_end <= row['worker']['requestUs'],
                        'after-GC allocator must precede other owner gauges')
            else:
                require(row['fd']['endUs'] <= allocator_start <= allocator_end <= capture_end,
                        'before/quiet allocator must follow owner and FD gauges')
        require(rows[0]['endUs'] <= self.report['scheduleOriginUs'], 'initialization not separated from baseline')
        require(rows[-1]['endUs'] <= self.report['raw']['recordingStoppedUs'], 'final owner gauge outside capture')
        lookup = {row['id']: row for row in rows}
        for slot, point in enumerate(self.report['memoryPoints']):
            integer(point['cycle'], 'VM slot cycle', -1)
            cycle, phase = POINT_KEYS[slot]
            prefix = phase if cycle == -1 else f'cycle-{cycle}.{phase}'
            require(point['gaugeBeforeId'] == prefix + '.before-gc'
                    and point['gaugeAfterId'] == prefix + '.after-gc', 'VM slot gauge IDs differ')
            before, after = lookup[point['gaugeBeforeId']], lookup[point['gaugeAfterId']]
            require(point['osBefore']['smapsEndUs'] <= before['startUs']
                    <= before['allocator']['startUs'] <= before['allocator']['endUs']
                    <= point['vmStartUs'] <= point['vmEndUs'] <= after['startUs']
                    <= after['allocator']['endUs'] <= after['worker']['requestUs'] <= after['captureEndUs']
                    <= point['osAfter']['timeUs'] <= point['osAfter']['smapsEndUs']
                    <= before['serializedAfterUs'] <= before['endUs']
                    <= after['serializedAfterUs'] <= after['endUs'] <= point['endUs'],
                    'owner/libc/VM/OS/serialization tight bracket order invalid')
            validate_telemetry(point)
            exact_keys(point, {'phase', 'cycle', 'startUs', 'endUs', 'vmStartUs', 'vmEndUs',
                               'osBefore', 'osAfter', 'vm', 'probeTelemetry', 'recorder',
                               'wrapperLatestRetained', 'gaugeBeforeId', 'gaugeAfterId', 'nativeCounters',
                               'atomic'}, 'VM point')
            require(set(point['vm']) <= set(original.VM_FIELDS) | {'gc', 'heapMeasurementMethod', 'heapUnavailable'},
                    'VM response bodies/class lists are outside scalar memory contract')
        for cycle in range(9):
            drains = [row for row in self.boundaries if row['cycle'] == cycle and row['phase'] == 'drain-end']
            names = [f'cycle-{cycle}.{phase}-quiet-end' for phase in ('retained', 'released')] if cycle < 8 else ['final-quiet-end']
            require(len(drains) == len(names), 'quiet gauge source boundaries missing')
            for boundary, name in zip(drains, names):
                require(boundary['timeUs'] <= lookup[name]['startUs'], 'quiet gauge precedes original fixed quiet end')
                if cycle < 8:
                    point_phase = 'retained-point' if '.retained-' in name else 'released-point'
                    next_boundary = next(row for row in self.boundaries
                                         if row['cycle'] == cycle and row['phase'] == point_phase)
                    require(lookup[name]['endUs'] <= next_boundary['timeUs'],
                            'quiet gauge escapes its original lifecycle boundary')
        self.validate_image_summary(previous_images, rows[-1]['endUs'])

    def validate_allocator_captures(self, gauges):
        descriptor = self.report['raw']['allocatorCaptures']
        count = 0
        def consume(row, line):
            nonlocal count
            exact_keys(row, {'sequence', 'startUs', 'endUs', 'statusCode', 'rawWords', 'rawWordEncoding'},
                       'raw allocator capture')
            require(integer(row['sequence'], 'raw allocator sequence') == count < 52,
                    'raw allocator sequence missing, duplicate or out of budget')
            require(row['rawWordEncoding'] == 'unsigned-decimal-string', 'raw allocator encoding differs')
            words = row['rawWords']
            require(isinstance(words, list) and len(words) == 16, 'raw allocator ABI word count differs')
            require(all(isinstance(word, str) and re.fullmatch(r'0|[1-9][0-9]{0,19}', word)
                        and int(word) < 2 ** 64 for word in words), 'raw allocator unsigned word malformed')
            words = [int(word) for word in words]
            status = integer(row['statusCode'], 'allocator status')
            require(status in range(5) and words[0] == 1 and words[1] == status,
                    'raw allocator ABI/status mismatch')
            require(status == self.report['allocatorInitialization']['statusCode'],
                    'allocator support changed from prebaseline initialization')
            observed = gauges[count]['allocator']
            require(row['startUs'] == observed['startUs'] and row['endUs'] == observed['endUs'],
                    'allocator raw/source timestamps differ')
            require(observed['sizeTBytes'] == words[2]
                    and observed['mallinfo2StructBytes'] == (words[3] or None)
                    and observed['glibcVersion'] == (f'{words[4]}.{words[5]}' if words[4] else None),
                    'allocator raw header/libc identity differs')
            reasons = [None, 'unsupported-build-headers', 'runtime-mallinfo2-unavailable',
                       'allocator-symbols-interposed', 'libc-symbol-identity-unverified']
            require(observed['reason'] == reasons[status]
                    and observed['status'] == ('available' if status == 0 else 'unsupported'),
                    'allocator raw status does not reconcile to described availability')
            if status == 0:
                require([observed['fields'][name] for name in MALLINFO_FIELDS] == words[6:],
                        'allocator raw metric values differ')
            else:
                require(words[6:] == [2 ** 64 - 1] * 10
                        and all(value is None for value in observed['fields'].values()),
                        'allocator unsupported sentinels must remain explicit null')
            count += 1
        self.scan_file(descriptor, consume)
        require(count == descriptor['sampleCount'] == 52, 'exactly 52 raw allocator captures required')

    def validate_allocator_initialization(self, first_gauge_start):
        initialization = self.report['allocatorInitialization']
        exact_keys(initialization, {'startUs', 'endUs', 'statusCode', 'status', 'reason', 'clockDomain'},
                   'allocator initialization')
        start, end = span(initialization)
        status = integer(initialization['statusCode'], 'allocator initialization status')
        reasons = [None, 'unsupported-build-headers', 'runtime-mallinfo2-unavailable',
                   'allocator-symbols-interposed', 'libc-symbol-identity-unverified']
        require(end <= first_gauge_start and status in range(5) and initialization['clockDomain'] == CLOCK,
                'allocator initialization after baseline/unknown clock or status')
        require(initialization['status'] == ('available' if status == 0 else 'unsupported')
                and initialization['reason'] == reasons[status], 'allocator initialization availability inconsistent')

    def validate_gauge_writes(self, gauges):
        writes = self.report['ownershipGaugeWrites']
        require(isinstance(writes, list) and len(writes) == 52, 'all 52 gauge write/flush overhead records required')
        prior = -1
        for index, (row, gauge) in enumerate(zip(writes, gauges)):
            exact_keys(row, {'id', 'sequence', 'startUs', 'endUs', 'bytes', 'status'}, 'gauge write')
            start, end = span(row)
            require(integer(row['sequence'], 'gauge write sequence') == index and row['id'] == gauge['id']
                    and row['status'] == 'written', 'gauge write failed, duplicated or wrong ID')
            require(integer(row['bytes'], 'serialized gauge bytes', 1) == self.gauge_bytes[index],
                    'gauge encoded byte count differs from actual raw journal')
            require(prior <= start and gauge['serializedAfterUs'] <= start <= end,
                    'gauge write/flush timestamps overlap or precede preencode marker')
            prior = end
            if index == 0:
                require(end <= self.report['scheduleOriginUs'], 'initialization encoding extends into baseline')
            if index == 51:
                require(end <= self.report['raw']['recordingStoppedUs'], 'final gauge write follows recording stop')
            if gauge['phase'].endswith('before-gc'):
                point = next(point for point in self.report['memoryPoints'] if point['gaugeBeforeId'] == row['id'])
                require(point['osAfter']['smapsEndUs'] <= start, 'gauge encoded/written before original OS-after')
            elif gauge['phase'].endswith('after-gc'):
                point = next(point for point in self.report['memoryPoints'] if point['gaugeAfterId'] == row['id'])
                require(end <= point['endUs'], 'gauge write/flush extends beyond VM point')
            elif gauge['cycle'] >= 0 and gauge['cycle'] < 8:
                phase = 'retained-point' if gauge['phase'] == 'retained-quiet-end' else 'released-point'
                boundary = next(row for row in self.boundaries
                                if row['cycle'] == gauge['cycle'] and row['phase'] == phase)
                require(end <= boundary['timeUs'], 'quiet gauge write/flush extends beyond lifecycle boundary')

    def validate_image_summary(self, previous, final_gauge_end):
        summary = self.report['imageObserverSummary']
        exact_keys(summary, IMAGE_FIELDS | {'restorationComplete'}, 'final image observer')
        require(summary['active'] is False and summary['callbacksIntact'] is True
                and summary['restorationComplete'] is True and summary['everReplaced'] is False
                and summary['preInstallationHandlesUnknown'] is True
                and summary['priorCallbackFailures'] == 0, 'image callback restoration/completeness failed')
        require(integer(summary['stoppedUs'], 'image observer stop') >= final_gauge_end
                and summary['installedUs'] == previous['installedUs'], 'image observer stop/install times differ')
        for field in ('installedUs', 'priorCallbackFailures', 'createdHandles', 'disposedHandles',
                      'peakObservedHandleBalance'):
            integer(summary[field], field)
        require(type(summary['observedHandleBalance']) is int, 'observedHandleBalance: signed integer required')
        require(summary['createdHandles'] - summary['disposedHandles'] == summary['observedHandleBalance']
                and summary['peakObservedHandleBalance'] >= summary['observedHandleBalance']
                and all(summary[field] >= previous[field] for field in
                        ('createdHandles', 'disposedHandles', 'peakObservedHandleBalance')),
                'final image callback totals do not reconcile')
        if self.arm == ARMS[1]:
            require(summary['createdHandles'] > 0, 'product image callback observation never fired')

    def overhead(self):
        rows = []
        for index, gauge in enumerate(self.report['ownershipGauges']):
            worker, allocator, fd = gauge['worker'], gauge['allocator'], gauge['fd']
            owner = worker['owner']
            rows.append({'id': gauge['id'], 'mainGaugeUs': gauge['mainEndUs'] - gauge['mainStartUs'],
                         'gaugeEncodeWriteFlushUs': self.report['ownershipGaugeWrites'][index]['endUs']
                            - self.report['ownershipGaugeWrites'][index]['startUs'],
                         'workerRpcUs': worker['ackUs'] - worker['requestUs'],
                         'workerQueueUs': owner['startUs'] - worker['requestUs'] if owner else None,
                         'hostGaugeUs': owner['host']['endUs'] - owner['host']['startUs'] if owner and owner['host'] else None,
                         'nativeSnapshotUs': owner['native']['endUs'] - owner['native']['startUs'] if owner else None,
                         'allocatorCallUs': allocator['endUs'] - allocator['startUs'],
                         'fdObservationUs': fd['endUs'] - fd['startUs'],
                         'fdEnumerationUs': fd['enumerationEndUs'] - fd['startUs'] if fd['enumerationEndUs'] is not None else None,
                         'fdClassificationUs': fd['endUs'] - fd['classificationStartUs'] if fd['classificationStartUs'] is not None else None,
                         'serializedRecordBytes': self.gauge_bytes[index]})
        summaries = {}
        for field in rows[0].keys() - {'id'}:
            values = sorted(row[field] for row in rows if row[field] is not None)
            summaries[field] = {'sampleCount': len(values), 'p50': values[(len(values) - 1) // 2] if values else None,
                                'p95': values[(95 * len(values) + 99) // 100 - 1] if values else None,
                                'maximum': max(values) if values else None}
        return {'rows': rows, 'summary': summaries, 'percentileMethod': 'nearest-rank',
                'subtractedFromProductMemory': False,
                'allocatorInitializationUs': self.report['allocatorInitialization']['endUs']
                    - self.report['allocatorInitialization']['startUs'],
                'vmSlotUs': [point['vmEndUs'] - point['vmStartUs'] for point in self.report['memoryPoints']]}

    def summarize_points(self):
        result = original.summarize_points(self.report.get('memoryPoints', []))
        if self.arm == ARMS[0]:
            scenarios = {row['cycle']: row.get('scenario') for row in self.report.get('cycles', [])}
            for row in result['cycles']:
                row['scenario'] = scenarios.get(row['cycle'])
            for pair in result['modePairs']:
                first, second = (scenarios.get(cycle) for cycle in pair['cycles'])
                pair['scenario'] = first if first == second else None
        return result

    def run(self):
        for name, method in (('report', self.validate_header), ('provenance', self.validate_provenance),
                             ('execution', lambda: validate_execution(self.execution, self.report, self.build,
                                self.expected_commit, self.build_sha256, self.schedule_sha256, self.report_sha256)),
                             ('boundaries', self.validate_boundaries), ('cycles', self.validate_cycles),
                             ('frames', self.validate_frames), ('records', self.validate_records),
                             ('OS samples', self.validate_os), ('checkpoints', self.validate_points),
                             ('schedule', self.validate_schedule), ('ownership', self.validate_gauges)):
            self.guard(name, method)
        extra = self.guard('raw inventory', lambda: sorted(path.name for path in self.root.iterdir()
                                                          if path.name not in self.files))
        if extra:
            self.errors.append(f'Unreferenced raw files/resources: {extra}')
        windows = self.guard('frame attribution', self.attribute_windows)
        points = self.guard('point summaries', self.summarize_points)
        overhead = self.guard('observer overhead', self.overhead)
        return {'schema': VALIDATION_SCHEMA, 'arm': self.arm,
                'status': 'validated-bounded-owner-observation' if not self.errors else 'failed',
                'evidenceValid': not self.errors, 'acceptanceEvidence': False, 'plateauEstablished': False,
                'stabilityEstablished': False, 'causalAttribution': 'inconclusive',
                'originalGrowthStillUnresolved': True, 'expectedCommit': self.expected_commit,
                'baseProductCommit': BASE_COMMIT, 'execution': self.execution,
                'runtime': {key: self.report.get('runtime', {}).get(key) for key in
                            ('renderer', 'flutterVersion', 'flutterRevisionPin', 'platform')},
                'binaryDigests': {name: self.build.get('artifacts', {}).get(name, {}).get('sha256')
                                  for name in ('terraforge', 'libapp.so', 'libabc_engine.so')},
                'errors': self.errors, 'warnings': self.warnings,
                'inconclusiveMetrics': sorted(set(self.inconclusive)), 'measurements': points,
                'observerOverhead': overhead,
                'raw': {'verifiedFiles': self.files, 'receivedFrames': self.frame_count,
                        'osSamples': self.os_count, 'windowAttribution': windows,
                        'allReceivedRecordsReconciled': not self.errors},
                'limits': ['Complete scalar observations do not establish a memory plateau or leak freedom.',
                           'Process/VM/native/libc/image/FD views overlap and must not be summed or subtracted into ownership.',
                           'Probe-only is an idle observer companion, not a causal subtraction control.',
                           'Only received callbacks and declared source intervals are covered; graphics residency is unavailable.']}


def validate_arm(report, raw_directory, build, expected_commit, build_sha256,
                 execution, schedule, schedule_sha256, report_sha256):
    try:
        return OwnershipValidator(report, raw_directory, build, expected_commit, build_sha256,
                                  execution, schedule, schedule_sha256, report_sha256).run()
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, OverflowError) as error:
        return {'schema': VALIDATION_SCHEMA, 'status': 'failed', 'evidenceValid': False,
                'acceptanceEvidence': False, 'plateauEstablished': False, 'stabilityEstablished': False,
                'causalAttribution': 'inconclusive', 'errors': [str(error)]}


def validate_group(group, arm_results):
    errors = []
    try:
        require(group['schema'] == 'abc.memory-ownership-group.v1' and group['status'] == 'completed'
                and group['armOrder'] == list(ARMS), 'group schema/order/completion differs')
        require(len(arm_results) == 2 and [row['arm'] for row in arm_results] == list(ARMS),
                'exactly probe-only then product arm results required')
        require(all(row['schema'] == VALIDATION_SCHEMA and row['evidenceValid'] is True
                    and row['acceptanceEvidence'] is False and row['plateauEstablished'] is False
                    for row in arm_results), 'group contains invalid or acceptance-promoted arm')
        executions = [row['execution'] for row in arm_results]
        require(group['executions'] == executions, 'group executions differ from validated arm inputs')
        first, second = executions
        for field in ('sourceCommit', 'sourceProvenanceSha256', 'scheduleSha256',
                      'nativeEngineSha256', 'allocatorHelperSha256', 'allocatorBuildSha256', 'binarySha256'):
            require(first[field] == second[field], f'arms disagree on {field}')
        require(group['sourceCommit'] == first['sourceCommit']
                and group['sourceProvenanceSha256'] == first['sourceProvenanceSha256']
                and group['scheduleSha256'] == SCHEDULE_SHA256 == first['scheduleSha256'],
                'group pinned identity differs')
        require(first['exitedMonotonicNs'] <= second['launchedMonotonicNs'], 'arms overlapped or ran in reverse order')
        require(second['exitedMonotonicNs'] - first['launchedMonotonicNs'] <= 2_000_000_000_000,
                'group wall-time budget exceeded')
        left, right = first['processIdentity'], second['processIdentity']
        require((left['pid'], left['starttimeTicks']) != (right['pid'], right['starttimeTicks']),
                'arms reused the same process identity')
        require((left['processGroupId'], left['groupLeaderStarttimeTicks']) !=
                (right['processGroupId'], right['groupLeaderStarttimeTicks']), 'arms reused the same owned process group')
        for field in ('runnerPid', 'runnerStarttimeTicks', 'uid'):
            require(left[field] == right[field], 'arms were not owned by the same runner')
        require(arm_results[0]['runtime'] == arm_results[1]['runtime'], 'renderer/toolchain/platform differs across arms')
        require(arm_results[0]['binaryDigests'] == arm_results[1]['binaryDigests'],
                'same compiled instrumentation binaries required for both runtime-selected arms')
        require(first['binaries'] == second['binaries'], 'actual archived executable/libapp/native/helper bytes differ')
    except (ValueError, TypeError, KeyError, IndexError, AttributeError) as error:
        errors.append(str(error))
    return {'schema': 'abc.memory-ownership-group-validation.v1',
            'status': 'validated-bounded-owner-group' if not errors else 'failed',
            'evidenceValid': not errors, 'acceptanceEvidence': False, 'plateauEstablished': False,
            'stabilityEstablished': False, 'causalAttribution': 'inconclusive', 'errors': errors}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--raw-directory', required=True, type=Path)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--execution', required=True, type=Path)
    parser.add_argument('--schedule', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        result = validate_arm(load_json(args.report), args.raw_directory, load_json(args.build),
                              args.expected_commit, digest(args.build), load_json(args.execution),
                              load_json(args.schedule), digest(args.schedule), digest(args.report))
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, OverflowError) as error:
        result = {'schema': VALIDATION_SCHEMA, 'status': 'failed', 'evidenceValid': False,
                  'acceptanceEvidence': False, 'plateauEstablished': False, 'stabilityEstablished': False,
                  'causalAttribution': 'inconclusive', 'errors': [str(error)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print(f'{result["status"]}: {len(result["errors"])} error(s); {args.output}')
    return 0 if result['evidenceValid'] else 1


if __name__ == '__main__':
    sys.exit(main())

