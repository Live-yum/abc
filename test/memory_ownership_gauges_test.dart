import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/native_engine.dart' as core;
import 'package:terraforge/engine/native_memory_ownership_diagnostics.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

import '../integration_test/support/memory_ownership_gauges.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup gate rejects wrong or incomplete identity before sampling', () {
    const commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const build = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final valid = <String, Object?>{
      'schema': 'abc.memory-ownership-ready.v1', 'arm': 'probe-only',
      'hostPid': 123, 'sourceCommit': commit, 'baseProductCommit': base,
      'buildSha256': build,
    };
    Map<String, Object?> validate(Object? value) => validateOwnershipReady(value,
        arm: 'probe-only', hostPid: 123, sourceCommit: commit,
        baseProductCommit: base, readyReceivedUs: 456);
    expect(validate(valid), {...valid, 'readyReceivedUs': 456});
    for (final key in valid.keys) {
      final missing = {...valid}..remove(key);
      expect(() => validate(missing), throwsStateError);
      expect(() => validate({...valid, key: null}), throwsStateError);
    }
    for (final change in <Map<String, Object?>>[
      {'schema': 'wrong'}, {'arm': 'product-with-ownership'}, {'hostPid': 124},
      {'hostPid': 123.0},
      {'sourceCommit': base}, {'baseProductCommit': commit},
      {'buildSha256': ''}, {'buildSha256': List.filled(63, '0').join()},
      {'extra': 'rejected'},
    ]) {
      expect(() => validate({...valid, ...change}), throwsStateError);
    }
    expect(() => validate(null), throwsStateError);
    expect(() => validate([]), throwsStateError);
  });

  Map<String, Object?> gaugeWithWorker(int cycle, String status,
      {String nativeStatus = 'available'}) => {
    'cycle': cycle,
    'images': {
      'callbacksIntact': true, 'everReplaced': false, 'priorCallbackFailures': 0,
    },
    'fd': {'status': 'observed'},
    'worker': {
      'status': status,
      'owner': status == 'acknowledged' ? {
        'native': {'status': nativeStatus},
      } : null,
    },
  };

  test('product postcycle requires acknowledgement, idle requires no worker', () {
    for (final cycle in [0, 7, 8]) {
      expect(ownershipGaugeFailure(gaugeWithWorker(cycle, 'acknowledged'),
          probeOnly: false), isNull);
      for (final status in ['worker-not-started', 'failed']) {
        expect(ownershipGaugeFailure(gaugeWithWorker(cycle, status),
            probeOnly: false), isNotNull);
      }
      expect(ownershipGaugeFailure(gaugeWithWorker(cycle, 'acknowledged',
          nativeStatus: 'unavailable'), probeOnly: false), isNotNull);
    }
    expect(ownershipGaugeFailure(gaugeWithWorker(-1, 'worker-not-started'),
        probeOnly: false), isNull);
    expect(ownershipGaugeFailure(gaugeWithWorker(-1, 'acknowledged'),
        probeOnly: false), isNotNull);
    for (final cycle in [-1, 0, 7, 8]) {
      expect(ownershipGaugeFailure(gaugeWithWorker(cycle, 'worker-not-started'),
          probeOnly: true), isNull);
      expect(ownershipGaugeFailure(gaugeWithWorker(cycle, 'acknowledged'),
          probeOnly: true), isNotNull);
    }
  });

  test('gauge write receipts measure completed bytes without row mutation', () {
    final output = <int>[];
    var flushes = 0;
    final writer = OwnershipGaugeWriter(
      write: output.addAll,
      flush: () { flushes++; },
    );
    final row = <String, Object?>{'id': 'fixture-\u03bc', 'sequence': 0};
    final before = jsonEncode(row);
    writer.write(row);
    expect(jsonEncode(row), before);
    expect(utf8.decode(output), '$before\n');
    expect(flushes, 1);
    final receipt = writer.receipts.single;
    expect(receipt['id'], row['id']);
    expect(receipt['sequence'], 0);
    expect(receipt['status'], 'written');
    expect(receipt['bytes'], output.length);
    expect(receipt['endUs'], greaterThanOrEqualTo(receipt['startUs'] as int));
    row['id'] = 'changed-after-write';
    expect(receipt['id'], 'fixture-\u03bc');
  });

  test('failed flush records uncertain bytes and rethrows without retry', () {
    var writes = 0, flushes = 0;
    final writer = OwnershipGaugeWriter(
      write: (_) { writes++; },
      flush: () { flushes++; throw StateError('fixture failure'); },
    );
    final row = <String, Object?>{'id': 'fixture', 'sequence': 0};
    expect(() => writer.write(row), throwsStateError);
    expect(writes, 1);
    expect(flushes, 1);
    final receipt = writer.receipts.single;
    expect(receipt['status'], 'failed');
    expect(receipt['bytes'], isNull);
    expect(receipt['endUs'], greaterThanOrEqualTo(receipt['startUs'] as int));
    expect(row, {'id': 'fixture', 'sequence': 0});
  });

  test('diagnostic access cannot initialize a native owner', () async {
    if (memoryOwnershipDiagnosticsEnabled) {
      final row = await core.diagnosticOwnerSnapshot();
      expect(row['status'], 'worker-not-started');
      expect(row['workerGeneration'], isNull);
      expect(row['owner'], isNull);
      expect(row['productionPendingBefore'], 0);
      expect(row['productionPendingAfter'], 0);
    } else {
      expect(core.diagnosticOwnerSnapshot, throwsStateError);
    }
  });

  test('native owner scalar parser rejects ABI and censor contradictions', () {
    final words = Uint64List(16)
      ..[0] = 1
      ..[1] = 16;
    final parsed = parseNativeOwnerWords(words);
    expect((parsed['values'] as Map).length, 9);
    expect(parsed['rawWords'], words.toList());
    words[2] = 0xffffffff;
    expect(() => parseNativeOwnerWords(words), throwsStateError);
    words[11] = 1;
    expect(parseNativeOwnerWords(words)['censoredMask'], 1);
    words[15] = 1;
    expect(() => parseNativeOwnerWords(words), throwsStateError);
    words[15] = 0;
    words[1] = 15;
    expect(() => parseNativeOwnerWords(words), throwsStateError);
  });

  test('FD observer reports self-entry disappearance without subtracting one', () {
    const secret = '/private/example-do-not-serialize/file.wld';
    final observer = OwnFdObserver(
      supported: () => true,
      listNumericCandidates: () => ['0', '1', '2', '3', '4', '5', 'noise'],
      resolveTarget: (name) => switch (name) {
        '0' => secret,
        '1' => 'pipe:[1234]',
        '2' => 'socket:[4321]',
        '3' => 'anon_inode:[eventpoll]',
        '4' => 'unknown-kind',
        _ => throw const FileSystemException(
          'sensitive target must never be saved', secret, OSError('gone', 2)),
      },
    );
    final row = observer.sample();
    expect(row['status'], 'observed');
    expect(row['fdEntriesEnumerated'], 6);
    expect(row['vanished'], 1);
    expect(row['unreadable'], 0);
    expect(row['ignoredNonnumeric'], 1);
    expect(row['categories'], {
      'socket': 1, 'pipe': 1, 'anonymous-inode': 1, 'path-like': 1, 'other': 1,
    });
    expect(row['probeDescriptorMayBeIncluded'], isTrue);
    expect(jsonEncode(row), isNot(contains(secret)));
    expect(jsonEncode(row), isNot(contains('sensitive target')));
  });

  test('FD failure stays null and prevents further enumeration', () {
    var reads = 0;
    final observer = OwnFdObserver(
      supported: () => true,
      listNumericCandidates: () {
        reads++;
        throw const FileSystemException('private-path', '/never-emit',
            OSError('denied', 13));
      },
    );
    final first = observer.sample(), second = observer.sample();
    expect(first['status'], 'incomplete');
    expect(first['fdEntriesEnumerated'], isNull);
    expect(first['categories'], isNull);
    expect(first['errorCode'], 13);
    expect(second['status'], 'stopped-after-incomplete');
    expect(reads, 1);
    expect(jsonEncode(first), isNot(contains('never-emit')));
  });

  test('FD ceiling stops later calls without resolving excess entries', () {
    var listings = 0, resolutions = 0;
    final observer = OwnFdObserver(
      supported: () => true,
      listNumericCandidates: () {
        listings++;
        return List.generate(4097, (index) => '$index');
      },
      resolveTarget: (_) { resolutions++; return '/fixture'; },
    );
    expect(observer.sample()['errorKind'], 'enumeration-ceiling-exceeded');
    expect(observer.sample()['status'], 'stopped-after-incomplete');
    expect(listings, 1);
    expect(resolutions, 0);
  });

  test('FD unsupported is not zero', () {
    final row = OwnFdObserver(supported: () => false).sample();
    expect(row['status'], 'unsupported');
    expect(row['fdEntriesEnumerated'], isNull);
    expect(row['categories'], isNull);
  });

  test('wrapper report has lengths without byte buffers or source paths', () {
    final result = WorldCircuitResult(1, [2, 0], Uint8List(12),
        world: Uint8List(8), objects: Uint8List(4),
        worldSource: const WorldCircuitSource.file(
          path: '/private-do-not-save', length: 405983441,
          name: 'source.wld', token: 'private-token',
        ));
    final row = wrapperResultSnapshot(result);
    expect(row['recordsLength'], 12);
    expect(row['worldLength'], 8);
    expect(row['objectsLength'], 4);
    expect(row['sourceTokenPresent'], isTrue);
    expect(row.values.every((value) => value is bool || value is int), isTrue);
    expect(jsonEncode(row), isNot(contains('private')));
  });

  test('image callbacks chain and restore, including clone handles', () async {
    final previousCreate = ui.Image.onCreate, previousDispose = ui.Image.onDispose;
    var priorCreates = 0, priorDisposes = 0;
    void create(ui.Image image) { priorCreates++; previousCreate?.call(image); }
    void dispose(ui.Image image) { priorDisposes++; previousDispose?.call(image); }
    ui.Image.onCreate = create;
    ui.Image.onDispose = dispose;
    final observer = ImageOwnershipObserver()..install();
    try {
      final image = await createTestImage(width: 1, height: 1, cache: false);
      final beforeClone = observer.created;
      final clone = image.clone();
      expect(observer.created, beforeClone + 1);
      clone.dispose();
      image.dispose();
      final row = observer.snapshot();
      expect(row['callbacksIntact'], isTrue);
      expect(row['observedHandleBalance'], 0);
      expect(priorCreates, observer.created);
      expect(priorDisposes, observer.disposed);
      expect(observer.close()['restorationComplete'], isTrue);
      expect(ui.Image.onCreate, same(create));
      expect(ui.Image.onDispose, same(dispose));
    } finally {
      observer.close();
      ui.Image.onCreate = previousCreate;
      ui.Image.onDispose = previousDispose;
    }
  });

  test('image observer preserves a later handler and reports incomplete', () {
    final previousCreate = ui.Image.onCreate, previousDispose = ui.Image.onDispose;
    final observer = ImageOwnershipObserver()..install();
    void replacement(ui.Image _) {}
    ui.Image.onCreate = replacement;
    try {
      expect(observer.snapshot()['callbacksIntact'], isFalse);
      expect(observer.close()['restorationComplete'], isFalse);
      expect(ui.Image.onCreate, same(replacement));
    } finally {
      ui.Image.onCreate = previousCreate;
      ui.Image.onDispose = previousDispose;
    }
  });
}
