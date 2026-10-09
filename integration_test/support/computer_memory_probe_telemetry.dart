// Test-only measurement-overhead observation. Never retains VM response bodies.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:vm_service/vm_service.dart';

import 'profile_memory_native.dart' as memory;

class ComputerMemoryProbeTelemetry {
  _ObservedVmService? _service;
  WebSocket? _socket;
  StreamSubscription<String>? _received;
  int _messages = 0, _utf8Bytes = 0, _maximumUtf8Bytes = 0;

  Future<_ObservedVmService> _connect() async {
    final uri = (await developer.Service.getInfo()).serverUri;
    if (uri == null) {
      throw StateError('VM service unavailable');
    }
    // Same VM protocol and in-process client as memorySnapshot's default.
    // No credentials or service URL are written to evidence.
    final socket = await WebSocket.connect(
      uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
    );
    _socket = socket;
    final service = _ObservedVmService(socket, socket.add);
    _received = service.onReceive.listen((message) {
      final bytes = _utf8Length(message);
      _messages++;
      _utf8Bytes += bytes;
      if (bytes > _maximumUtf8Bytes) {
        _maximumUtf8Bytes = bytes;
      }
    });
    return service;
  }

  Future<Map<String, Object?>> measure() async {
    final started = developer.Timeline.now;
    final service = _service ??= await _connect();
    _messages = 0;
    _utf8Bytes = 0;
    _maximumUtf8Bytes = 0;
    service.profileCalls.clear();
    // This unchanged public helper groups isolates before requesting GC/profile
    // and then reads group memory. Decoding that profile is part of the measured
    // process's own allocation overhead, not an inert observer.
    final vm = await memory.memorySnapshot(service: service);
    final ended = developer.Timeline.now;
    return {
      'vm': vm,
      'telemetry': {
        'measurementStartUs': started,
        'measurementEndUs': ended,
        'responseMessages': _messages,
        'responseWireUtf8Bytes': _utf8Bytes,
        'largestResponseWireUtf8Bytes': _maximumUtf8Bytes,
        'responseScope': 'all VM-service responses during this checkpoint',
        'allocationProfiles': List<Map<String, Object?>>.of(
          service.profileCalls,
        ),
        'retainedResponseBodies': 0,
        'gcGuarantee':
            'request-only; dateLastServiceGC is recorded when available',
      },
    };
  }

  Future<void> close() async {
    await _received?.cancel();
    await _service?.dispose();
    await _socket?.close();
  }
}

class _ObservedVmService extends VmService {
  _ObservedVmService(super.inStream, super.writeMessage);
  final profileCalls = <Map<String, Object?>>[];

  @override
  Future<AllocationProfile> getAllocationProfile(
    String isolateId, {
    bool? reset,
    bool? gc,
  }) async {
    final started = developer.Timeline.now;
    final result = await super.getAllocationProfile(
      isolateId,
      reset: reset,
      gc: gc,
    );
    profileCalls.add({
      'startUs': started,
      'endUs': developer.Timeline.now,
      'gcRequested': gc == true,
      'classCount': result.members?.length,
      'dateLastServiceGC': result.dateLastServiceGC,
      'profileReportedHeapUsage': result.memoryUsage?.heapUsage,
      'profileReportedHeapCapacity': result.memoryUsage?.heapCapacity,
      'profileReportedExternalUsage': result.memoryUsage?.externalUsage,
    });
    return result;
  }
}

// Compute transport size without allocating another payload-sized UTF-8 buffer.
int _utf8Length(String value) {
  var bytes = 0;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit < 0x80) {
      bytes++;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xd800 &&
        unit <= 0xdbff &&
        i + 1 < value.length &&
        value.codeUnitAt(i + 1) >= 0xdc00 &&
        value.codeUnitAt(i + 1) <= 0xdfff) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}
