import 'dart:developer';
import 'dart:io';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

VmService? _service;

const heapMeasurementMethod = 'vm-service-isolate-groups-v1';

Map<String, Object?> runtimeMetadata() => {
  'platform': Platform.operatingSystem,
  'osVersion': Platform.operatingSystemVersion,
  'dartVersion': Platform.version,
  'processors': Platform.numberOfProcessors,
  'processorModel': _processorModel(),
  'memorySource':
      'ProcessInfo RSS + VM service unique isolate-group heaps after GC',
  'heapMeasurementMethod': heapMeasurementMethod,
};

String? _processorModel() {
  if (!Platform.isLinux) return null;
  try {
    final cpu = File('/proc/cpuinfo').readAsStringSync();
    return RegExp(
      r'^model name\s*:\s*(.+)$',
      multiLine: true,
    ).firstMatch(cpu)?.group(1);
  } catch (_) {
    return null;
  }
}

Map<String, Object?> runtimeOverrides() => {
  if (Platform.environment['TERRA_PERF_RUNNER'] case final String runner
      when runner.isNotEmpty)
    'runner': runner,
  if (Platform.environment['TERRA_PERF_RENDERER'] case final String renderer
      when renderer.isNotEmpty)
    'renderer': renderer,
};

int currentRss() => ProcessInfo.currentRss;

Future<Map<String, Object?>> memorySnapshot({VmService? service}) async {
  var heapUsed = 0, heapCapacity = 0, external = 0;
  var sampledIsolates = 0, sampledGroups = 0;
  var exitedIsolates = 0, exitedGroups = 0;
  String? unavailable;
  try {
    if (service == null) {
      if (_service == null) {
        final info = await Service.getInfo();
        final uri = info.serverUri;
        if (uri == null) throw StateError('VM service not enabled');
        _service = await vmServiceConnectUri(
          uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
        );
      }
      service = _service!;
    }
    final vm = await service.getVM();
    final groups = <String, List<String>>{};
    for (final ref in vm.isolates ?? <IsolateRef>[]) {
      try {
        final isolate = await service.getIsolate(ref.id!);
        final groupId = isolate.isolateGroupId;
        if (groupId == null || groupId.isEmpty) {
          throw StateError('VM service did not identify an isolate group');
        }
        (groups[groupId] ??= []).add(ref.id!);
      } on SentinelException catch (error) {
        if (error.sentinel.kind != SentinelKind.kCollected) rethrow;
        exitedIsolates++;
      }
    }
    for (final entry in groups.entries) {
      // Isolate.spawn shares its group's heap. Summing getMemoryUsage for each
      // isolate would count that heap repeatedly. GC and read it once per group,
      // only between lifecycle/frame windows. A MAP owner may just have exited.
      var collected = true, liveMembers = entry.value.length;
      for (final representative in entry.value) {
        try {
          await service.getAllocationProfile(representative, gc: true);
          collected = false;
          break;
        } on SentinelException catch (error) {
          if (error.sentinel.kind != SentinelKind.kCollected) rethrow;
          exitedIsolates++;
          liveMembers--;
        }
      }
      if (collected) {
        exitedGroups++;
        continue;
      }
      try {
        final memory = await service.getIsolateGroupMemoryUsage(entry.key);
        if (memory.heapUsage == null ||
            memory.heapCapacity == null ||
            memory.externalUsage == null) {
          throw StateError('VM service returned incomplete group memory usage');
        }
        heapUsed += memory.heapUsage!;
        heapCapacity += memory.heapCapacity!;
        external += memory.externalUsage!;
        sampledGroups++;
        sampledIsolates += liveMembers;
      } on SentinelException catch (error) {
        if (error.sentinel.kind != SentinelKind.kExpired &&
            error.sentinel.kind != SentinelKind.kCollected) {
          rethrow;
        }
        exitedGroups++;
      }
    }
    if (sampledGroups == 0) {
      throw StateError('No live isolate-group heap sampled');
    }
  } catch (error) {
    unavailable = error.toString();
  }
  return {
    'rssBytes': ProcessInfo.currentRss,
    'maxRssBytes': ProcessInfo.maxRss,
    'heapUsedBytes': unavailable == null ? heapUsed : null,
    'heapCapacityBytes': unavailable == null ? heapCapacity : null,
    'externalBytes': unavailable == null ? external : null,
    'sampledIsolates': sampledIsolates,
    'sampledIsolateGroups': sampledGroups,
    'exitedIsolatesDuringProbe': exitedIsolates,
    'exitedIsolateGroupsDuringProbe': exitedGroups,
    'heapMeasurementMethod': heapMeasurementMethod,
    'gc': unavailable == null ? 'requested-all-isolate-groups' : 'unavailable',
    'heapUnavailable': ?unavailable,
  };
}

Future<void> closeMemoryProbe() async {
  await _service?.dispose();
  _service = null;
}

Future<void> writeStandaloneReport(Map<String, dynamic> report) async {
  final path = Platform.environment['TERRA_UI_PROFILE_STANDALONE_OUTPUT'];
  if (path == null || path.isEmpty) return;
  final output = File(path);
  await output.parent.create(recursive: true);
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
  );
}
