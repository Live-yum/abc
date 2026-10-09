import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import '../integration_test/support/profile_memory_native.dart' as memory;

class _Service implements VmService {
  final gcRequests = <String>[];
  final heapRequests = <String>[];
  bool unsupported = false;
  String? exitBeforeGc;
  String? expiredGroup;
  final members = <String, String>{
    'main': 'shared',
    'engine': 'shared',
    'map': 'separate',
  };

  Never _collected(String method) => throw SentinelException.parse(method, {
    'type': 'Sentinel',
    'kind': SentinelKind.kCollected,
  });

  @override
  Future<VM> getVM() async =>
      VM(isolates: members.keys.map((id) => IsolateRef(id: id)).toList());
  @override
  Future<Isolate> getIsolate(String isolateId) async =>
      Isolate(id: isolateId, isolateGroupId: members[isolateId]);
  @override
  Future<AllocationProfile> getAllocationProfile(
    String isolateId, {
    bool? reset,
    bool? gc,
  }) async {
    expect(gc, true);
    if (isolateId == exitBeforeGc) _collected('getAllocationProfile');
    gcRequests.add(isolateId);
    return AllocationProfile();
  }

  @override
  Future<MemoryUsage> getIsolateGroupMemoryUsage(String isolateGroupId) async {
    heapRequests.add(isolateGroupId);
    if (unsupported) throw StateError('getIsolateGroupMemoryUsage unsupported');
    if (isolateGroupId == expiredGroup) {
      throw SentinelException.parse('getIsolateGroupMemoryUsage', {
        'type': 'Sentinel',
        'kind': SentinelKind.kExpired,
      });
    }
    final size = isolateGroupId == 'shared' ? 100 : 200;
    return MemoryUsage(
      heapUsage: size,
      heapCapacity: size * 2,
      externalUsage: size ~/ 10,
    );
  }

  // In particular, a regression to per-isolate getMemoryUsage fails here.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('profile probe counts a shared UI and engine heap once', () async {
    final service = _Service();
    final sample = await memory.memorySnapshot(service: service);
    expect(sample['heapUsedBytes'], 300);
    expect(sample['heapCapacityBytes'], 600);
    expect(sample['externalBytes'], 30);
    expect(sample['sampledIsolates'], 3);
    expect(sample['sampledIsolateGroups'], 2);
    expect(service.gcRequests, ['main', 'map']);
    expect(service.heapRequests, ['shared', 'separate']);
    expect(sample['heapMeasurementMethod'], memory.heapMeasurementMethod);
    expect(sample['gc'], 'requested-all-isolate-groups');
  });
  test('exited representative uses a live member of the same group', () async {
    final service = _Service()..exitBeforeGc = 'main';
    final sample = await memory.memorySnapshot(service: service);
    expect(sample['heapUsedBytes'], 300);
    expect(sample['sampledIsolates'], 2);
    expect(sample['sampledIsolateGroups'], 2);
    expect(sample['exitedIsolatesDuringProbe'], 1);
    expect(service.gcRequests, ['engine', 'map']);
    expect(service.heapRequests, ['shared', 'separate']);
  });
  test(
    'expired group does not invalidate remaining live group evidence',
    () async {
      final service = _Service()..expiredGroup = 'separate';
      final sample = await memory.memorySnapshot(service: service);
      expect(sample['heapUsedBytes'], 100);
      expect(sample['sampledIsolates'], 2);
      expect(sample['sampledIsolateGroups'], 1);
      expect(sample['exitedIsolateGroupsDuringProbe'], 1);
      expect(sample['heapUnavailable'], isNull);
    },
  );
  test(
    'unsupported VM group measurement remains explicitly unavailable',
    () async {
      final service = _Service()..unsupported = true;
      final sample = await memory.memorySnapshot(service: service);
      expect(sample['heapUsedBytes'], isNull);
      expect(sample['heapCapacityBytes'], isNull);
      expect(sample['externalBytes'], isNull);
      expect(sample['gc'], 'unavailable');
      expect(
        sample['heapUnavailable'],
        contains('getIsolateGroupMemoryUsage unsupported'),
      );
    },
  );
}
