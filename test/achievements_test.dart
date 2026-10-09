import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:terraforge/domain/achievements.dart';

// Synthetic BSON fixtures, deliberately unrelated to any shipped game catalog.
List<int> i32(int value) =>
    (ByteData(4)..setInt32(0, value, Endian.little)).buffer.asUint8List();
List<int> f64(double value) =>
    (ByteData(8)..setFloat64(0, value, Endian.little)).buffer.asUint8List();
List<int> field(int type, String name, List<int> payload) => [
  type,
  ...utf8.encode(name),
  0,
  ...payload,
];
List<int> doc(List<List<int>> fields) {
  final payload = fields.expand((f) => f).toList();
  return [...i32(payload.length + 5), ...payload, 0];
}

List<int> condition(String id, {int? type, List<int>? payload}) => field(
  3,
  id,
  doc([
    field(8, 'Completed', [0]),
    if (type != null) field(type, 'Value', payload!),
  ]),
);
List<int> record(String id, List<List<int>> conditions) =>
    field(3, id, doc([field(3, 'Conditions', doc(conditions))]));
Uint8List crypt(Uint8List bytes, bool encrypt) {
  final key = Uint8List.fromList(ascii.encode('RELOGIC-TERRARIA'));
  final cipher = CBCBlockCipher(AESEngine())
    ..init(encrypt, ParametersWithIV<KeyParameter>(KeyParameter(key), key));
  final result = Uint8List(bytes.length);
  for (var i = 0; i < bytes.length; i += 16) {
    cipher.processBlock(bytes, i, result, i);
  }
  return result;
}

Uint8List encrypt(List<int> bson) {
  final pad = 16 - bson.length % 16;
  return crypt(Uint8List.fromList([...bson, ...List.filled(pad, pad)]), true);
}

List<int> fixture() => doc([
  field(2, 'metadata', [...i32(7), ...utf8.encode('future'), 0]),
  field(5, 'opaque', [...i32(4), 0x80, 23, 42, 99, 0]),
  record('SYNTHETIC', [condition('switch')]),
  record('COUNTER', [condition('count', type: 16, payload: i32(2))]),
  record('FLOAT', [condition('distance', type: 1, payload: f64(0.5))]),
  record('UNKNOWN', [condition('wide', type: 18, payload: List.filled(8, 0))]),
]);
void main() {
  test(
    'untouched input is byte identical and exported buffers are detached',
    () {
      final original = encrypt(fixture());
      final file = AchievementFile.open(original);
      expect(file.records.length, 4);
      expect(file.exportBytes(), original);
      final exported = file.exportBytes();
      exported[0] ^= 255;
      expect(file.exportBytes(), original);
      original[0] ^= 255;
      expect(file.exportBytes(), isNot(original));
      expect(file.dirty, false);
    },
  );
  test('boolean edit preserves every byte except its one payload byte', () {
    final encrypted = encrypt(fixture());
    final before = crypt(encrypted, false);
    final file = AchievementFile.open(encrypted)
      ..setCompleted('SYNTHETIC', true);
    final after = crypt(file.exportBytes(), false);
    expect([
      for (var i = 0; i < before.length; i++)
        if (before[i] != after[i]) i,
    ], hasLength(1));
    expect(
      AchievementFile.open(file.exportBytes()).records.first.completed,
      true,
    );
    file.reset();
    expect(file.dirty, false);
    expect(file.exportBytes(), encrypted);
  });
  test('integer and floating progress round trip with coherent completion', () {
    final file = AchievementFile.open(encrypt(fixture()));
    file.setProgress('COUNTER', 'count', 10, maximum: 10);
    file.setProgress('FLOAT', 'distance', 1.25, maximum: 2.5);
    var parsed = AchievementFile.open(file.exportBytes());
    expect(parsed.records[1].conditions.single.value, 10);
    expect(parsed.records[1].completed, true);
    expect(parsed.records[2].conditions.single.value, 1.25);
    expect(parsed.records[2].completed, false);
    file.setConditionCompleted('FLOAT', 'distance', true, maximum: 2.5);
    file.setConditionCompleted('COUNTER', 'count', false, maximum: 10);
    parsed = AchievementFile.open(file.exportBytes());
    expect(parsed.records[1].conditions.single.value, 0);
    expect(parsed.records[2].conditions.single.value, 2.5);
  });
  test('unsafe counters and unknown encodings never partially mutate', () {
    final file = AchievementFile.open(encrypt(fixture()));
    expect(() => file.setCompleted('COUNTER', true), throwsStateError);
    expect(
      () => file.setConditionCompleted('COUNTER', 'count', true),
      throwsStateError,
    );
    expect(
      () => file.setProgress('UNKNOWN', 'wide', 1, maximum: 2),
      throwsStateError,
    );
    for (final value in [-1, 11, 1.5, double.nan, double.infinity]) {
      expect(
        () => file.setProgress('COUNTER', 'count', value, maximum: 10),
        throwsArgumentError,
      );
    }
    for (final max in [0, -1, 1.5, 2147483648, double.infinity]) {
      expect(
        () => file.setProgress('COUNTER', 'count', 0, maximum: max),
        throwsArgumentError,
      );
    }
    expect(file.dirty, false);
  });
  test('mixed whole-record edit fails atomically', () {
    final file = AchievementFile.open(
      encrypt(
        doc([
          record('MIXED', [
            condition('switch'),
            condition('count', type: 16, payload: i32(0)),
          ]),
        ]),
      ),
    );
    expect(() => file.setCompleted('MIXED', true), throwsStateError);
    expect(file.dirty, false);
  });
  test(
    'size padding truncation duplicates UTF8 and unsupported types rejected',
    () {
      for (final input in [
        Uint8List(0),
        Uint8List(15),
        Uint8List(AchievementFile.maxBytes + 16),
      ]) {
        expect(() => AchievementFile.open(input), throwsFormatException);
      }
      final padded = crypt(encrypt(fixture()), false)..last = 0;
      expect(
        () => AchievementFile.open(crypt(padded, true)),
        throwsFormatException,
      );
      final valid = fixture();
      final badLength = [...valid]..[0] = 1;
      for (final malformed in [
        badLength,
        valid.sublist(0, valid.length - 1),
        [...valid, 0],
        doc([
          record('X', [condition('a'), condition('a')]),
        ]),
        doc([field(0x42, 'unknown', [])]),
        doc([
          [8, 0xff, 0, 0],
        ]),
      ]) {
        expect(
          () => AchievementFile.open(encrypt(malformed)),
          throwsFormatException,
        );
      }
    },
  );
  test('bad condition structure and excessive nesting rejected', () {
    final bad = doc([
      record('X', [
        field(
          3,
          'bad',
          doc([
            field(8, 'Completed', [2]),
          ]),
        ),
      ]),
    ]);
    expect(() => AchievementFile.open(encrypt(bad)), throwsFormatException);
    var nested = doc([]);
    for (var i = 0; i < 34; i++) {
      nested = doc([field(3, 'nested', nested)]);
    }
    expect(() => AchievementFile.open(encrypt(nested)), throwsFormatException);
  });
}
