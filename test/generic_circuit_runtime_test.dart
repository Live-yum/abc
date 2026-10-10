import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/circuit_display.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

class _Backend implements WorldCircuitBackend, WorldCircuitBatchBackend {
  bool lit = false, failPixels = false, failBatchRead = false;
  int mutations = 0, ticks = 0, batches = 0;
  WorldCircuitResult result([Uint8List? records, int kind = 0]) {
    final stats = List<int>.filled(24, 0)
      ..[2] = 900 ..[3] = 600 ..[18] = ticks;
    return WorldCircuitResult(1, stats, records ?? Uint8List(0),
        resultKind: kind, reserved: 4);
  }
  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List bytes) async => result();
  @override
  Future<void> closeWorldCircuit(int session) async {}
  @override
  Future<WorldCircuitResult> commandWorldCircuit(
      int session, WorldCircuitCommand command) async {
    final kind = command.words[1];
    if (kind == 2 || kind == 3) {
      mutations++;
      lit = !lit;
      if (kind == 3) ticks += command.words[8];
    }
    if (kind == 9) {
      if (failPixels) throw StateError('pixel read failed');
      final bytes = Uint8List(16), data = ByteData(16);
      data.setUint32(0, 17, Endian.little);
      data.setUint32(4, 23, Endian.little);
      data.setUint32(8, 445, Endian.little);
      data.setInt16(12, lit ? 18 : 0, Endian.little);
      bytes.setAll(0, data.buffer.asUint8List());
      return result(bytes, 9);
    }
    return result();
  }
  @override
  Future<WorldCircuitBatchResult> commandAndReadPixels(int session,
      WorldCircuitCommand command, WorldCircuitCommand pixels) async {
    batches++;
    final receipt = await commandWorldCircuit(session, command);
    if (failBatchRead) {
      return WorldCircuitBatchResult(command: receipt, readError: 'read failed');
    }
    return WorldCircuitBatchResult(command: receipt,
        pixels: await commandWorldCircuit(session, pixels));
  }
}

void main() {
  const region = CircuitDisplayRegion('arbitrary device', 17, 23, 2, 2);
  testWidgets('generic ticks publish locally after the first dirty transition',
      (tester) async {
    final backend = _Backend();
    final session = WorldCircuitSession(backend, Uint8List(1));
    await session.open();
    await session.command(WorldCircuitCommand.viewport(10, 20, 10, 10));
    await session.readDisplay(region);
    final reasons = <bool>[];
    session.addListener(() => reasons.add(session.isRuntimeFramePublication));
    session.run();
    reasons.clear();
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.ticks, 6);
    expect(reasons, [false]);
    expect(session.displayFrame!.first, 255);
    reasons.clear();
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.ticks, 12);
    expect(reasons, [true]);
    expect(session.displayFrame!.first, 0);
    expect(backend.batches, 2);
    session.pause();
    await tester.pump(const Duration(seconds: 1));
    expect(backend.ticks, 12);
    await session.close();
    session.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
  for (final runtime in [false, true]) {
    test('committed mutation survives failed read, runtime=$runtime', () async {
      final backend = _Backend();
      final session = WorldCircuitSession(backend, Uint8List(1));
      await session.open();
      await session.readDisplay(region);
      final previous = session.displayFrame;
      final busyStates = <bool>[], reasons = <bool>[];
      session.addListener(() {
        busyStates.add(session.busy);
        reasons.add(session.isRuntimeFramePublication);
      });
      backend.failBatchRead = true;
      final command = WorldCircuitCommand.trigger(7, 9);
      await expectLater(runtime ? session.runtimeCommand(command)
          : session.command(command, refreshViewport: true), throwsStateError);
      expect(backend.mutations, 1);
      expect(backend.batches, 1);
      expect(session.dirty, isTrue);
      expect(session.displayFrame, same(previous));
      expect(session.running, isFalse);
      expect(busyStates.last, isFalse);
      expect(reasons, everyElement(isFalse));
      await session.close();
      session.dispose();
    });
  }
  test('failed ROI replacement preserves state; successful retry clears error', () async {
    final backend = _Backend();
    final session = WorldCircuitSession(backend, Uint8List(1));
    await session.open();
    await session.refreshDisplay();
    await session.readDisplay(region);
    final image = session.displayFrame, identity = session.displayIdentity;
    backend.failPixels = true;
    await expectLater(session.readDisplay(
        const CircuitDisplayRegion('other', 0, 0, 4, 4)), throwsStateError);
    expect(session.displayRegion, same(region));
    expect(session.displayFrame, same(image));
    expect(session.displayIdentity, same(identity));
    expect(session.error, isNotNull);
    backend.failPixels = false;
    await session.refreshDisplay();
    expect(session.error, isNull);
    backend.failPixels = true;
    await expectLater(session.readDisplay(region), throwsStateError);
    backend.failPixels = false;
    await session.readDisplay(region);
    expect(session.error, isNull);
    await session.close();
    session.dispose();
  });
}
