// Synthetic protocol/lifecycle contracts only; no physical CPU or UI evidence.
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

import '../integration_test/support/computerraria_dynamic_backend.dart';
import 'support/computerraria/layout.dart';

const _session = 7;
const _source = WorldCircuitSource.file(
  path: 'unread-unit-test-input.wld',
  length: 1,
  name: 'unit-test-input.wld',
);
final _ticks = WorldCircuitCommand.ticks(6);
final _pixels = WorldCircuitCommand.pixels(6485, 800, 64, 48);

Uint8List _densePixelRecords() {
  // The real protocol uses sorted x/y, type 445, and signed frame coordinates
  // in each 16-byte little-endian record. One actual PixelBox is lit.
  final bytes = Uint8List(3072 * 16);
  final data = ByteData.sublistView(bytes);
  var offset = 0;
  for (var x = 0; x < 64; x++) {
    for (var y = 0; y < 48; y++) {
      data.setUint32(offset, 6485 + x, Endian.little);
      data.setUint32(offset + 4, 800 + y, Endian.little);
      data.setUint32(offset + 8, 445, Endian.little);
      data.setInt16(offset + 12, x == 0 && y == 0 ? 18 : 0, Endian.little);
      data.setInt16(offset + 14, 0, Endian.little);
      offset += 16;
    }
  }
  return bytes;
}

class _SourceBackend implements WorldCircuitSourceBackend {
  final calls = <WorldCircuitCommand>[];
  final pixelRecords = _densePixelRecords();
  Completer<void>? pulseAccepted;
  Completer<void>? releasePulse;
  bool failPulse = false;
  int ticks = 0;
  int pulses = 0;
  WorldCircuitResult? lastPixels;

  WorldCircuitResult snapshot({bool pixels = false}) {
    final stats = List<int>.filled(24, 0);
    stats[0] = 2;
    stats[2] = 15200;
    stats[3] = 7200;
    stats[18] = ticks;
    stats[20] = pulses;
    return WorldCircuitResult(
      _session,
      stats,
      pixels ? pixelRecords : Uint8List(0),
      resultKind: pixels ? 9 : 0,
      resultCount: pixels ? 3072 : 0,
    );
  }

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource source, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async => snapshot();

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List world) =>
      throw StateError('The diagnostic must retain its ranged source path');

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    expect(session, _session);
    calls.add(command);
    if (command.words[1] == 2) {
      pulseAccepted?.complete();
      pulseAccepted = null;
      await releasePulse?.future;
      if (failPulse) throw StateError('Synthetic accepted pulse failed');
      pulses += command.words[8];
    } else if (command.words[1] == 3) {
      ticks += command.words[8];
    } else if (command.words[1] == 9) {
      lastPixels = snapshot(pixels: true);
      return lastPixels!;
    }
    return snapshot();
  }

  @override
  Future<void> closeWorldCircuit(int session) async {}

  @override
  Future<void> cancelWorldCircuitOperation() async {}

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() async => null;

  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) async {}
}

class _BatchBackend extends _SourceBackend implements WorldCircuitBatchBackend {
  bool omitPixels = false;
  int compoundCalls = 0;

  @override
  Future<WorldCircuitBatchResult> commandAndReadPixels(
    int session,
    WorldCircuitCommand command,
    WorldCircuitCommand pixels,
  ) async {
    compoundCalls++;
    final result = await commandWorldCircuit(session, command);
    return WorldCircuitBatchResult(
      command: result,
      pixels: omitPixels ? null : await commandWorldCircuit(session, pixels),
    );
  }
}

Future<ComputerrariaDynamicBackend> _open(_SourceBackend inner) async {
  final backend = ComputerrariaDynamicBackend(inner);
  await backend.openWorldCircuitSource(_source);
  return backend;
}

Future<WorldCircuitBatchResult> _batch(ComputerrariaDynamicBackend backend) =>
    backend.commandAndReadPixels(_session, _ticks, _pixels);

void _expectClockThenOriginalBatch(List<WorldCircuitCommand> calls) {
  expect(calls, hasLength(3));
  expect(calls[0].words, ComputerrariaComputer.clock(128).words);
  expect(calls[0].records, isEmpty);
  expect(calls[1], same(_ticks));
  expect(calls[2], same(_pixels));
}

void main() {
  test(
    'batch capability forwards clock128 then unchanged ticks6 and pixels',
    () async {
      final inner = _BatchBackend();
      final backend = await _open(inner);
      expect(backend, isA<WorldCircuitBatchBackend>());
      expect(backend.completesCircuitBatchFromExternalEvent, isFalse);
      backend.arm('ordered-one', batches: 1);
      final budget = backend.budgetReached;

      final result = await _batch(backend);
      await budget;

      _expectClockThenOriginalBatch(inner.calls);
      expect(inner.compoundCalls, 1);
      expect(result.pixels, same(inner.lastPixels));
      expect(result.pixels!.records, same(inner.pixelRecords));
      expect(result.command.ticks, 6);
      expect(backend.physicalPulses, 128);
      expect(backend.mechanicalTicks, 6);
      expect(backend.completedBatches, 1);
      expect(backend.clockEnabled, isFalse);
      expect(backend.frames, hasLength(1));
      expect(backend.frames.single['recordCount'], 3072);
      expect(backend.frames.single['litPixels'], 1);
      expect(
        backend.frames.single['recordsSha256'],
        sha256.convert(inner.pixelRecords).toString(),
      );
    },
  );

  test(
    'non-batch source fallback preserves the same exact command order',
    () async {
      final inner = _SourceBackend();
      final backend = await _open(inner);
      backend.arm('fallback-one', batches: 1);

      final result = await _batch(backend);
      await backend.budgetReached;

      _expectClockThenOriginalBatch(inner.calls);
      expect(result.pixels, same(inner.lastPixels));
      expect(backend.frames.single['recordCount'], 3072);
      expect(backend.frames.single['litPixels'], 1);
    },
  );

  test(
    'twelve-batch budget stops injection and preserves later mechanical ticks',
    () async {
      final inner = _BatchBackend();
      final backend = await _open(inner);
      backend.arm('fixed-twelve', batches: 12);
      final budget = backend.budgetReached;
      for (var n = 0; n < 12; n++) {
        await _batch(backend);
      }
      await budget;
      expect(backend.clockEnabled, isFalse);
      expect(backend.physicalPulses, 1536);
      expect(backend.mechanicalTicks, 72);
      expect(backend.frames, hasLength(12));
      expect(
        inner.calls.where((command) => command.words[1] == 2),
        hasLength(12),
      );

      final before = inner.calls.length;
      await _batch(backend);

      expect(inner.calls.sublist(before), [same(_ticks), same(_pixels)]);
      expect(backend.physicalPulses, 1536);
      expect(backend.mechanicalTicks, 78);
      expect(inner.ticks, 78);
      expect(backend.completedBatches, 12);
      expect(backend.frames, hasLength(12));
    },
  );

  test('manual disarm before a batch prevents any external pulse', () async {
    final inner = _BatchBackend();
    final backend = await _open(inner);
    backend.arm('manual-pause');
    backend.disarm('explicit-pause-before-batch');

    await _batch(backend);

    expect(inner.calls, [same(_ticks), same(_pixels)]);
    expect(backend.physicalPulses, 0);
    expect(backend.mechanicalTicks, 6);
    expect(backend.frames, isEmpty);
    expect(backend.clockEnabled, isFalse);
  });

  test('armed noncompound ticks reject before any physical mutation', () async {
    final inner = _BatchBackend();
    final backend = await _open(inner);
    backend.arm('reject-unobserved-ticks');

    await expectLater(
      backend.commandWorldCircuit(_session, _ticks),
      throwsStateError,
    );

    expect(inner.calls, isEmpty);
    expect(inner.ticks, 0);
    expect(backend.physicalPulses, 0);
    expect(backend.mechanicalTicks, 0);
    expect(backend.frames, isEmpty);
    backend.disarm('rejected-command-cleanup');
  });

  test(
    'disarm during an accepted pulse drains its original batch once',
    () async {
      final inner = _BatchBackend();
      final accepted = Completer<void>();
      final released = Completer<void>();
      inner.pulseAccepted = accepted;
      inner.releasePulse = released;
      final backend = await _open(inner);
      backend.arm('held-pulse');

      final pending = _batch(backend);
      await accepted.future;
      expect(inner.calls, hasLength(1));
      expect(inner.calls.single.words, ComputerrariaComputer.clock(128).words);
      expect(backend.frames, isEmpty);
      expect(inner.ticks, 0);
      backend.disarm('pause-during-accepted-pulse');
      released.complete();
      await pending;

      _expectClockThenOriginalBatch(inner.calls);
      expect(backend.physicalPulses, 128);
      expect(backend.mechanicalTicks, 6);
      expect(backend.frames, hasLength(1));
      expect(backend.clockEnabled, isFalse);
      final before = inner.calls.length;
      await _batch(backend);
      expect(inner.calls.sublist(before), [same(_ticks), same(_pixels)]);
      expect(backend.physicalPulses, 128);
      expect(backend.mechanicalTicks, 12);
      expect(backend.frames, hasLength(1));
    },
  );

  test(
    'missing compound pixels fail and disarm without fabricating a frame',
    () async {
      final inner = _BatchBackend()..omitPixels = true;
      final backend = await _open(inner);
      backend.arm('missing-pixel-failure');

      await expectLater(_batch(backend), throwsStateError);

      expect(backend.clockEnabled, isFalse);
      expect(backend.physicalPulses, 128);
      expect(inner.ticks, 6);
      expect(backend.frames, isEmpty);
      final failure = backend.events.singleWhere(
        (event) => event['kind'] == 'production-command-and-pixels',
      );
      expect(failure['status'], 'failed');
      expect(failure['error'], contains('pixels'));
      expect(failure['endUs'], isA<int>());
      expect(
        backend.events.where(
          (event) =>
              event['kind'] == 'external-clock-disarm' &&
              event['reason'] == 'failed-batch',
        ),
        hasLength(1),
      );
    },
  );

  test('failed pulse rejects its fixed budget and retains the failed command', () async {
    final inner = _BatchBackend()..failPulse = true;
    final backend = await _open(inner);
    backend.arm('failed-fixed-pulse', batches: 1);
    // Register both handlers before the injected command can complete in error.
    final budgetFailure = expectLater(backend.budgetReached, throwsStateError);
    final batchFailure = expectLater(_batch(backend), throwsStateError);

    await Future.wait([budgetFailure, batchFailure]);

    expect(backend.clockEnabled, isFalse);
    expect(inner.calls, hasLength(1));
    expect(inner.calls.single.words, ComputerrariaComputer.clock(128).words);
    expect(inner.ticks, 0);
    expect(inner.compoundCalls, 0);
    expect(backend.physicalPulses, 0);
    expect(backend.frames, isEmpty);
    final failure = backend.events.singleWhere(
      (event) => event['kind'] == 'native-command',
    );
    expect(failure['status'], 'failed');
    expect(failure['error'], contains('Synthetic accepted pulse failed'));
    expect(failure['endUs'], isA<int>());
  });
}
