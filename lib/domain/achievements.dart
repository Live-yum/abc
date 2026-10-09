import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// An imported condition. IDs come from the file, never a bundled game catalog.
class AchievementCondition {
  const AchievementCondition(this.id, this.completed, this.kind, this.value);
  final String id;
  final bool completed;

  /// boolean, int, float, or unsupported. Unsupported counters are read-only.
  final String kind;
  final num? value;
  bool get editable => kind == 'boolean';
}

class AchievementRecord {
  const AchievementRecord(this.id, this.conditions);
  final String id;
  final List<AchievementCondition> conditions;

  /// Completion of the imported conditions only; missing game conditions cannot
  /// be inferred without an independently supplied catalog.
  bool get completed => conditions.every((c) => c.completed);
  bool get editable => conditions.every((c) => c.editable);
}

/// Lossless achievements.dat editor. Only existing primitive payloads are
/// patched. Document lengths, numeric representations and unknown data survive.
/// AES here implements the game's storage format, not secure user encryption.
class AchievementFile {
  AchievementFile._(
    this._encrypted,
    this._original,
    this._bytes,
    this._records,
  );
  static const maxBytes = 2 * 1024 * 1024;
  final Uint8List _encrypted, _original, _bytes;
  final Map<String, Map<String, _StoredCondition>> _records;

  factory AchievementFile.open(Uint8List input) {
    if (input.isEmpty || input.length > maxBytes || input.length % 16 != 0) {
      throw const FormatException(
        'Invalid achievements file size (maximum 2 MiB).',
      );
    }
    final padded = _crypt(input, false);
    final padding = padded.last;
    if (padding < 1 ||
        padding > 16 ||
        padded.skip(padded.length - padding).any((b) => b != padding)) {
      throw const FormatException('Invalid achievement encryption or padding.');
    }
    final original = Uint8List.fromList(
      padded.sublist(0, padded.length - padding),
    );
    final parser = _BsonReader(original);
    final root = parser.document(original.length, 0);
    if (parser.position != original.length) {
      throw const FormatException('Trailing BSON data.');
    }
    final records = <String, Map<String, _StoredCondition>>{};
    for (final entry in root.entries) {
      final conditions = entry.value.children?['Conditions'];
      if (conditions == null) continue;
      if (entry.value.type != 3 ||
          conditions.type != 3 ||
          conditions.children!.isEmpty) {
        throw const FormatException('Invalid achievement Conditions document.');
      }
      final fields = <String, _StoredCondition>{};
      for (final condition in conditions.children!.entries) {
        final completed = condition.value.children?['Completed'];
        if (condition.value.type != 3 || completed?.type != 8) {
          throw const FormatException(
            'Condition requires a Completed boolean.',
          );
        }
        fields[condition.key] = _StoredCondition(
          completed!.offset,
          condition.value.children!['Value'],
        );
      }
      records[entry.key] = fields;
    }
    if (records.isEmpty) {
      throw const FormatException('No achievement records found.');
    }
    return AchievementFile._(
      Uint8List.fromList(input),
      original,
      Uint8List.fromList(original),
      records,
    );
  }

  /// Build a new, initially locked file from validated external definitions.
  /// No game IDs or counter targets are bundled here.
  factory AchievementFile.blank(Map<String, Map<String, String>> definitions) {
    if (definitions.isEmpty || definitions.length > 1000) {
      throw const FormatException('Achievement catalog is empty or too large.');
    }
    final writer = _BsonWriter();
    final root = writer.document([
      for (final record in definitions.entries)
        writer.element(
          3,
          record.key,
          writer.document([
            writer.element(
              3,
              'Conditions',
              writer.document([
                for (final condition in record.value.entries)
                  writer.element(
                    3,
                    condition.key,
                    writer.document([
                      writer.element(8, 'Completed', Uint8List(1)),
                      if (condition.value == 'int')
                        writer.element(16, 'Value', Uint8List(4)),
                      if (condition.value == 'float')
                        writer.element(1, 'Value', Uint8List(8)),
                    ]),
                  ),
              ]),
            ),
          ]),
        ),
    ]);
    if (definitions.values.any(
      (conditions) =>
          conditions.isEmpty ||
          conditions.length > 1000 ||
          conditions.values.any(
            (kind) => !const ['boolean', 'int', 'float'].contains(kind),
          ),
    )) {
      throw const FormatException('Invalid achievement conditions.');
    }
    final padding = 16 - root.length % 16;
    final padded = Uint8List(root.length + padding)..setAll(0, root);
    padded.fillRange(root.length, padded.length, padding);
    return AchievementFile.open(_crypt(padded, true));
  }

  /// Detached candidate preserving the original reset baseline and all opaque
  /// bytes. Callers publish this only after every mutation and persistence pass.
  AchievementFile clone() => AchievementFile._(
    Uint8List.fromList(_encrypted),
    Uint8List.fromList(_original),
    Uint8List.fromList(_bytes),
    _records,
  );

  List<AchievementRecord> get records => List.unmodifiable(
    _records.entries.map(
      (r) => AchievementRecord(
        r.key,
        List.unmodifiable(
          r.value.entries.map((c) {
            final stored = c.value;
            final value = stored.value;
            final data = ByteData.sublistView(_bytes);
            return AchievementCondition(
              c.key,
              _bytes[stored.completedOffset] == 1,
              stored.kind,
              value?.type == 16
                  ? data.getInt32(value!.offset, Endian.little)
                  : value?.type == 1
                  ? data.getFloat64(value!.offset, Endian.little)
                  : null,
            );
          }),
        ),
      ),
    ),
  );

  bool get dirty {
    for (var i = 0; i < _bytes.length; i++) {
      if (_bytes[i] != _original[i]) return true;
    }
    return false;
  }

  _StoredCondition _condition(String id, String conditionId) {
    final result = _records[id]?[conditionId];
    if (result == null) {
      throw ArgumentError('Unknown achievement or condition.');
    }
    return result;
  }

  /// Whole-record changes are atomic and limited to boolean-only records.
  /// Numeric records need explicit, verified bounds for each counter.
  void setCompleted(String id, bool completed) {
    final record = _records[id];
    if (record == null) throw ArgumentError('Unknown achievement.');
    if (record.values.any((c) => c.kind != 'boolean')) {
      throw StateError('Numeric conditions require a verified maximum.');
    }
    for (final c in record.values) {
      _bytes[c.completedOffset] = completed ? 1 : 0;
    }
  }

  void setConditionCompleted(
    String id,
    String conditionId,
    bool completed, {
    num? maximum,
  }) {
    final c = _condition(id, conditionId);
    if (c.kind == 'boolean') {
      _bytes[c.completedOffset] = completed ? 1 : 0;
    } else {
      if (maximum == null) {
        throw StateError('A verified counter maximum is required.');
      }
      setProgress(id, conditionId, completed ? maximum : 0, maximum: maximum);
    }
  }

  /// Caller must obtain the maximum from a trusted definition or explicit user
  /// input. Never infer a game's target from its current saved counter.
  void setProgress(
    String id,
    String conditionId,
    num value, {
    required num maximum,
  }) {
    final c = _condition(id, conditionId);
    if (c.kind != 'int' && c.kind != 'float') {
      throw StateError('Not an editable counter.');
    }
    final integer = c.kind == 'int';
    if (!maximum.isFinite ||
        maximum <= 0 ||
        !value.isFinite ||
        value < 0 ||
        value > maximum ||
        (integer &&
            (maximum > 2147483647 ||
                maximum != maximum.truncateToDouble() ||
                value != value.truncateToDouble())) ||
        (!integer && maximum > 3.4028234663852886e38)) {
      throw ArgumentError('Counter value or maximum is outside safe bounds.');
    }
    final data = ByteData.sublistView(_bytes);
    if (integer) {
      data.setInt32(c.value!.offset, value.toInt(), Endian.little);
    } else {
      data.setFloat64(c.value!.offset, value.toDouble(), Endian.little);
    }
    _bytes[c.completedOffset] = value >= maximum ? 1 : 0;
  }

  void reset() => _bytes.setAll(0, _original);

  Uint8List exportBytes() {
    if (!dirty) return Uint8List.fromList(_encrypted);
    final padding = 16 - _bytes.length % 16;
    final padded = Uint8List(_bytes.length + padding)..setAll(0, _bytes);
    padded.fillRange(_bytes.length, padded.length, padding);
    return _crypt(padded, true);
  }
}

Uint8List _crypt(Uint8List input, bool encrypt) {
  final key = Uint8List.fromList(ascii.encode('RELOGIC-TERRARIA'));
  final cipher = CBCBlockCipher(AESEngine())
    ..init(encrypt, ParametersWithIV<KeyParameter>(KeyParameter(key), key));
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += 16) {
    cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

class _StoredCondition {
  const _StoredCondition(this.completedOffset, this.value);
  final int completedOffset;
  final _Field? value;
  String get kind => value == null
      ? 'boolean'
      : switch (value!.type) {
          16 => 'int',
          1 => 'float',
          _ => 'unsupported',
        };
}

class _Field {
  _Field(this.type, this.offset, [this.children]);
  final int type, offset;
  final Map<String, _Field>? children;
}

/// Strict BSON 1.1 scanner. Opaque values remain in the original byte buffer.
class _BsonReader {
  _BsonReader(this.bytes) : data = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData data;
  int position = 0, documents = 0, fields = 0;
  Never fail() => throw const FormatException('Malformed or unsupported BSON.');
  void need(int count, int limit) {
    if (count < 0 || position > limit - count) fail();
  }

  void skip(int count, int limit) {
    need(count, limit);
    position += count;
  }

  int int32(int limit) {
    need(4, limit);
    final n = data.getInt32(position, Endian.little);
    position += 4;
    return n;
  }

  String cstring(int limit) {
    final start = position;
    while (position < limit && bytes[position] != 0) {
      position++;
    }
    if (position == limit || position - start > 4096) fail();
    final result = utf8.decode(bytes.sublist(start, position));
    position++;
    return result;
  }

  void string(int limit) {
    final length = int32(limit);
    if (length < 1) fail();
    need(length, limit);
    if (bytes[position + length - 1] != 0) fail();
    utf8.decode(bytes.sublist(position, position + length - 1));
    position += length;
  }

  Map<String, _Field> document(int limit, int depth) {
    if (depth > 32 || ++documents > 10000) fail();
    final start = position;
    final length = int32(limit);
    if (length < 5 || length > limit - start) fail();
    final end = start + length - 1;
    if (bytes[end] != 0) fail();
    final result = <String, _Field>{};
    while (position < end) {
      if (++fields > 100000) fail();
      final type = bytes[position++];
      final name = cstring(end);
      if (result.containsKey(name)) fail();
      final offset = position;
      Map<String, _Field>? children;
      switch (type) {
        case 1:
          need(8, end);
          if (!data.getFloat64(position, Endian.little).isFinite) fail();
          skip(8, end);
        case 2 || 13 || 14:
          string(end);
        case 3 || 4:
          children = document(end, depth + 1);
          if (type == 4) {
            var index = 0;
            for (final key in children.keys) {
              if (key != '${index++}') fail();
            }
          }
        case 5:
          final length = int32(end);
          need(1, end);
          final subtype = bytes[position++];
          need(length, end);
          if (subtype == 2 &&
              (length < 4 ||
                  data.getInt32(position, Endian.little) != length - 4)) {
            fail();
          }
          skip(length, end);
        case 6 || 10 || 127 || 255:
          break;
        case 7:
          skip(12, end);
        case 8:
          need(1, end);
          if (bytes[position++] > 1) fail();
        case 9 || 17 || 18:
          skip(8, end);
        case 11:
          cstring(end);
          cstring(end);
        case 12:
          string(end);
          skip(12, end);
        case 15:
          final start = position;
          final size = int32(end);
          if (size < 14 || size > end - start) fail();
          final scopeEnd = start + size;
          string(scopeEnd);
          document(scopeEnd, depth + 1);
          if (position != scopeEnd) fail();
        case 16:
          skip(4, end);
        case 19:
          skip(16, end);
        default:
          fail();
      }
      result[name] = _Field(type, offset, children);
    }
    if (position != end) fail();
    position++;
    return result;
  }
}

/// Narrow writer: only the BSON primitives required for a new achievement file.
class _BsonWriter {
  int bytes = 0, fields = 0, documents = 0;
  void reserve(int amount) {
    bytes += amount;
    if (bytes > AchievementFile.maxBytes - 16) {
      throw const FormatException('Achievement catalog exceeds 2 MiB.');
    }
  }

  Uint8List element(int type, String name, Uint8List value) {
    final encoded = utf8.encode(name);
    if (name.isEmpty ||
        name.contains('\u0000') ||
        encoded.length > 4096 ||
        utf8.decode(encoded) != name ||
        ++fields > 100000) {
      throw const FormatException('Invalid or oversized achievement ID.');
    }
    reserve(encoded.length + 2 + (type == 3 ? 0 : value.length));
    return Uint8List.fromList([type, ...encoded, 0, ...value]);
  }

  Uint8List document(List<Uint8List> fields) {
    if (++documents > 10000) {
      throw const FormatException('Too many achievement documents.');
    }
    reserve(5);
    final length = fields.fold<int>(5, (sum, field) => sum + field.length);
    final result = Uint8List(length);
    ByteData.sublistView(result).setInt32(0, length, Endian.little);
    var offset = 4;
    for (final field in fields) {
      result.setAll(offset, field);
      offset += field.length;
    }
    return result;
  }
}
