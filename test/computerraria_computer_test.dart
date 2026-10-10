import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/computerraria/layout.dart';

import 'package:terraforge/engine/world_circuit_backend.dart';

void main() {
  test('physical ROM/RAM banks and mirror boundaries match current layout', () {
    expect(ComputerrariaComputer.romLamp(0, 31), (2853, 1143));
    expect(ComputerrariaComputer.romLamp(4, 0), (2855, 1236));
    expect(ComputerrariaComputer.romLamp(8192 * 4, 31), (2853, 1274));
    expect(ComputerrariaComputer.romLamp(768 * 1024 - 4, 0), (15140, 4249));
    expect(ComputerrariaComputer.ramLamp(0x100000, 31), (2853, 4287));
    expect(ComputerrariaComputer.ramLamp(0x104000, 31, mirror: 1), (
      2854,
      4412,
    ));
    expect(
      () => ComputerrariaComputer.romLamp(768 * 1024, 0),
      throwsRangeError,
    );
    expect(() => ComputerrariaComputer.ramLamp(0x15c000, 0), throwsRangeError);
  });

  test(
    'ROM import accepts bounded raw/hex and rejects ELF and invalid text',
    () {
      expect(
        ComputerrariaComputer.parseProgram(
          'p.bin',
          Uint8List.fromList([1, 2, 3]),
        ),
        [1, 2, 3, 0],
      );
      expect(
        ComputerrariaComputer.parseProgram(
          'p.txt',
          Uint8List.fromList('01 ff\n02\t03'.codeUnits),
        ),
        [1, 255, 2, 3],
      );
      expect(
        () => ComputerrariaComputer.parseProgram(
          'p.bin',
          Uint8List.fromList([127, 69, 76, 70]),
        ),
        throwsFormatException,
      );
      expect(
        () => ComputerrariaComputer.parseProgram(
          'p.txt',
          Uint8List.fromList('0x01'.codeUnits),
        ),
        throwsFormatException,
      );
      expect(
        () => ComputerrariaComputer.parseProgram(
          'p.txt',
          Uint8List.fromList('f 00'.codeUnits),
        ),
        throwsFormatException,
      );
      expect(
        () => ComputerrariaComputer.parseProgram(
          'p.txt',
          Uint8List.fromList('ffff'.codeUnits),
        ),
        throwsFormatException,
      );
      expect(
        ComputerrariaComputer.parseProgram(
          'p.bin',
          Uint8List(768 * 1024),
        ).length,
        768 * 1024,
      );
      expect(
        () => ComputerrariaComputer.parseProgram(
          'p.bin',
          Uint8List(768 * 1024 + 1),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'program deltas preserve little-endian bit order and clear old tail',
    () {
      final before = Uint8List.fromList([1, 0, 0, 128, 1, 0, 0, 0]);
      final after = Uint8List.fromList([2, 0, 0, 0]);
      final batches = ComputerrariaComputer.programWrites(
        before,
        after,
        batchLamps: 2,
      ).toList();
      expect(batches, [
        [2853, 1236, 0, 0, 2853, 1233, 1, 0],
        [2853, 1143, 0, 0, 2855, 1236, 0, 0],
      ]);
      expect(ComputerrariaComputer.programWrites(after, after), isEmpty);
    },
  );

  test(
    'real mono PixelBox frame states decode row-major and reject foreign tiles',
    () {
      const region = ComputerDisplayRegion('test', 20, 30, 2, 2);
      final records = Uint8List(4 * 16), data = ByteData.sublistView(records);
      for (var x = 0; x < 2; x++) {
        for (var y = 0; y < 2; y++) {
          final at = (x * 2 + y) * 16;
          data.setUint32(at, 20 + x, Endian.little);
          data.setUint32(at + 4, 30 + y, Endian.little);
          data.setUint32(at + 8, 445 | (9 << 16), Endian.little);
          data.setInt16(at + 12, y * 18, Endian.little);
        }
      }
      WorldCircuitResult result() =>
          WorldCircuitResult(1, List.filled(24, 0), records, resultKind: 9);
      expect(region.decode(result()), [
        0,
        0,
        0,
        255,
        0,
        0,
        0,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
      ]);
      data.setInt16(12, 17, Endian.little);
      expect(() => region.decode(result()), throwsFormatException);
      data.setInt16(12, 0, Endian.little);
      data.setUint32(8, 65534, Endian.little);
      expect(() => region.decode(result()), throwsFormatException);
    },
  );
}
