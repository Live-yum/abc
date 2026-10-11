#!/usr/bin/env python3
"""Offline source-only q0 preservation audit. Never imports/runs a Dart SDK.

The original ownership source is immutable input. This checks its exact helper
bodies and the probe-only execution prefix, not a synthetic Flutter execution.
Real Dart format/analyze, native runtime and Flutter behavior remain untested.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT if (ROOT / 'integration_test/computer_memory_ownership_test.dart').is_file() else (
    ROOT.parent / 'gperftools-maps-role-publication-review/snapshot')
ENTRY_PATH = ROOT / 'integration_test/computer_memory_sampled_q0_test.dart'
BRIDGE_PATH = ROOT / 'integration_test/support/memory_sampled_q0_probe.dart'
ORIGINAL_PATH = BASE / 'integration_test/computer_memory_ownership_test.dart'
ORIGINAL_SHA256 = '3b324b4eae2baf1a456b5354dca0110b5f3853bbe92c73c42fa983967613a8e3'


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


def lines(text):
    return [line.strip() for line in text.splitlines() if line.strip()]


def require(condition, reason):
    if not condition:
        raise AssertionError(reason)


def validate_prefix(entry, original):
    boundaries = (
        '      Future<void> until(',
        '      Future<Map<String, Object?>> collect(',
        '      void persist(',
        '      void requireComplete(',
        '      Future<void> gauge(',
        '      Future<void> quiet(',
        '      Future<void> point(',
        "      await gauge('initialization'",
    )
    for start, end in zip(boundaries, boundaries[1:]):
        if 'quiet(' in start:
            continue
        require(between(entry, start, end) == between(original, start, end),
                f'Original measurement helper changed: {start.strip()}')
    quiet = between(original, boundaries[5], boundaries[6])
    quiet = quiet.replace("cycle == 8 ? suffix : 'cycle-$cycle.$suffix'",
                          "'cycle-$cycle.$suffix'")
    quiet = re.sub(r'        // BEGIN bounded stack-attribution quiet cut.*?'
                   r'        // END bounded stack-attribution quiet cut',
                   "        // The only new measured cut: immediately after the original q0 gauge.\n"
                   "        if (phase == 'released' && cycle == 0) {\n"
                   "          sample.afterQ0Gauge(Timeline.now);\n"
                   '        }', quiet, flags=re.S)
    require(between(entry, boundaries[5], boundaries[6]) == quiet,
            'Original quiet drain/gauge changed or sampled hook moved')
    common = between(original, '      for (var cycle = 0; cycle < 8; cycle++) {',
                     '        if (probeOnly) {\n          evidence.addAll')
    body = between(original, '          evidence.addAll(createProbeOnlyCycleEvidence(cycle));',
                   "          await activeJournal.flush('cycle-$cycle.late-tail');")
    expected = common + '\n          evidence.addAll(createProbeOnlyCycleEvidence(cycle));' + body
    actual = between(entry, '      const cycle = 0;', '      // Stop at q0.')
    require(lines(actual) == lines(expected),
            'Probe-only schedule/action prefix before q0 changed')
    require(between(entry, "      await gauge('initialization'", '      const cycle = 0;') ==
            between(original, "      await gauge('initialization'", '      for (var cycle'),
            'Initialization/baseline call order changed')


def validate_exclusions(entry, bridge):
    forbidden = (
        'HeapProfilerStart', 'HeapProfilerStop', 'IsHeapProfilerRunning',
        'MemoryAllocationStackProbe', 'abc_quiet_', 'computerInput(',
        'runComputerMemoryDiagnosticCycle', 'product-with-ownership',
        'after-close-released', 'completeProbeOnlyCycleEvidence(',
        'completedOwnershipCycles(', 'cycle == 7', 'cycle < 8',
        "await quiet(8,", "request('rotate'", 'GetHeapGrowthStacks',
    )
    for token in forbidden:
        require(token not in entry + bridge, f'Forbidden old/product path: {token}')
    require(entry.count('observed = await telemetry.measure();') == 1,
            'Only original point helper may invoke telemetry')
    require(entry.count('await tester.pump(') == 1,
            'Only original quiet helper may pump')
    require(entry.count('sample.afterQ0Gauge(Timeline.now);') == 1,
            'Only one sampled q0 hook call site allowed')


class SampledDartSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entry = ENTRY_PATH.read_text()
        cls.bridge = BRIDGE_PATH.read_text()
        cls.original = ORIGINAL_PATH.read_text()

    def test_frozen_original_is_unchanged(self):
        self.assertEqual(hashlib.sha256(ORIGINAL_PATH.read_bytes()).hexdigest(),
                         ORIGINAL_SHA256)

    def test_original_helpers_and_probe_prefix_through_q0_are_preserved(self):
        validate_prefix(self.entry, self.original)

    def test_changed_quiet_drain_or_schedule_wait_is_rejected(self):
        for old, new in (('milliseconds: 1200', 'milliseconds: 1201'),
                         ("planned['workloadEndOffsetUs']", "planned['startOffsetUs']"),
                         ('for (var i = 0; i < 3; i++)', 'for (var i = 0; i < 4; i++)')):
            with self.subTest(change=old), self.assertRaises(AssertionError):
                validate_prefix(self.entry.replace(old, new), self.original)

    def test_no_product_full_profiler_or_post_q0_paths(self):
        validate_exclusions(self.entry, self.bridge)

    def test_added_probe_or_old_path_is_rejected(self):
        for addition in ('observed = await telemetry.measure();',
                         'sample.afterQ0Gauge(Timeline.now);',
                         'HeapProfilerStart(', 'cycle == 7'):
            with self.subTest(addition=addition), self.assertRaises(AssertionError):
                validate_exclusions(self.entry + addition, self.bridge)

    def test_sampled_report_cannot_claim_original_workload_completion(self):
        for token in ("'schema': 'abc.gperftools-sampled-q0-control.v1'",
                      "'mode': 'sampled-q0-feasibility'", "'completedCycles': 0",
                      "'originalEightCycleWorkloadCompleted': false",
                      "'mappingAcceptanceEstablished': false", "'fullHeapCoverage': false",
                      "'plannedCheckpoints': 2", "'plannedOwnershipGauges': 7",
                      "'expectedNativeWorkers': 0", "'inputFormat': 'none'",
                      "evidence['status'] = 'stopped-at-q0';"):
            self.assertIn(token, self.entry)
        self.assertNotIn("'schema': 'abc.memory-ownership.v1'", self.entry)
        for token in ('expect(points.length, 2)', 'expect(gauges.length, 7)',
                      'expect(retentionProbe.captureCount, 7)', 'expect(vmProbeCalls, 2)'):
            self.assertIn(token, self.entry)

    def test_default_off_and_probe_only_guards_are_explicit(self):
        self.assertIn("!const bool.fromEnvironment('ABC_SAMPLED_DIAGNOSTIC')", self.entry)
        self.assertIn("!const bool.fromEnvironment('ABC_SAMPLED_DIAGNOSTIC')", self.bridge)
        self.assertIn("if (arm != 'probe-only')", self.entry)
        self.assertIn("environment['ABC_SAMPLED_DIAGNOSTIC'] != '1'", self.bridge)
        self.assertIn("environment['TCMALLOC_SAMPLE_PARAMETER'] != '524288'", self.bridge)
        self.assertIn("environment['MEMORY_OWNER_ARM'] != 'probe-only'", self.bridge)
        self.assertIn("environment['ABC_SAMPLED_HELLO'] != '$output/sampled-hello.json'", self.bridge)
        self.assertIn("environment['ABC_SAMPLED_READY'] != '$output/sampled-ready.json'", self.bridge)

    def test_hello_identity_gate_precedes_schedule_and_measurement(self):
        order = ['sample.initialize();', "'schema': 'abc.gperftools-sampled-hello.v1'",
                 'helloTemporary.renameSync(hello.path);',
                 'startupIdentityGate = await waitForSampledQ0Ready(',
                 'final recorder = ProfileRecorder(',
                 "await gauge('initialization'", 'origin = Timeline.now;',
                 "await point(-1, 'baseline'"]
        positions = [self.entry.index(item) for item in order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("'sampledStartup': sample.startup", self.entry)

    def test_ready_retains_original_deadline_interval_and_identity_checks(self):
        original_gauges = (BASE / 'integration_test/support/memory_ownership_gauges.dart').read_text()
        expected = between(original_gauges, 'Map<String, Object?> validateOwnershipReady(',
                           'String? ownershipGaugeFailure(')
        expected = expected.replace('abc.memory-ownership-ready.v1',
                                    'abc.gperftools-sampled-ready.v1')
        expected = expected.replace('Ownership startup', 'Sampled q0 startup')
        expected = expected.replace('waitForOwnershipReady', 'waitForSampledQ0Ready')
        expected = expected.replace('validateOwnershipReady', 'validateSampledQ0Ready')
        actual = self.bridge.split('Map<String, Object?> validateSampledQ0Ready(', 1)[1]
        actual = actual.replace("      arm != 'probe-only' ||\n", '')
        actual = actual.replace('// Same one-time startup gate budget as the original ownership entrypoint.\n'
                                '// The gate is before schedule origin and all gauges, never at the q0 cut.\n', '')
        self.assertEqual(expected.strip(), actual.strip())

    def test_ffi_is_minimal_synchronous_and_single_attempt(self):
        symbols = re.findall(r"'(abc_sample_runtime_[a-z0-9_]+)'", self.bridge)
        self.assertEqual(set(symbols), {'abc_sample_runtime_initialize', 'abc_sample_runtime_q0',
                                        'abc_sample_runtime_close', 'abc_sample_runtime_metadata_json'})
        self.assertIn('typedef _Q0Native = Int32 Function(Uint64);', self.bridge)
        self.assertNotIn('isLeaf: true', self.bridge)
        cut = between(self.bridge, '  void afterQ0Gauge(', '  // First operation in outer finally')
        self.assertEqual(cut.count('_q0(gaugeDartUs)'), 1)
        for token in ('await ', '_nativeMetadata(', 'Future', '.delayed(', 'readAs', '.existsSync('):
            self.assertNotIn(token, cut)
        self.assertLess(cut.index('_q0Attempted = true;'), cut.index('_q0(gaugeDartUs)'))
        self.assertIn('_q0Attempted || _closeInvoked', cut)

    def test_bounded_metadata_and_cleanup_before_evidence(self):
        self.assertIn('static const _metadataByteLimit = 16384;', self.bridge)
        self.assertIn('buffer.indexOf(0)', self.bridge)
        self.assertEqual(self.bridge.count('final native = _nativeMetadata();'), 2)
        finish = between(self.bridge, '  void closeAndWriteEvidence()', '\n}\n\nMap<String, Object?>')
        sequence = ['_closeInvoked = true;', 'final result = _close();',
                    'final native = _nativeMetadata();', 'final evidence =',
                    'file.createSync(exclusive: true);', 'file.writeAsStringSync(']
        positions = [finish.index(token) for token in sequence]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("'clockDomainsComparable': false", finish)
        self.assertIn("sample['api_calls'] == 1", finish)
        self.assertIn("native['q0Calls'] == 1", finish)
        self.assertIn("native['closeCalls'] == 1", finish)
        self.assertIn("native['q0TransportAccepted'] == true", finish)
        self.assertIn("observer['heldFds'] == 0", finish)

    def test_original_failure_cleanup_remains_after_native_close(self):
        beginning, end = '      try {\n        journal?.stop();', '      final report ='
        self.assertEqual(between(self.entry, beginning, end),
                         between(self.original, beginning, end))
        close_index = self.entry.index('sampledProbe?.closeAndWriteEvidence();')
        self.assertLess(close_index, self.entry.index('journal?.stop();'))

    def test_relative_imports_resolve_after_overlay_without_product_inputs(self):
        for path in re.findall(r"import '([^']+)'", self.entry + self.bridge):
            if ':' in path:
                continue
            self.assertTrue((ROOT / 'integration_test' / path).is_file() or
                            (BASE / 'integration_test' / path).is_file(), path)
        self.assertNotIn('computer_memory_diagnostic_test.dart', self.entry)
        self.assertNotIn('computer_inputs_native.dart', self.entry)

    def test_native_shared_fixture_contains_every_consumed_metadata_key(self):
        # Synthetic identity/timestamps; this is an interface compatibility
        # check, never proof that a real official provider ran successfully.
        raw = (Path(__file__).parent / 'sample_runtime_metadata.example.json').read_bytes()
        self.assertLess(len(raw), 16384)
        fixture = json.loads(raw)
        self.assertEqual(fixture['schema'], 'abc.gperftools-sampled-runtime.v1')
        self.assertEqual(fixture['abi'], 1)
        for name in ('native', 'provider', 'target', 'output', 'observer', 'sample', 'cut'):
            values = fixture if name == 'native' else fixture[name]
            used = set(re.findall(rf"\b{name}\['([^']+)'\]", self.bridge))
            self.assertTrue(used <= set(values), (name, sorted(used - set(values))))
        for key in ('initialized', 'closed', 'q0TransportAccepted',
                    'estimationOnly', 'transportOnly'):
            self.assertIs(type(fixture[key]), bool)
        for key in ('receiptPublished', 'ackAccepted'):
            self.assertIs(type(fixture['cut'][key]), bool)
        for key in ('accepted', 'api_calls', 'published', 'cleanup_errno'):
            self.assertIs(type(fixture['sample'][key]), int)
        observer = fixture['observer']
        self.assertEqual(observer['heldFds'], 0)
        self.assertEqual(observer['fdOpened'], observer['fdClosed'])
        self.assertEqual(observer['fdCloseAttempts'], observer['fdClosed'])
        header = (Path(__file__).parent / 'sample_runtime.h').read_text()
        self.assertIn('#define ABC_SAMPLE_METADATA_CAP 16384u', header)
        self.assertIn('int abc_sample_runtime_q0(uint64_t gauge_dart_us);', header)


if __name__ == '__main__':
    unittest.main()
