import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Real Terraria MAP data. Protocol sources and limits: docs/MAP_FORMAT.md.
/// Chunked MAP values are palette-index/light/extra bytes. Legacy MAP values
/// retain their category separately; they are not WLD tile IDs.
class TerrariaMapCell {
  final int option, light, color;
  final int? legacyKind;
  const TerrariaMapCell(this.option, this.light, this.color, this.legacyKind);
}

class TerrariaMapRaster {
  final int width, height;
  final Uint8List rgba;
  const TerrariaMapRaster(this.width, this.height, this.rgba);
}

class TerrariaMapSession {
  static const maxInputBytes = 128 * 1024 * 1024;
  static const maxCells = 20160000;
  static const maxEditCells = 262144;
  static const maxHistoryBytes = 8 * 1024 * 1024;
  final int version, width, height, worldId;
  final String worldName;
  final bool chunked;
  Uint8List _source;
  Uint32List _cells;
  Uint8List _kinds;
  final int _headerLength;
  final List<(int, int)> _chunks;
  final Map<int, int> _originalEdits = {};
  final List<_MapEdit> _undo = [], _redo = [];
  bool _closed = false;
  int _historyBytes = 0;
  int revision = 0;

  TerrariaMapSession._(
    this.version,
    this.width,
    this.height,
    this.worldId,
    this.worldName,
    this.chunked,
    this._source,
    this._cells,
    this._kinds,
    this._headerLength,
    this._chunks,
  );

  /// Decodes every tile, validates all chunk checksums and RLE boundaries, and
  /// takes a private copy of the input. No caller-owned bytes are modified.
  static TerrariaMapSession decode(Uint8List input) {
    if (input.length > maxInputBytes) {
      throw const FormatException('MAP exceeds the 128 MiB input limit');
    }
    final source = Uint8List.fromList(input), r = _MapReader(input);
    final rawVersion = r.u32(), version = rawVersion & ~0x8000;
    final chunked = rawVersion & 0x8000 != 0;
    if ((chunked && version != 315) ||
        (!chunked && (version < 135 || version > 319))) {
      throw FormatException('Unsupported MAP version $rawVersion');
    }
    if (utf8.decode(r.take(7), allowMalformed: true) != 'relogic' ||
        r.u8() != 1) {
      throw const FormatException('Invalid Terraria MAP signature');
    }
    r.take(12); // Preserve revision and favorite bytes verbatim.
    final worldName = r.string(), worldId = r.i32();
    final height = r.i32(), width = r.i32();
    if (width <= 0 ||
        height <= 0 ||
        width * height > maxCells ||
        width > 32768 ||
        height > 32768) {
      throw const FormatException('MAP dimensions exceed supported bounds');
    }
    final counts = List.generate(6, (_) => r.u16());
    if (counts.any((v) => v > 32767)) {
      throw const FormatException('Invalid MAP option count');
    }
    final tileBits = r.take((counts[0] + 7) ~/ 8);
    final wallBits = r.take((counts[1] + 7) ~/ 8);
    var paletteSize = 1 + counts.skip(2).fold<int>(0, (a, b) => a + b);
    for (var layer = 0; layer < 2; layer++) {
      final bits = layer == 0 ? tileBits : wallBits;
      for (var i = 0; i < counts[layer]; i++) {
        paletteSize += bits[i >> 3] & (1 << (i & 7)) != 0 ? r.u8() : 1;
      }
    }
    if (paletteSize > 65535) {
      throw const FormatException('MAP palette overflows uint16');
    }
    final headerLength = r.offset;
    final cells = Uint32List(width * height);
    final kinds = chunked ? Uint8List(0) : Uint8List(cells.length);
    final chunks = <(int, int)>[];
    if (chunked) {
      for (var cy = 0; cy < height; cy += 64) {
        for (var cx = 0; cx < width; cx += 64) {
          final size = r.u32(), offset = r.offset;
          if (size == 0 || size > 1024 * 1024) {
            throw const FormatException('Invalid MAP chunk length');
          }
          final data = _inflateBounded(r.take(size), 16384, zlib: true);
          if (data.length != 16384) {
            throw const FormatException('MAP chunk must contain 4096 cells');
          }
          final view = ByteData.sublistView(data);
          for (var y = 0; y < 64 && cy + y < height; y++) {
            for (var x = 0; x < 64 && cx + x < width; x++) {
              cells[(cy + y) * width + cx + x] = view.getUint32(
                (y * 64 + x) * 4,
                Endian.little,
              );
            }
          }
          chunks.add((offset, size));
        }
      }
      if (r.remaining != 0) {
        throw const FormatException('Unexpected trailing MAP chunks');
      }
    } else {
      final payload = _inflateBounded(
        r.take(r.remaining),
        cells.length * 8,
        zlib: false,
      );
      final p = _MapReader(payload);
      for (var y = 0; y < height; y++) {
        var x = 0;
        while (x < width) {
          final flags = p.u8(), extra = flags & 1 == 0 ? 0 : p.u8();
          if (extra & 0x81 != 0 || flags >> 6 == 3) {
            throw const FormatException('Unsupported MAP record extension');
          }
          var kind = (flags >> 1) & 7;
          if (kind == 3 && extra & 0x40 != 0) kind = 8;
          final hasOption = kind == 1 || kind == 2 || kind == 7;
          final option = !hasOption
              ? 0
              : flags & 16 != 0
              ? p.u16()
              : p.u8();
          final lightPresent = flags & 32 != 0;
          final light = lightPresent ? p.u8() : 255;
          final run = switch (flags >> 6) {
            1 => p.u8(),
            2 => p.u16(),
            _ => 0,
          };
          if (run > 32767 || x + run >= width) {
            throw const FormatException('MAP RLE crosses a row boundary');
          }
          final base = option | (((extra >> 1) & 31) << 24);
          for (var n = 0; n <= run; n++) {
            final index = y * width + x + n;
            kinds[index] = kind;
            cells[index] =
                base | ((n == 0 || !lightPresent ? light : p.u8()) << 16);
          }
          x += run + 1;
        }
      }
      if (p.remaining != 0) {
        throw const FormatException('Unexpected trailing MAP tile records');
      }
    }
    return TerrariaMapSession._(
      version,
      width,
      height,
      worldId,
      worldName,
      chunked,
      source,
      cells,
      kinds,
      headerLength,
      chunks,
    );
  }

  bool get isClosed => _closed;
  bool get isModified => _originalEdits.isNotEmpty;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Owned binary buffers plus typed undo records. Dart object/allocator
  /// overhead is deliberately excluded; this is not process RSS.
  int get ownedBytes =>
      _source.length + _cells.lengthInBytes + _kinds.length + _historyBytes;
  Map<String, Object> get metadata => {
    'version': version,
    'chunked': chunked,
    'width': width,
    'height': height,
    'worldId': worldId,
    'worldName': worldName,
    'cellCount': width * height,
    'modified': isModified,
  };

  void _check() {
    if (_closed) throw StateError('MAP session is closed');
  }

  int _index(int x, int y) {
    _check();
    if (x < 0 || y < 0 || x >= width || y >= height) {
      throw RangeError('MAP coordinate is outside the world');
    }
    return y * width + x;
  }

  TerrariaMapCell cellAt(int x, int y) {
    final i = _index(x, y), v = _cells[i];
    return TerrariaMapCell(
      v & 65535,
      (v >> 16) & 255,
      (v >> 24) & 31,
      chunked ? null : _kinds[i],
    );
  }

  /// Returns independent packed values; callers cannot mutate the document.
  Uint32List readRegion(int x, int y, int regionWidth, int regionHeight) {
    _rectangle(x, y, regionWidth, regionHeight);
    final result = Uint32List(regionWidth * regionHeight);
    for (var row = 0; row < regionHeight; row++) {
      final source = (y + row) * width + x;
      result.setRange(
        row * regionWidth,
        (row + 1) * regionWidth,
        _cells,
        source,
      );
    }
    return result;
  }

  void _rectangle(int x, int y, int w, int h) {
    _check();
    if (w <= 0 ||
        h <= 0 ||
        w * h > maxEditCells ||
        x < 0 ||
        y < 0 ||
        x + w > width ||
        y + h > height) {
      throw RangeError('MAP rectangle exceeds world or 262144-cell limit');
    }
  }

  /// Changes exploration light (0–255) and/or paint (0–31), preserving palette
  /// indices, categories, extra bits, metadata, and out-of-selection cells.
  int editRect(
    int x,
    int y,
    int regionWidth,
    int regionHeight, {
    int? light,
    int? color,
  }) {
    _rectangle(x, y, regionWidth, regionHeight);
    if (light == null && color == null ||
        light != null && (light < 0 || light > 255) ||
        color != null && (color < 0 || color > 31)) {
      throw ArgumentError('Provide valid MAP light and/or paint');
    }
    final indices = <int>[], before = <int>[], after = <int>[];
    for (var row = y; row < y + regionHeight; row++) {
      for (var column = x; column < x + regionWidth; column++) {
        final i = row * width + column, old = _cells[i];
        var next = old;
        if (light != null) next = (next & 0xff00ffff) | (light << 16);
        if (color != null) next = (next & 0xe0ffffff) | (color << 24);
        if (next != old) {
          indices.add(i);
          before.add(old);
          after.add(next);
        }
      }
    }
    if (indices.isEmpty) return 0;
    if (_originalEdits.length +
            indices.where((i) => !_originalEdits.containsKey(i)).length >
        1048576) {
      throw StateError('MAP edit state exceeds the 1048576-cell budget');
    }
    for (final edit in _redo) {
      _historyBytes -= edit.bytes;
    }
    _redo.clear();
    final edit = _MapEdit(indices, before, after);
    _apply(edit.indices, edit.after);
    _undo.add(edit);
    revision++;
    _historyBytes += edit.bytes;
    while (_undo.length > 32 || _historyBytes > maxHistoryBytes) {
      _historyBytes -= _undo.removeAt(0).bytes;
    }
    return indices.length;
  }

  void _apply(Uint32List indices, Uint32List values) {
    for (var n = 0; n < indices.length; n++) {
      final i = indices[n], original = _originalEdits[i] ?? _cells[i];
      if (values[n] == original) {
        _originalEdits.remove(i);
      } else {
        _originalEdits[i] = original;
      }
      _cells[i] = values[n];
    }
  }

  void undo() {
    _check();
    if (_undo.isEmpty) return;
    final edit = _undo.removeLast();
    _apply(edit.indices, edit.before);
    _redo.add(edit);
    revision++;
  }

  void redo() {
    _check();
    if (_redo.isEmpty) return;
    final edit = _redo.removeLast();
    _apply(edit.indices, edit.after);
    _undo.add(edit);
    revision++;
  }

  /// A real MAP exploration/visibility raster, intentionally grayscale.
  /// This does not imply WLD terrain, wire, chest or game-palette rendering.
  TerrariaMapRaster renderExplorationRgba({int maxWidth = 1024}) {
    _check();
    if (maxWidth <= 0 || maxWidth > 2048) {
      throw RangeError.range(maxWidth, 1, 2048);
    }
    final scale = math.max(1.0, math.max(width / maxWidth, height / 2048));
    final w = (width / scale).ceil(), h = (height / scale).ceil();
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final sy = math.min(height - 1, (y * scale).floor());
      for (var x = 0; x < w; x++) {
        final sx = math.min(width - 1, (x * scale).floor()),
            i = sy * width + sx;
        final value = _cells[i];
        final empty = chunked ? value & 65535 == 0 : _kinds[i] == 0;
        final light = empty ? 0 : (value >> 16) & 255, out = (y * w + x) * 4;
        rgba[out] = light;
        rgba[out + 1] = light;
        rgba[out + 2] = light;
        rgba[out + 3] = 255;
      }
    }
    return TerrariaMapRaster(w, h, rgba);
  }

  Uint8List exportBytes() {
    _check();
    if (!isModified) return Uint8List.fromList(_source);
    final out = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(_source, 0, _headerLength));
    if (chunked) {
      final across = (width + 63) ~/ 64;
      final dirtyChunks = <int>{
        for (final i in _originalEdits.keys)
          ((i ~/ width) ~/ 64) * across + ((i % width) ~/ 64),
      };
      for (var index = 0; index < _chunks.length; index++) {
        final (offset, size) = _chunks[index];
        if (!dirtyChunks.contains(index)) {
          out.add(Uint8List.sublistView(_source, offset - 4, offset + size));
          continue;
        }
        final raw = _inflateBounded(
          Uint8List.sublistView(_source, offset, offset + size),
          16384,
          zlib: true,
        );
        final view = ByteData.sublistView(raw);
        final cx = (index % across) * 64, cy = (index ~/ across) * 64;
        for (var y = 0; y < 64 && cy + y < height; y++) {
          for (var x = 0; x < 64 && cx + x < width; x++) {
            view.setUint32(
              (y * 64 + x) * 4,
              _cells[(cy + y) * width + cx + x],
              Endian.little,
            );
          }
        }
        final compressed = const ZLibEncoder().encodeBytes(raw);
        final sizeBytes = ByteData(4)
          ..setUint32(0, compressed.length, Endian.little);
        out.add(sizeBytes.buffer.asUint8List());
        out.add(compressed);
      }
    } else {
      final raw = OutputMemoryStream(size: 65536);
      for (var y = 0; y < height; y++) {
        var x = 0;
        while (x < width) {
          final index = y * width + x,
              value = _cells[index],
              kind = _kinds[index];
          final option = value & 65535,
              light = (value >> 16) & 255,
              color = (value >> 24) & 31;
          var run = 0;
          while (x + run + 1 < width && run < 32767) {
            final next = index + run + 1;
            if (_kinds[next] != kind ||
                (light == 255
                    ? _cells[next] != value
                    : (_cells[next] & 0xff00ffff) != (value & 0xff00ffff))) {
              break;
            }
            run++;
          }
          final hasOption = kind == 1 || kind == 2 || kind == 7;
          final extra = (color << 1) | (kind == 8 ? 0x40 : 0);
          final flags =
              ((kind == 8 ? 3 : kind) << 1) |
              (extra != 0 ? 1 : 0) |
              (hasOption && option > 255 ? 16 : 0) |
              (light != 255 ? 32 : 0) |
              (run == 0
                  ? 0
                  : run <= 255
                  ? 64
                  : 128);
          raw.writeByte(flags);
          if (extra != 0) raw.writeByte(extra);
          if (hasOption) {
            raw.writeByte(option & 255);
            if (option > 255) raw.writeByte(option >> 8);
          }
          if (light != 255) raw.writeByte(light);
          if (run != 0) {
            raw.writeByte(run & 255);
            if (run > 255) raw.writeByte(run >> 8);
          }
          if (light != 255) {
            for (var n = 1; n <= run; n++) {
              raw.writeByte((_cells[index + n] >> 16) & 255);
            }
          }
          x += run + 1;
        }
      }
      final zlib = const ZLibEncoder().encodeBytes(raw.getBytes());
      out.add(Uint8List.sublistView(zlib, 2, zlib.length - 4));
    }
    return out.takeBytes();
  }

  void close() {
    if (_closed) return;
    _source = Uint8List(0);
    _cells = Uint32List(0);
    _kinds = Uint8List(0);
    _chunks.clear();
    _originalEdits.clear();
    _undo.clear();
    _redo.clear();
    _historyBytes = 0;
    _closed = true;
  }

  /// Full semantic and header equivalence for isolated export verification.
  bool contentEquals(TerrariaMapSession other) {
    _check();
    other._check();
    if (version != other.version ||
        chunked != other.chunked ||
        width != other.width ||
        height != other.height ||
        _headerLength != other._headerLength ||
        _kinds.length != other._kinds.length) {
      return false;
    }
    for (var i = 0; i < _headerLength; i++) {
      if (_source[i] != other._source[i]) return false;
    }
    for (var i = 0; i < _cells.length; i++) {
      if (_cells[i] != other._cells[i]) return false;
    }
    for (var i = 0; i < _kinds.length; i++) {
      if (_kinds[i] != other._kinds[i]) return false;
    }
    return true;
  }
}

class _MapEdit {
  final Uint32List indices, before, after;
  _MapEdit(List<int> i, List<int> b, List<int> a)
    : indices = Uint32List.fromList(i),
      before = Uint32List.fromList(b),
      after = Uint32List.fromList(a);
  int get bytes => indices.lengthInBytes * 3;
}

class _MapReader {
  final Uint8List bytes;
  final ByteData view;
  int offset = 0;
  _MapReader(this.bytes) : view = ByteData.sublistView(bytes);
  int get remaining => bytes.length - offset;
  Uint8List take(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('Truncated MAP');
    }
    final result = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return result;
  }

  int u8() {
    if (remaining < 1) throw const FormatException('Truncated MAP');
    return bytes[offset++];
  }

  int u16() {
    final start = offset;
    take(2);
    return view.getUint16(start, Endian.little);
  }

  int u32() {
    final start = offset;
    take(4);
    return view.getUint32(start, Endian.little);
  }

  int i32() {
    final start = offset;
    take(4);
    return view.getInt32(start, Endian.little);
  }

  String string() {
    var count = 0, shift = 0;
    while (true) {
      final b = u8();
      count |= (b & 127) << shift;
      if (b < 128) break;
      shift += 7;
      if (shift > 28) throw const FormatException('Invalid MAP string length');
    }
    if (count > 65536) {
      throw const FormatException('MAP world name is too long');
    }
    return utf8.decode(take(count));
  }
}

Uint8List _inflateBounded(Uint8List bytes, int limit, {required bool zlib}) {
  var start = 0, end = bytes.length;
  if (zlib) {
    if (bytes.length < 6 ||
        bytes[0] & 15 != 8 ||
        bytes[0] >> 4 > 7 ||
        ((bytes[0] << 8) | bytes[1]) % 31 != 0 ||
        bytes[1] & 32 != 0) {
      throw const FormatException('Invalid MAP zlib header');
    }
    start = 2;
    end -= 4;
  }
  final output = _BoundedMapOutput(limit);
  final compressed = InputMemoryStream(
    Uint8List.sublistView(bytes, start, end),
  );
  Inflate.stream(compressed, output: output);
  if (!compressed.isEOS) {
    throw const FormatException('Unexpected trailing MAP compressed data');
  }
  final decoded = output.getBytes();
  if (zlib &&
      getAdler32(decoded) != ByteData.sublistView(bytes).getUint32(end)) {
    throw const FormatException('MAP chunk checksum mismatch');
  }
  return decoded;
}

class _BoundedMapOutput extends OutputMemoryStream {
  final int limit;
  _BoundedMapOutput(this.limit) : super(size: math.min(limit, 32768));
  void _bound(int n) {
    if (n < 0 || length + n > limit) {
      throw const FormatException('MAP decompression exceeds bounds');
    }
  }

  @override
  void writeByte(int value) {
    _bound(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _bound(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _bound(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _bound(count);
    if (distance <= 0 || distance > length) {
      throw const FormatException('Invalid MAP deflate reference');
    }
    super.writeBackReference(distance, count);
  }
}
