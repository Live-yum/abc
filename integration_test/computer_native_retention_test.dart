// One fixed-product allocator observation. All eight existing cycles remain.
// Cycles 0–3 cover first-use variants; 4–7 are one repeat, not a plateau test.
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'computer_memory_diagnostic_test.dart' as original;
import 'support/computer_inputs_native.dart' as inputs;
import 'support/computer_memory_journal.dart';
import 'support/native_retention_probe.dart';
import 'support/profile_memory_native.dart' as memory;
import 'support/profile_recorder.dart';

const _base = '661f9f17531e87f0b3f9f7028d70a94814c21234';
const _scheduleSource = '51bc8eaa76b145b0d9bec3c95977779af43b676c';

class _ExternalObserver {
  _ExternalObserver(this.requests, this.acks, this.allocator);
  final NativeRetentionProbe allocator;
  final File requests;
  final Directory acks;
  final endpoints = <Map<String, Object?>>[];
  int sequence = 0;
  Future<Map<String, Object?>> point(
    String phase,
    int cycle, {
    String kind = 'point',
  }) async {
    final observe = phase == 'baseline.pre' || phase.endsWith('-quiet.end');
    final allocatorBefore = observe ? allocator.sample() : null;
    final request = <String, Object?>{
      'kind': kind,
      'sequence': sequence++,
      'hostPid': pid,
      'phase': phase,
      'cycle': cycle,
      'dartTimeUs': Timeline.now,
    };
    requests.writeAsStringSync(
      '${jsonEncode(request)}\n',
      mode: FileMode.append,
      flush: true,
    );
    final reply = File('${acks.path}/ack-${request['sequence']}.json');
    final watch = Stopwatch()..start();
    while (!reply.existsSync()) {
      if (watch.elapsed > const Duration(seconds: 10)) {
        throw StateError('External OS observer acknowledgement timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final value = Map<String, Object?>.from(
      jsonDecode(reply.readAsStringSync()) as Map,
    );
    if (value['sequence'] != request['sequence'] || value['ok'] != true) {
      throw StateError('External OS observation failed: ${value['error']}');
    }
    final allocatorAfter = observe ? allocator.sample() : null;
    final endpoint = <String, Object?>{
      ...request,
      'acknowledgedDartTimeUs': Timeline.now,
      'os': (value['row'] as Map)['os'],
      'mappingCategories': (value['row'] as Map)['categories'],
      'allocatorBefore': allocatorBefore,
      'allocatorAfter': allocatorAfter,
    };
    endpoints.add(endpoint);
    return endpoint;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('fixed-product native allocator retention observation', (
    tester,
  ) async {
    if (!kProfileMode || !Platform.isLinux) {
      fail('Real Linux profile required');
    }
    const arm = 'native-retention';
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final scheduleFile = File(Platform.environment['ABC_CONTROL_SCHEDULE']!);
    final scheduleBytes = await scheduleFile.readAsBytes();
    final schedule = jsonDecode(utf8.decode(scheduleBytes)) as Map;
    expect(schedule['schema'], 'abc.memory-probe-control-schedule.v1');
    expect((schedule['source'] as Map)['commit'], _scheduleSource);
    expect((schedule['points'] as List).length, 17);
    final root = Directory(Platform.environment['ABC_MEMORY_RAW_DIRECTORY']!);
    if (root.existsSync()) {
      fail('New raw directory required');
    }
    await root.create(recursive: true);
    final allocatorRawFile = File(
      Platform.environment['ABC_RETENTION_PROBE_JOURNAL']!,
    );
    final allocator = NativeRetentionProbe.open(
      Platform.environment['ABC_RETENTION_HELPER']!,
      journal: allocatorRawFile,
    );
    final allocatorInitialization = allocator.sample();
    addTearDown(allocator.close);
    final external = _ExternalObserver(
      File(Platform.environment['ABC_CONTROL_REQUESTS']!),
      Directory(Platform.environment['ABC_CONTROL_ACK_DIRECTORY']!),
      allocator,
    );
    if (external.requests.existsSync()) {
      fail('New external request journal required');
    }
    await external.point('hello', -1, kind: 'hello');
    // Reuse the exact fixed-product eight-cycle action body without edits.
    final source = await inputs.computerInput();
    final recorder = ProfileRecorder(
      frameBudgetUs: 1000000 / 60,
      profile: true,
      currentRss: memory.currentRss,
    );
    final journal = ComputerMemoryJournal(root, recorder)..start();
    ComputerMemoryOsJournal? os;
    final points = <Map<String, Object?>>[], cycles = <Map<String, Object?>>[];
    final waits = <Map<String, Object?>>[];
    Map<String, Object?>? osResult;
    Map<String, Object?>? allocatorJournal;
    var origin = 0, status = 'failed';
    String? failure, failureStack;

    Map plannedPoint(int cycle, String phase) => (schedule['points'] as List)
        .cast<Map>()
        .singleWhere((p) => p['cycle'] == cycle && p['phase'] == phase);
    int boundaryOffset(int cycle, String phase) =>
        ((schedule['boundaries'] as List).cast<Map>().firstWhere(
              (b) => b['cycle'] == cycle && b['phase'] == phase,
            )['offsetUs'])
            as int;
    Future<void> until(int offset, String phase, int cycle) async {
      final remaining = origin + offset - Timeline.now;
      if (remaining > 0) {
        await Future<void>.delayed(Duration(microseconds: remaining));
      }
      waits.add({
        'cycle': cycle,
        'phase': phase,
        'plannedOffsetUs': offset,
        'actualOffsetUs': Timeline.now - origin,
        'lateUs': (Timeline.now - origin - offset).clamp(0, 1 << 62),
      });
    }

    Future<void> quiet(int cycle, String name) async {
      journal.boundary('drain-start', cycle);
      await external.point('$name.start', cycle);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      journal.boundary('drain-end', cycle);
      await external.point('$name.end', cycle);
    }

    Future<void> point(int cycle, String phase, bool wrapper) async {
      final planned = plannedPoint(cycle, phase);
      await until(planned['startOffsetUs'] as int, phase, cycle);
      final start = Timeline.now;
      final beforeExternal = await external.point('$phase.pre', cycle);
      final before = await os!.request('point', '$phase.before-slot');
      final vmStart = Timeline.now;
      // Same predeclared nominal slot; no VM-service API is called.
      await Future<void>.delayed(
        Duration(
          microseconds:
              (planned['vmEndOffsetUs'] as int) -
              (planned['vmStartOffsetUs'] as int),
        ),
      );
      final vmEnd = Timeline.now;
      final after = await os!.request('point', '$phase.after-slot');
      final afterExternal = await external.point('$phase.post', cycle);
      points.add({
        'cycle': cycle,
        'phase': phase,
        'startUs': start,
        'endUs': Timeline.now,
        'slotStartUs': vmStart,
        'slotEndUs': vmEnd,
        'planned': planned,
        'vmProbeInvoked': false,
        'vm': null,
        'probeTelemetry': null,
        'osBefore': before,
        'osAfter': after,
        'externalBefore': beforeExternal,
        'externalAfter': afterExternal,
        'recorder': journal.retainedCounts(),
        'wrapperLatestRetained': wrapper,
        'atomic': false,
      });
    }

    try {
      os = await ComputerMemoryOsJournal.start(root);
      origin = Timeline.now;
      await point(-1, 'baseline', false);
      await external.point('pre-next-work', -1);
      for (var cycle = 0; cycle < 8; cycle++) {
        await until(boundaryOffset(cycle, 'cycle-start'), 'cycle-start', cycle);
        journal.boundary('cycle-start', cycle);
        final evidence = <String, Object?>{};
        cycles.add(evidence);
        evidence['predeclaredRole'] = cycle < 4
            ? 'warm-up-variant'
            : 'single-repeat-variant';
        final backend = await original.runComputerMemoryDiagnosticCycle(
          tester: tester,
          cycle: cycle,
          source: source,
          journal: journal,
          os: os,
          evidence: evidence,
        );
        await quiet(cycle, 'retained-quiet');
        journal.boundary('retained-point', cycle);
        await point(cycle, 'after-close-retained', backend.latest != null);
        await journal.flush('cycle-$cycle.release-prefix');
        backend.latest = null;
        journal.boundary('released-prefix', cycle);
        await quiet(cycle, 'released-quiet');
        await journal.flush('cycle-$cycle.late-tail');
        journal.boundary('released-point', cycle);
        await point(cycle, 'after-close-released', false);
        await external.point('pre-next-work', cycle);
        await os.request('rotate', 'cycle-$cycle.end');
        journal.boundary('cycle-end', cycle);
      }
      await quiet(8, 'final-quiet');
      status = 'observed';
    } catch (error, stack) {
      failure = error.toString();
      failureStack = stack.toString();
    } finally {
      journal.stop();
      try {
        await journal.flush('final-received-tail');
        osResult = await os?.finish();
        if (osResult != null) {
          if (osResult['error'] != null) {
            throw StateError('In-process sampler failed');
          }
          final files = osResult['files'] as List;
          for (var i = 0; i < files.length; i++) {
            final row = Map<String, Object?>.from(files[i] as Map);
            files[i] = {
              ...row,
              ...await describeRawFile(File('${root.path}/${row['file']}')),
            };
          }
        }
        await external.point('recording-stopped', 8, kind: 'finish');
      } catch (error) {
        status = 'failed';
        failure = '$failure; finalization: $error';
      }
      try {
        allocator.closeJournal();
        allocatorJournal = {
          ...await describeRawFile(allocatorRawFile),
          'count': allocator.observations.length,
        };
      } catch (error) {
        status = 'failed';
        failure = '$failure; allocator journal: $error';
      }
      final report = <String, Object?>{
        'schema': 'abc.native-retention.v1',
        'status': status,
        'arm': arm,
        'hostPid': pid,
        'baseProductCommit': _base,
        'buildMode': 'profile',
        'inputFormat': 'wld-only',
        'scope': 'one fixed-product eight-cycle allocator observation',
        'warmupCycles': [0, 1, 2, 3],
        'repeatCycles': [4, 5, 6, 7],
        'plateauEstablished': false,
        'allocatorInitialization': allocatorInitialization,
        'allocatorCalls': allocator.observations,
        'allocatorJournal': allocatorJournal,
        'allocatorBufferBytes': 128,
        'plannedAllocatorBoundaries': 18,
        'plannedAllocatorCalls': 37,
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
        'scheduleSha256': sha256.convert(scheduleBytes).toString(),
        'scheduleOriginUs': origin,
        'plannedCycles': 8,
        'completedCycles': cycles
            .where((c) => c['status'] == 'completed')
            .length,
        'plannedCheckpoints': 17,
        'vmProbeCalls': 0,
        'expectedNativeWorkers': 1,
        'inProcessOsSamplerRetained': true,
        'externalOsSamplerEnabled': true,
        'memoryPoints': points,
        'cycles': cycles,
        'scheduleObservations': waits,
        'externalEndpoints': external.endpoints,
        'raw': {
          'directory': root.uri.pathSegments.where((s) => s.isNotEmpty).last,
          'frameChunks': journal.chunks,
          'os': osResult,
          'boundaries': journal.boundaries,
          'finalCounts': journal.retainedCounts(),
          'recordingStoppedUs': journal.stoppedUs,
        },
        'drainPolicy': schedule['drainPolicy'],
        'failure': failure,
        'failureStack': failureStack,
        'limits': [
          'Every cycle, startup and tail remains. Warm-up covers first-use variants; the last four cycles are one repeat per variant, not a plateau or long-term leak test.',
          'mallinfo2 counts allocator-accounted in-use and free arena space, not application ownership or physical residence. Thread caches and allocator metadata limit interpretation.',
          'Arena locks are acquired individually. Allocator and OS observations are non-atomic, with every timing boundary retained.',
          'No VM memory probes (AllocationProfile/GC), forced GC, malloc_trim, allocator tuning, new threshold or FPS certification. The unchanged profile integration driver may use VM service.',
          'RSS/PSS/USS and allocator views overlap; no allocator number is subtracted from RSS or added to another view.',
          'The old public schedule supplies nominal waits only. It does not identify the measured final product.',
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
    }
    expect(status, 'observed', reason: failure);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
