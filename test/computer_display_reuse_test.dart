import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

import 'support/computer_circuit_backend.dart';
import 'support/computer_display_frames.dart';

void main() {
  const region = ComputerDisplayRegion('test', 20, 30, 2, 2);
  test('unchanged unordered pixels reuse RGBA without allocating another', () {
    var allocations = 0;
    Uint8List allocate(int length) {
      allocations++;
      return Uint8List(length);
    }

    final first = region.decode(displayFrame(region), allocateRgba: allocate);
    expect(allocations, 1);
    final before = sha256.convert(first);
    for (var i = 0; i < 32; i++) {
      final result = region.decode(
        displayFrame(region, reversed: i.isOdd),
        previous: first,
        previousRegion: region,
        allocateRgba: allocate,
      );
      expect(result, same(first));
    }
    expect(allocations, 1);
    expect(sha256.convert(first), before);
  });

  test('a changed frame allocates once and never mutates a published frame', () {
    final first = region.decode(displayFrame(region));
    final before = Uint8List.fromList(first);
    final response = displayFrame(region, reversed: true);
    // Change a late record: earlier validated pixels have arbitrary positions.
    final data = ByteData.sublistView(response.records);
    data.setInt16(3 * 16 + 12, 18, Endian.little);
    var allocations = 0;
    final changed = region.decode(
      response,
      previous: first,
      previousRegion: region,
      allocateRgba: (length) {
        allocations++;
        return Uint8List(length);
      },
    );
    expect(allocations, 1);
    expect(changed, isNot(same(first)));
    expect(changed, referenceDisplayDecode(region, response));
    expect(first, before);
    expect(
      sha256.convert(changed),
      sha256.convert(referenceDisplayDecode(region, response)),
    );
  });

  test('missing or wrongly sized previous pixels produce a complete new frame', () {
    final response = displayFrame(region);
    for (final previous in <Uint8List?>[
      null,
      Uint8List(0),
      Uint8List(15),
      Uint8List(17),
    ]) {
      final result = region.decode(
        response,
        previous: previous,
        previousRegion: region,
      );
      expect(result, referenceDisplayDecode(region, response));
      expect(result, isNot(same(previous)));
    }
  });

  test('monitor name, origin, and dimensions require a new frame', () {
    final previous = region.decode(displayFrame(region));
    for (final next in const [
      ComputerDisplayRegion('other', 20, 30, 2, 2),
      ComputerDisplayRegion('test', 21, 30, 2, 2),
      ComputerDisplayRegion('test', 20, 31, 2, 2),
      ComputerDisplayRegion('test', 20, 30, 1, 4),
      ComputerDisplayRegion('test', 20, 30, 4, 1),
    ]) {
      final response = displayFrame(next);
      final result = next.decode(
        response,
        previous: previous,
        previousRegion: region,
      );
      expect(result, isNot(same(previous)));
      expect(result, referenceDisplayDecode(next, response));
    }
    expect(
      region.decode(displayFrame(region), previous: previous),
      isNot(same(previous)),
      reason: 'A frame without its monitor descriptor cannot be reused.',
    );
  });

  final invalid = <String, void Function(ByteData)>{
    'duplicate': (d) {
      d.setUint32(16, 20, Endian.little);
      d.setUint32(20, 30, Endian.little);
    },
    'x outside': (d) => d.setUint32(0, 19, Endian.little),
    'y outside': (d) => d.setUint32(4, 32, Endian.little),
    'foreign tile': (d) => d.setUint32(8, 419, Endian.little),
    'negative frame': (d) => d.setInt16(12, -18, Endian.little),
    'invalid frame': (d) => d.setInt16(12, 17, Endian.little),
    'extra frame': (d) => d.setInt16(12, 36, Endian.little),
    'foreign row': (d) => d.setInt16(14, 18, Endian.little),
  };
  for (final entry in invalid.entries) {
    for (final phase in [0, 1]) {
      test('${entry.key}, phase $phase preserves validation and old pixels', () {
        final previous = region.decode(displayFrame(region));
        final before = Uint8List.fromList(previous);
        final response = displayFrame(region, phase: phase);
        entry.value(ByteData.sublistView(response.records));
        expect(
          () => region.decode(
            response,
            previous: previous,
            previousRegion: region,
          ),
          throwsFormatException,
        );
        expect(previous, before);
      });
    }
  }
  test('invalid result kind and truncated frames preserve validation', () {
    final previous = region.decode(displayFrame(region));
    for (final response in [
      WorldCircuitResult(1, const [], Uint8List(64), resultKind: 1),
      WorldCircuitResult(1, const [], Uint8List(48), resultKind: 9),
    ]) {
      expect(
        () => region.decode(
          response,
          previous: previous,
          previousRegion: region,
        ),
        throwsFormatException,
      );
    }
  });

  test('session refresh reuses pixels and reset discards its frame owner', () async {
    final backend = ComputerCircuitBackend();
    final session = WorldCircuitSession.fromSource(
      backend,
      const WorldCircuitSource.file(
        path: '/fixture/computer.wld',
        length: 405983441,
        name: 'computer.wld',
      ),
    );
    try {
      await session.open();
      expect(await session.verifyComputer(), isTrue);
      final first = session.displayFrames[ComputerrariaComputer.mono.name];
      await session.refreshComputerDisplays();
      expect(session.displayFrames[ComputerrariaComputer.mono.name], same(first));
      await session.reset();
      expect(session.displayFrames, isEmpty);
      expect(await session.verifyComputer(), isTrue);
      expect(
        session.displayFrames[ComputerrariaComputer.mono.name],
        isNot(same(first)),
      );
    } finally {
      await session.close();
      expect(session.displayFrames, isEmpty);
      session.dispose();
    }
  });
}
