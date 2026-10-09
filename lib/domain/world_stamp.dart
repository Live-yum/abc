import 'dart:typed_data';

/// A sparse layer edit. Null preserves a layer; block -1 or wall 0 clears it.
/// Deliberately excludes furniture, liquids, wiring, slopes and entity payloads.
class StampCell {
  final int? block, wall;
  final int blockPaint, wallPaint;
  const StampCell({
    this.block,
    this.wall,
    this.blockPaint = 0,
    this.wallPaint = 0,
  });
}

/// Original conservative WLD byte-stream editor. No engine pointers or tables.
/// Only releases 139 and 326 are supported. All non-tile sections remain exact.
class WorldStamp {
  static const maxCells = 1048576;
  static Uint8List apply(
    Uint8List source, {
    required int x,
    required int y,
    required int width,
    required int height,
    required List<StampCell?> cells,
    bool overwrite = false,
  }) {
    final world = _World(source);
    world.bounds(x, y, width, height);
    if (cells.length != width * height) _bad('Stamp cell count mismatch');
    world.guardObjects(x, y, width, height);
    for (final cell in cells) {
      if (cell != null) world.validate(cell);
    }
    final output = BytesBuilder(copy: false);
    world.scan((column, row, tile) {
      final inside = column >= x && column < x + width;
      final last = row + tile.count;
      if (column >= x - 8 &&
          column < x + width + 8 &&
          row < y + height + 8 &&
          last > y - 8 &&
          tile.framed) {
        _bad(
          'Furniture at or next to destination requires an object-aware writer',
        );
      }
      if (!inside || last <= y || row >= y + height) {
        output.add(source.sublist(tile.start, tile.end));
        return;
      }
      var preserved = 0;
      void flush() {
        if (preserved != 0) {
          output.add(tile.record(source, preserved));
          preserved = 0;
        }
      }

      for (var yy = row; yy < last; yy++) {
        final edit = yy >= y && yy < y + height
            ? cells[(yy - y) * width + column - x]
            : null;
        if (edit == null || (edit.block == null && edit.wall == null)) {
          preserved++;
          continue;
        }
        if (tile.protected) {
          _bad('Destination contains wiring, liquid, shape or special flags');
        }
        if (!overwrite &&
            ((edit.block != null && tile.block >= 0) ||
                (edit.wall != null && tile.wall != 0))) {
          _bad('Destination layer is occupied; explicit overwrite is required');
        }
        flush();
        output.add(
          _encode(
            edit.block ?? tile.block,
            edit.wall ?? tile.wall,
            edit.block == null ? tile.blockPaint : edit.blockPaint,
            edit.wall == null ? tile.wallPaint : edit.wallPaint,
          ),
        );
      }
      flush();
    });
    final tiles = output.takeBytes();
    final delta = tiles.length - (world.positions[2] - world.positions[1]);
    if (source.length + delta > 64 * 1024 * 1024) {
      _bad('Candidate exceeds 64 MiB budget');
    }
    final result = Uint8List(source.length + delta);
    result.setRange(0, world.positions[1], source);
    result.setRange(
      world.positions[1],
      world.positions[1] + tiles.length,
      tiles,
    );
    result.setRange(
      world.positions[2] + delta,
      result.length,
      source,
      world.positions[2],
    );
    final bytes = ByteData.sublistView(result);
    for (var i = 2; i < world.positions.length; i++) {
      bytes.setInt32(
        world.pointerOffset + i * 4,
        world.positions[i] + delta,
        Endian.little,
      );
    }
    // Verify our emitted stream, plus every requested cell and untouched section.
    final readback = extract(result, x: x, y: y, width: width, height: height);
    for (var i = 0; i < cells.length; i++) {
      final expected = cells[i], actual = readback[i];
      if (expected == null) continue;
      if ((expected.block != null &&
              (actual?.block != expected.block ||
                  actual?.blockPaint != expected.blockPaint)) ||
          (expected.wall != null &&
              (actual?.wall != expected.wall ||
                  actual?.wallPaint != expected.wallPaint))) {
        _bad('Stamp read-back mismatch');
      }
    }
    return result;
  }

  /// Row-major ordinary cells suitable for a conservative fusion stamp.
  static List<StampCell?> extract(
    Uint8List source, {
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    final world = _World(source);
    world.bounds(x, y, width, height);
    world.guardObjects(x, y, width, height);
    final result = List<StampCell?>.filled(width * height, null);
    world.scan((column, row, tile) {
      if (column < x ||
          column >= x + width ||
          row >= y + height ||
          row + tile.count <= y) {
        return;
      }
      if (tile.framed || tile.protected) {
        _bad(
          'Source region contains unsupported furniture or special tile state',
        );
      }
      final cell = StampCell(
        block: tile.block,
        wall: tile.wall,
        blockPaint: tile.blockPaint,
        wallPaint: tile.wallPaint,
      );
      world.validate(cell);
      for (
        var yy = row < y ? y : row;
        yy < row + tile.count && yy < y + height;
        yy++
      ) {
        result[(yy - y) * width + column - x] = cell;
      }
    });
    return result;
  }
}

Never _bad(String message) => throw FormatException(message);

class _Reader {
  final Uint8List bytes;
  int offset;
  final int end;
  _Reader(this.bytes, this.offset, this.end);
  int byte() {
    if (offset >= end) _bad('Truncated WLD');
    return bytes[offset++];
  }

  int u16() => byte() | (byte() << 8);
  int i32() {
    final n = byte() | (byte() << 8) | (byte() << 16) | (byte() << 24);
    return n.toSigned(32);
  }

  void skip(int n) {
    if (n < 0 || n > end - offset) _bad('Truncated WLD');
    offset += n;
  }

  void string() {
    var n = 0;
    for (var i = 0; i < 5; i++) {
      final b = byte();
      n |= (b & 127) << (7 * i);
      if (b < 128) {
        skip(n);
        return;
      }
    }
    _bad('Malformed WLD string');
  }
}

class _World {
  final Uint8List source;
  late final int version, pointerOffset, width, height, typeCount;
  late final List<int> positions;
  late final Uint8List important;
  _World(this.source) {
    if (source.length > 64 * 1024 * 1024) _bad('WLD exceeds 64 MiB budget');
    final r = _Reader(source, 0, source.length);
    version = r.i32();
    if (version != 139 && version != 326) {
      _bad('Safe stamping currently supports WLD releases 139 and 326 only');
    }
    for (final b in [114, 101, 108, 111, 103, 105, 99, 2]) {
      if (r.byte() != b) _bad('Invalid WLD signature');
    }
    r.skip(12);
    final count = r.u16();
    if (count != (version == 139 ? 7 : 11)) {
      _bad('Unsupported WLD section layout');
    }
    pointerOffset = r.offset;
    positions = List.generate(count, (_) => r.i32());
    typeCount = r.u16();
    if (typeCount == 0 || typeCount > 4096) _bad('Invalid tile type table');
    final tableStart = r.offset;
    r.skip((typeCount + 7) ~/ 8);
    important = Uint8List.sublistView(source, tableStart, r.offset);
    var previous = r.offset;
    for (final position in positions) {
      if (position < previous || position > source.length) {
        _bad('Invalid WLD section offsets');
      }
      previous = position;
    }
    final header = _Reader(source, positions[0], positions[1]);
    header.string();
    if (version == 326) {
      header.string();
      header.skip(24);
    }
    header.skip(20);
    height = header.i32();
    width = header.i32();
    if (width < 1 || height < 1 || width * height > 200000000) {
      _bad('Invalid WLD dimensions');
    }
  }
  bool framed(int type) => (important[type ~/ 8] & (1 << (type % 8))) != 0;
  void bounds(int x, int y, int w, int h) {
    if (x < 0 ||
        y < 0 ||
        w < 1 ||
        h < 1 ||
        w * h > WorldStamp.maxCells ||
        x + w > width ||
        y + h > height) {
      _bad('Stamp rectangle is outside the world or exceeds the cell budget');
    }
  }

  void guardObjects(int x, int y, int w, int h) {
    bool near(int xx, int yy) =>
        xx >= x - 8 && xx < x + w + 8 && yy >= y - 8 && yy < y + h + 8;
    final chests = _Reader(source, positions[2], positions[3]);
    final chestCount = chests.u16();
    final fixedSlots = version == 139 ? chests.u16() : 0;
    if (chestCount > 8000 || fixedSlots > 504) _bad('Invalid chest section');
    for (var i = 0; i < chestCount; i++) {
      final xx = chests.i32(), yy = chests.i32();
      chests.string();
      final slots = version == 326 ? chests.i32() : fixedSlots;
      if (slots < 0 ||
          slots > 504 ||
          xx < 0 ||
          yy < 0 ||
          xx >= width ||
          yy >= height) {
        _bad('Invalid chest record');
      }
      if (near(xx, yy)) {
        _bad(
          'Chest within eight tiles of the region requires object-aware fusion',
        );
      }
      for (var j = 0; j < slots; j++) {
        final stack = chests.u16();
        if (stack > 32767) _bad('Invalid item stack');
        if (stack > 0) chests.skip(5);
      }
    }
    if (chests.offset != chests.end) _bad('Unexpected chest section bytes');
    final signs = _Reader(source, positions[3], positions[4]);
    final signCount = signs.u16();
    if (signCount > 32000) _bad('Invalid sign count');
    for (var i = 0; i < signCount; i++) {
      signs.string();
      final xx = signs.i32(), yy = signs.i32();
      if (xx < 0 || yy < 0 || xx >= width || yy >= height) {
        _bad('Invalid sign coordinates');
      }
      if (near(xx, yy)) {
        _bad(
          'Sign within eight tiles of the region requires object-aware fusion',
        );
      }
    }
    if (signs.offset != signs.end) _bad('Unexpected sign section bytes');
    final entities = _Reader(source, positions[5], positions[6]);
    if (entities.i32() != 0 || entities.offset != entities.end) {
      _bad('Tile entity worlds require an object-aware writer');
    }
  }

  void validate(StampCell cell) {
    if (cell.blockPaint < 0 ||
        cell.blockPaint > 30 ||
        cell.wallPaint < 0 ||
        cell.wallPaint > 30) {
      _bad('Paint must be 0–30');
    }
    final block = cell.block, wall = cell.wall;
    // Intentionally tiny, original material allowlist: dirt, stone, grass, wood.
    if (block != null &&
        (block != -1 &&
            block != 0 &&
            block != 1 &&
            block != 2 &&
            block != 30)) {
      _bad('Only dirt, stone, grass and wood blocks are supported');
    }
    if (block != null && block >= 0 && (block >= typeCount || framed(block))) {
      _bad('Block is unavailable or frame-important in this world');
    }
    if (wall != null && (wall < 0 || wall > 4)) {
      _bad('Only basic wall IDs 0–4 are supported');
    }
    if (block == -1 && cell.blockPaint != 0 ||
        wall == 0 && cell.wallPaint != 0) {
      _bad('An empty layer cannot carry paint');
    }
  }

  void scan(void Function(int, int, _Tile) visit) {
    final r = _Reader(source, positions[1], positions[2]);
    for (var x = 0; x < width; x++) {
      var y = 0;
      while (y < height) {
        final start = r.offset, a = r.byte();
        final b = (a & 1) != 0 ? r.byte() : 0;
        final c = (b & 1) != 0 ? r.byte() : 0;
        final d = (c & 1) != 0 ? r.byte() : 0;
        if ((b & 128) != 0 ||
            (d & 225) != 0 ||
            (version == 139 && (d != 0 || (c & 225) != 0))) {
          _bad('Unknown tile header flags');
        }
        var block = -1, wall = 0, blockPaint = 0, wallPaint = 0;
        var isFramed = false;
        if ((a & 2) != 0) {
          block = (a & 32) != 0 ? r.u16() : r.byte();
          if (block >= typeCount) _bad('Tile ID exceeds frame table');
          isFramed = framed(block);
          if (isFramed) r.skip(4);
          if ((c & 8) != 0) blockPaint = r.byte();
        } else if ((a & 32) != 0 || (c & 8) != 0) {
          _bad('Invalid inactive tile flags');
        }
        if ((a & 4) != 0) {
          wall = r.byte();
          if ((c & 16) != 0) wallPaint = r.byte();
        } else if ((c & 80) != 0) {
          _bad('Invalid absent wall flags');
        }
        if ((a & 24) != 0) r.skip(1);
        if ((c & 64) != 0) wall |= r.byte() << 8;
        final payloadEnd = r.offset;
        final mode = a >> 6;
        if (mode == 3) _bad('Unsupported RLE mode');
        final repeat = mode == 1
            ? r.byte()
            : mode == 2
            ? r.u16()
            : 0;
        if (repeat > 32767 || y + repeat + 1 > height) {
          _bad('Tile run crosses column boundary');
        }
        visit(
          x,
          y,
          _Tile(
            start,
            r.offset,
            payloadEnd,
            repeat + 1,
            block,
            wall,
            blockPaint,
            wallPaint,
            isFramed,
            (a & 24) != 0 || (b & 126) != 0 || (c & 166) != 0 || d != 0,
          ),
        );
        y += repeat + 1;
      }
    }
    if (r.offset != r.end) _bad('Unexpected trailing tile bytes');
  }
}

class _Tile {
  final int start, end, payloadEnd, count, block, wall, blockPaint, wallPaint;
  final bool framed, protected;
  _Tile(
    this.start,
    this.end,
    this.payloadEnd,
    this.count,
    this.block,
    this.wall,
    this.blockPaint,
    this.wallPaint,
    this.framed,
    this.protected,
  );
  Uint8List record(Uint8List source, int count) {
    final repeat = count - 1;
    final extra = repeat == 0
        ? 0
        : repeat < 256
        ? 1
        : 2;
    final result = Uint8List(payloadEnd - start + extra);
    result.setRange(0, payloadEnd - start, source, start);
    result[0] = (result[0] & 63) | (extra << 6);
    if (extra > 0) result[payloadEnd - start] = repeat & 255;
    if (extra == 2) result[payloadEnd - start + 1] = repeat >> 8;
    return result;
  }
}

List<int> _encode(int block, int wall, int blockPaint, int wallPaint) {
  final paintFlags =
      (block >= 0 && blockPaint != 0 ? 8 : 0) |
      (wall != 0 && wallPaint != 0 ? 16 : 0);
  return [
    (block >= 0 ? 2 : 0) | (wall != 0 ? 4 : 0) | (paintFlags != 0 ? 1 : 0),
    if (paintFlags != 0) ...[1, paintFlags],
    if (block >= 0) ...[block, if (blockPaint != 0) blockPaint],
    if (wall != 0) ...[wall, if (wallPaint != 0) wallPaint],
  ];
}
