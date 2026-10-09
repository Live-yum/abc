import 'dart:developer';
import 'dart:io';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

VmService? _service;

Map<String, Object?> runtimeMetadata() => {
  'platform': Platform.operatingSystem,
  'osVersion': Platform.operatingSystemVersion,
  'dartVersion': Platform.version,
  'processors': Platform.numberOfProcessors,
  'processorModel': _processorModel(),
  'memorySource': 'ProcessInfo RSS + VM service all-isolate heaps after GC',
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

Future<Map<String, Object?>> memorySnapshot() async {
  var heapUsed = 0, heapCapacity = 0, external = 0;
  var sampledIsolates = 0, exitedIsolates = 0;
  String? unavailable;
  try {
    if (_service == null) {
      final info = await Service.getInfo();
      final uri = info.serverUri;
      if (uri == null) throw StateError('VM service not enabled');
      _service = await vmServiceConnectUri(
        uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
      );
    }
    final vm = await _service!.getVM();
    for (final isolate in vm.isolates ?? <IsolateRef>[]) {
      // This runs only between complete lifecycle cycles, never in frame windows.
      try {
        await _service!.getAllocationProfile(isolate.id!, gc: true);
        final memory = await _service!.getMemoryUsage(isolate.id!);
        heapUsed += memory.heapUsage ?? 0;
        heapCapacity += memory.heapCapacity ?? 0;
        external += memory.externalUsage ?? 0;
        sampledIsolates++;
      } on SentinelException catch (error) {
        // A just-closed MAP/compute owner can exit after getVM lists it.
        if (error.sentinel.kind != SentinelKind.kCollected) rethrow;
        exitedIsolates++;
      }
    }
    if (sampledIsolates == 0) throw StateError('No live isolate heap sampled');
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
    'exitedIsolatesDuringProbe': exitedIsolates,
    'gc': unavailable == null ? 'requested-all-isolates' : 'unavailable',
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
