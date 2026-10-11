// Independent sampled feasibility control: unchanged probe-only prefix to q0.
// This entrypoint never completes the original eight-cycle ownership workload.
// Keep original helpers/schedule behavior through released-quiet-end intact.
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terraforge/engine/native_engine.dart' as core;
import 'package:terraforge/engine/native_memory_ownership_diagnostics.dart';

import 'support/computer_memory_journal.dart';
import 'support/computer_memory_probe_telemetry.dart';
import 'support/memory_ownership_gauges.dart';
import 'support/memory_sampled_q0_probe.dart';
import 'support/memory_ownership_retention.dart';
import 'support/profile_memory_native.dart' as memory;
import 'support/profile_recorder.dart';

const _base = '9d4cd5a0f9db03042a3986689fea374ba92d78b8';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('original probe-only prefix to one sampled q0', (tester) async {
    if (!kProfileMode ||
        !Platform.isLinux ||
        !memoryOwnershipDiagnosticsEnabled ||
        !const bool.fromEnvironment('ABC_SAMPLED_DIAGNOSTIC')) {
      fail('Requires opt-in sampled Linux Flutter profile ownership build');
    }
    final arm = Platform.environment['MEMORY_OWNER_ARM'];
    if (arm != 'probe-only') {
      fail('Sampled q0 control requires the probe-only arm');
    }
    const probeOnly = true;
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final imageObserver = ImageOwnershipObserver()..install();
    final fdObserver = OwnFdObserver();
    final telemetry = ComputerMemoryProbeTelemetry();
    final points = <Map<String, Object?>>[], gauges = <Map<String, Object?>>[];
    final cycles = <Map<String, Object?>>[], waits = <Map<String, Object?>>[];
    final emptyWrapper = wrapperResultSnapshot(null);
    ComputerMemoryJournal? journal;
    ComputerMemoryOsJournal? os;
    OwnershipRetentionProbe? retention;
    MemorySampledQ0Probe? sampledProbe;
    OwnershipGaugeWriter? gaugeWriter;
    RandomAccessFile? gaugeOutput;
    Directory? root;
    File? gaugeFile;
    Map<String, Object?>? osResult, rawGauges, rawAllocator, imageSummary;
    Map<String, Object?>? startupIdentityGate;
    Map? schedule;
    String? scheduleSha;
    var origin = 0, status = 'failed';
    var vmProbeCalls = 0;
    String? failure, failureStack;

    try {
      final sample = MemorySampledQ0Probe.open();
      sampledProbe = sample;
      sample.initialize();
      final scheduleBytes = await File(
        Platform.environment['ABC_OWNER_SCHEDULE']!,
      ).readAsBytes();
      final activeSchedule = jsonDecode(utf8.decode(scheduleBytes)) as Map;
      schedule = activeSchedule;
      scheduleSha = sha256.convert(scheduleBytes).toString();
      expect(schedule['schema'], 'abc.memory-ownership-schedule.v1');
      expect((schedule['source'] as Map)['commit'], _base);
      expect((schedule['points'] as List).length, 17);
      expect((schedule['cycles'] as List).length, 8);
      expect((schedule['quietWindows'] as List).length, 17);
      expect((schedule['gaugeSchedule'] as List).length, 52);
      root = Directory(Platform.environment['ABC_MEMORY_RAW_DIRECTORY']!);
      if (root.existsSync()) fail('New ownership raw directory required');
      await root.create(recursive: true);
      gaugeFile = File('${root.path}/ownership-gauges.jsonl');
      gaugeOutput = gaugeFile.openSync(mode: FileMode.writeOnly);
      final writer = OwnershipGaugeWriter(
        write: (bytes) => gaugeOutput!.writeFromSync(bytes),
        flush: () => gaugeOutput!.flushSync(),
      );
      gaugeWriter = writer;
      final retentionProbe = OwnershipRetentionProbe.open(
        Platform.environment['ABC_OWNER_LIBC_HELPER']!,
      );
      retention = retentionProbe;
      if (retentionProbe.initialization['status'] == 'failed') {
        throw StateError('Allocator helper initialization failed');
      }
      final hello = File(Platform.environment['ABC_SAMPLED_HELLO']!);
      final helloTemporary = File('${hello.path}.pending');
      final ready = File(Platform.environment['ABC_SAMPLED_READY']!);
      if (hello.existsSync() ||
          helloTemporary.existsSync() ||
          ready.existsSync()) {
        fail('New owned-process handshake paths required');
      }
      helloTemporary.writeAsStringSync(
        jsonEncode({
          'schema': 'abc.gperftools-sampled-hello.v1',
          'arm': arm,
          'hostPid': pid,
          'sourceCommit': const String.fromEnvironment('PERF_COMMIT'),
          'baseProductCommit': _base,
          'startedUs': Timeline.now,
          'sampledStartup': sample.startup,
        }),
        mode: FileMode.writeOnly,
        flush: true,
      );
      if (hello.existsSync()) fail('Owned-process hello already exists');
      helloTemporary.renameSync(hello.path);
      startupIdentityGate = await waitForSampledQ0Ready(
        ready,
        arm: 'probe-only',
        hostPid: pid,
        sourceCommit: const String.fromEnvironment('PERF_COMMIT'),
        baseProductCommit: _base,
      );
      // No synthetic image, dummy worker, decoder warm-up or product input.
      final recorder = ProfileRecorder(
        frameBudgetUs: 1000000 / 60,
        profile: true,
        currentRss: memory.currentRss,
      );
      final activeJournal = ComputerMemoryJournal(root, recorder)..start();
      journal = activeJournal;
      final osJournal = await ComputerMemoryOsJournal.start(root);
      os = osJournal;

      Future<void> until(int offset, String phase, int cycle) async {
        final remaining = origin + offset - Timeline.now;
        if (remaining > 0) {
          await Future<void>.delayed(Duration(microseconds: remaining));
        }
        final actual = Timeline.now - origin;
        waits.add({
          'phase': phase,
          'cycle': cycle,
          'plannedOffsetUs': offset,
          'actualOffsetUs': actual,
          'lateUs': (actual - offset).clamp(0, 1 << 62),
        });
      }

      Future<Map<String, Object?>> collect(
        String id,
        int cycle,
        String phase,
        Map<String, Object?> wrapper,
      ) async {
        final started = Timeline.now;
        Map<String, Object?> worker;
        try {
          worker = await core.diagnosticOwnerSnapshot();
        } catch (_) {
          worker = {
            'status': 'failed',
            'workerGeneration': null,
            'requestUs': started,
            'ackUs': null,
            'failedUs': Timeline.now,
            'productionPendingBefore': null,
            'productionPendingAfter': null,
            'owner': null,
            'errorKind': 'owner-request-failed',
          };
        }
        final mainStarted = Timeline.now;
        final imageState = imageObserver.snapshot();
        final cache = imageCacheSnapshot();
        final mainEnded = Timeline.now;
        final fd = fdObserver.sample();
        return {
          'id': id,
          'sequence': gauges.length,
          'cycle': cycle,
          'phase': phase,
          'startUs': started,
          'mainStartUs': mainStarted,
          'mainEndUs': mainEnded,
          'captureEndUs': Timeline.now,
          'images': imageState,
          'imageCache': cache,
          'wrapper': wrapper,
          'worker': worker,
          'fd': fd,
          'atomic': false,
        };
      }

      void persist(Map<String, Object?> row, int allocatorIndex) {
        row['sequence'] = gauges.length;
        row['allocator'] = retentionProbe.describe(allocatorIndex);
        final allocator = row['allocator'] as Map;
        if ((allocator['endUs'] as int) > (row['captureEndUs'] as int)) {
          row['captureEndUs'] = allocator['endUs'];
        }
        final serializationMarker = Timeline.now;
        row['serializedAfterUs'] = serializationMarker;
        row['endUs'] = serializationMarker;
        if (ownershipGaugeFailure(row, probeOnly: probeOnly) != null) {
          row['partial'] = true;
        }
        gauges.add(row);
        writer.write(row);
      }

      void requireComplete(Map<String, Object?> row) {
        final failure = ownershipGaugeFailure(row, probeOnly: probeOnly);
        if (failure != null) throw StateError(failure);
      }

      Future<void> gauge(
        String id,
        int cycle,
        String phase,
        Map<String, Object?> wrapper,
      ) async {
        final row = await collect(id, cycle, phase, wrapper);
        final captured = retentionProbe.capture();
        persist(row, captured);
        requireComplete(row);
      }

      Future<void> quiet(
        int cycle,
        String phase,
        Map<String, Object?> Function() wrapper,
      ) async {
        final window = (activeSchedule['quietWindows'] as List)
            .cast<Map>()
            .singleWhere(
              (row) => row['cycle'] == cycle && row['phase'] == phase,
            );
        if (probeOnly) {
          await until(
            window['startOffsetUs'] as int,
            '$phase-quiet-start',
            cycle,
          );
        }
        activeJournal.boundary('drain-start', cycle);
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        activeJournal.boundary('drain-end', cycle);
        final suffix = '$phase-quiet-end';
        await gauge(
          'cycle-$cycle.$suffix',
          cycle,
          suffix,
          wrapper(),
        );
        // The only new measured cut: immediately after the original q0 gauge.
        if (phase == 'released' && cycle == 0) {
          sample.afterQ0Gauge(Timeline.now);
        }
      }

      Future<void> point(
        int cycle,
        String phase,
        Map<String, Object?> wrapper,
      ) async {
        final planned = (activeSchedule['points'] as List)
            .cast<Map>()
            .singleWhere(
              (row) => row['cycle'] == cycle && row['phase'] == phase,
            );
        if (probeOnly) await until(planned['offsetUs'] as int, phase, cycle);
        final started = Timeline.now;
        final prefix = cycle < 0 ? phase : 'cycle-$cycle.$phase';
        final before = await osJournal.request('point', '$phase.before-gc');
        final beforeGauge = await collect(
          '$prefix.before-gc',
          cycle,
          '$phase.before-gc',
          wrapper,
        );
        if (ownershipGaugeFailure(beforeGauge, probeOnly: probeOnly) != null) {
          beforeGauge['abortedBeforeVm'] = true;
          final captured = retentionProbe.capture();
          persist(beforeGauge, captured);
          requireComplete(beforeGauge);
        }
        final allocatorBefore = retentionProbe.capture();
        final vmStart = Timeline.now;
        Map<String, Object?>? observed;
        Map<String, Object?>? afterGauge;
        int? vmEnd, allocatorAfter;
        try {
          try {
            vmProbeCalls++;
            observed = await telemetry.measure();
          } finally {
            vmEnd = Timeline.now;
            // Capture the second wire slot before JSON encoding or OS IO.
            allocatorAfter = retentionProbe.capture();
          }
          final afterIndex = allocatorAfter;
          final vmObservation = observed;
          afterGauge = await collect(
            '$prefix.after-gc',
            cycle,
            '$phase.after-gc',
            wrapper,
          );
          afterGauge['startUs'] = retentionProbe.captureStartUs(afterIndex);
          final after = await osJournal.request('point', '$phase.after-gc');
          persist(beforeGauge, allocatorBefore);
          persist(afterGauge, afterIndex);
          points.add({
            'phase': phase,
            'cycle': cycle,
            'startUs': started,
            'endUs': Timeline.now,
            'vmStartUs': vmStart,
            'vmEndUs': vmEnd,
            'osBefore': before,
            'osAfter': after,
            'vm': vmObservation['vm'],
            'probeTelemetry': vmObservation['telemetry'],
            'recorder': activeJournal.retainedCounts(),
            'wrapperLatestRetained': wrapper['present'],
            'gaugeBeforeId': beforeGauge['id'],
            'gaugeAfterId': afterGauge['id'],
            'nativeCounters': {
              'status': 'recorded-in-owner-gauges',
              'gaugeBeforeId': beforeGauge['id'],
              'gaugeAfterId': afterGauge['id'],
              'values': null,
            },
            'atomic': false,
          });
          requireComplete(beforeGauge);
          requireComplete(afterGauge);
          if ((vmObservation['vm'] as Map)['heapUsedBytes'] == null) {
            throw StateError('VM group observation unavailable');
          }
        } catch (_) {
          // Preserve completed measurements without taking another sample.
          if (!gauges.any((row) => row['id'] == beforeGauge['id'])) {
            beforeGauge['partial'] = true;
            persist(beforeGauge, allocatorBefore);
          }
          final afterIndex = allocatorAfter;
          if (afterIndex != null &&
              !gauges.any((row) => row['id'] == '$prefix.after-gc')) {
            final partial =
                afterGauge ??
                <String, Object?>{
                  'id': '$prefix.after-gc',
                  'cycle': cycle,
                  'phase': '$phase.after-gc',
                  'startUs': retentionProbe.captureStartUs(afterIndex),
                  'captureEndUs': Timeline.now,
                  'images': null,
                  'imageCache': null,
                  'wrapper': null,
                  'worker': null,
                  'fd': null,
                  'atomic': false,
                };
            partial['partial'] = true;
            persist(partial, afterIndex);
          }
          rethrow;
        }
      }

      await gauge('initialization', -1, 'initialization', emptyWrapper);
      origin = Timeline.now;
      await point(-1, 'baseline', emptyWrapper);
      const cycle = 0;
      final planned = (activeSchedule['cycles'] as List)
          .cast<Map>()
          .singleWhere((row) => row['cycle'] == cycle);
      if (probeOnly) {
        await until(planned['startOffsetUs'] as int, 'cycle-start', cycle);
      }
      activeJournal.boundary('cycle-start', cycle);
      final evidence = <String, Object?>{};
      cycles.add(evidence);
      evidence.addAll(createProbeOnlyCycleEvidence(cycle));
      await until(
        planned['workloadEndOffsetUs'] as int,
        'idle-workload-slot-end',
        cycle,
      );
      activeJournal.boundary('cycle-disposed', cycle);
      await quiet(cycle, 'retained', () => emptyWrapper);
      activeJournal.boundary('retained-point', cycle);
      await point(cycle, 'after-close-retained', emptyWrapper);
      await activeJournal.flush('cycle-$cycle.release-prefix');
      activeJournal.boundary('released-prefix', cycle);
      await quiet(cycle, 'released', () => emptyWrapper);
      // Stop at q0. No released checkpoint, end-of-cycle rotation or final quiet.
      evidence['status'] = 'stopped-at-q0';
      expect(points.length, 2);
      expect(gauges.length, 7);
      expect(retentionProbe.captureCount, 7);
      expect(vmProbeCalls, 2);
      expect(
        points.every((p) => (p['vm'] as Map)['heapUsedBytes'] != null),
        isTrue,
      );
      status = 'sampled-q0-captured';
    } catch (error, stack) {
      failure = error.toString();
      failureStack = stack.toString();
    } finally {
      // Cleanup is attempted once, before the unchanged observer finalization.
      try {
        sampledProbe?.closeAndWriteEvidence();
      } catch (error) {
        status = 'failed';
        failure = '$failure; sampled q0 finalization: $error';
      }
      try {
        journal?.stop();
        await journal?.flush('final-received-tail');
        osResult = await os?.finish();
        if (osResult != null) {
          if (osResult['error'] != null) {
            throw StateError('OS sampler incomplete');
          }
          final files = osResult['files'] as List;
          for (var i = 0; i < files.length; i++) {
            final row = Map<String, Object?>.from(files[i] as Map);
            files[i] = {
              ...row,
              ...await describeRawFile(File('${root!.path}/${row['file']}')),
            };
          }
        }
      } catch (error) {
        status = 'failed';
        failure = '$failure; finalization: $error';
      }
      try {
        gaugeOutput?.flushSync();
        gaugeOutput?.closeSync();
        if (gaugeFile != null) {
          rawGauges = {
            ...await describeRawFile(gaugeFile),
            'sampleCount': gauges.length,
          };
        }
      } catch (error) {
        status = 'failed';
        failure = '$failure; gauge persistence: $error';
      } finally {
        imageSummary = imageObserver.close();
        try {
          final probe = retention;
          if (probe != null && root != null) {
            final file = File('${root.path}/allocator-captures.jsonl');
            final output = file.openSync(mode: FileMode.writeOnly);
            try {
              for (var i = 0; i < probe.captureCount; i++) {
                output.writeStringSync('${jsonEncode(probe.rawCapture(i))}\n');
              }
              output.flushSync();
            } finally {
              output.closeSync();
            }
            rawAllocator = {
              ...await describeRawFile(file),
              'sampleCount': probe.captureCount,
            };
          }
        } catch (error) {
          status = 'failed';
          failure = '$failure; allocator persistence: $error';
        } finally {
          retention?.close();
        }
      }
      if (imageSummary['restorationComplete'] != true ||
          imageSummary['priorCallbackFailures'] != 0) {
        status = 'failed';
        failure = '$failure; image observer incomplete';
      }
      final report = <String, Object?>{
        'schema': 'abc.gperftools-sampled-q0-control.v1',
        'workloadId': 'abc.original-probe-only-to-q0',
        'status': status,
        'arm': arm,
        'hostPid': pid,
        'baseProductCommit': _base,
        'buildMode': 'profile',
        'inputFormat': 'none',
        'mode': 'sampled-q0-feasibility',
        'stopBoundary': 'cycle-0.released-quiet-end',
        'plannedCycles': 0,
        'completedCycles': 0,
        'originalEightCycleWorkloadCompleted': false,
        'mappingAcceptanceEstablished': false,
        'fullHeapCoverage': false,
        'productOperations': 0,
        'ticksPerCycle': 0,
        'excludedWarmupCycles': 0,
        'plannedCheckpoints': 2,
        'vmProbeCalls': vmProbeCalls,
        'plannedOwnershipGauges': 7,
        'expectedNativeWorkers': 0,
        'inProcessOsSamplerRetained': true,
        'externalOsSamplerEnabled': false,
        'fixture': null,
        'sampledProbe': sampledProbe?.evidence,
        'runtime': {
          ...memory.runtimeMetadata(),
          'commit': const String.fromEnvironment('PERF_COMMIT'),
          'checkedOutHead': const String.fromEnvironment(
            'PERF_CHECKED_OUT_HEAD',
          ),
          'workingTreeDirty': const bool.fromEnvironment(
            'PERF_WORKTREE_DIRTY',
            defaultValue: true,
          ),
          'flutterVersion': const String.fromEnvironment(
            'PERF_FLUTTER_VERSION',
          ),
          'flutterRevisionPin': '5fc346839b5d0eef006ed8404392afb4dfae428d',
          'renderer': const String.fromEnvironment('PERF_RENDERER'),
          ...memory.runtimeOverrides(),
        },
        'scheduleSha256': scheduleSha,
        'scheduleOriginUs': origin,
        'scheduleObservations': waits,
        'memoryPoints': points,
        'ownershipGauges': gauges,
        'ownershipGaugeWrites': gaugeWriter?.receipts,
        'allocatorInitialization': retention?.initialization,
        'startupIdentityGate': startupIdentityGate,
        'imageObserverSummary': imageSummary,
        'cycles': cycles,
        'raw': {
          'directory': root?.uri.pathSegments.where((s) => s.isNotEmpty).last,
          'frameChunks': journal?.chunks,
          'os': osResult,
          'boundaries': journal?.boundaries,
          'finalCounts': journal?.retainedCounts(),
          'recordingStoppedUs': journal?.stoppedUs,
          'ownershipGauges': rawGauges,
          'allocatorCaptures': rawAllocator,
        },
        'drainPolicy': {
          'frameBarriers': 3,
          'barrierDelayMs': 16,
          'quietMs': 1200,
          'releasePrefixFlushesBeforeQ0': 1,
          'capture': 'all-callbacks-received-until-recordingStoppedUs',
        },
        'failure': failure,
        'failureStack': failureStack,
        'limits': [
          'Single sampled feasibility control; no original workload completion or mapping acceptance.',
          'Only the original two VM group probes before q0 run; no added GC or observer poll.',
          'Sampled live allocations are estimates; no cumulative allocation or complete heap claim.',
          'Native and Dart clocks are separate and are not subtracted.',
          'Image handle events and ImageCache are distinct from graphics/GPU residency.',
          'FD enumeration may include its own descriptor; all reads are non-atomic.',
          'Native tracked bytes and libc statistics overlap and cannot be added to RSS or heap.',
          'No extra GC, cache eviction, trim, threshold relaxation, or excluded first/cancelled work.',
        ],
      };
      final clean = Map<String, dynamic>.from(
        jsonDecode(
          jsonEncode(report).replaceAll(
            RegExp(
              r'''(?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?[^\s<>"']*''',
            ),
            '[redacted-local-service-url]',
          ),
        ) as Map,
      );
      binding.reportData = clean;
      await memory.writeStandaloneReport(clean);
      await telemetry.close();
    }
    expect(status, 'sampled-q0-captured', reason: failure);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
