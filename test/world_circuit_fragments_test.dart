import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/domain/world_circuit_geometry.dart';
import 'package:terraforge/domain/resource_catalog.dart';

import 'package:terraforge/engine/world_circuit_session.dart';

ResourceCatalog _catalog() => ResourceCatalog(
  gameVersion: '1.4.5.8',
  provenance: const {'fixture': 'original'},
  families: {
    'tile-object-data': [
      for (var alternate = 0; alternate < 2; alternate++)
        CatalogEntry('tile-object-data', {
          'id': 'fixture:$alternate',
          'tile': 15,
          'style': 0,
          'width': 2,
          'height': 3,
          'frameX': alternate * 36,
          'frameY': 24,
          'coordinateWidth': 16,
          'coordinatePadding': 2,
          'coordinateHeights': [16, 20, 10],
          'alternate': alternate,
        }),
      CatalogEntry('tile-object-data', {
        'id': 'display',
        'tile': 395,
        'style': 0,
        'width': 2,
        'height': 2,
        'frameX': 0,
        'frameY': 0,
        'coordinateWidth': 16,
        'coordinatePadding': 2,
        'coordinateHeights': [16, 16],
      }),
    ],
  },
);

Uint8List _words(List<int> values) {
  final data = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setUint32(i * 4, values[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List _objects({int x = 4, int y = 6}) =>
    _words([0x31424f43, 1, 326, 0, 32, x, y, 0]);

WorldCircuitResult _result(
  int kind,
  Uint8List records, {
  int count = 1,
  Uint8List? objects,
}) => WorldCircuitResult(
  9,
  [2, 0, 64, 64, ...List.filled(20, 0)],
  records,
  resultKind: kind,
  resultCount: count,
  reserved: 0,
  objects: objects,
);

final _pageBytes = _words([17, 4, 6, 2, 2, 2, 2, 0]);
final _cellBytes = _words([
  4,
  6,
  0,
  0xffffffff,
  0,
  1 << 24,
  0,
  0,
  5,
  7,
  0,
  0xffffffff,
  0,
  2 << 24,
  0,
  0,
]);

class _Backend implements WorldCircuitBackend {
  final commands = <WorldCircuitCommand>[];
  final events = <String>[];
  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List world) async =>
      _result(0, Uint8List(0), count: 0);
  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    commands.add(command);
    events.add('begin${command.words[1]}');
    await Future<void>.delayed(Duration.zero);
    events.add('end${command.words[1]}');
    if (command.words[1] == 7) return _result(7, _pageBytes);
    if (command.words[1] == 8) {
      return _result(8, _cellBytes, count: 2, objects: _objects());
    }
    return _result(command.words[1], _words([4, 6, 1, 0]), count: 0);
  }

  @override
  Future<void> closeWorldCircuit(int session) async {}
}

void main() {
  test('imported geometry preserves unequal rows, deduplicates and bounds versions', () {
    final geometry = WorldCircuitGeometry.fromCatalog(
      _catalog(),
      worldVersion: 326,
    );
    expect(geometry.records.length, 16 * 4);
    // The second row follows 16 + 2; the third follows another 20 + 2.
    final frames = <int>[];
    for (var i = 0; i < geometry.records.length; i += 4) {
      if (geometry.records[i] == 15) frames.add(geometry.records[i + 1] >> 16);
    }
    expect(frames.toSet(), {24, 42, 64});
    expect(geometry.unverifiedSupportFrameCount, 12);
    expect(
      () => WorldCircuitGeometry.fromCatalog(_catalog(), worldVersion: 139),
      throwsFormatException,
    );
    final rows = _catalog().families['tile-object-data']!;
    final conflict = CatalogEntry('tile-object-data', {
      ...rows.first.fields,
      'id': 'conflict',
      'width': 1,
    });
    final catalog = ResourceCatalog(
      gameVersion: '1.4.5.8',
      provenance: const {},
      families: {
        'tile-object-data': [...rows, rows.first, conflict],
      },
    );
    final filtered = WorldCircuitGeometry.fromCatalog(
      catalog,
      worldVersion: 326,
    );
    expect(filtered.ambiguousFrameCount, 3);
    expect(filtered.records.length, geometry.records.length - 12);
  });

  test(
    'unknown placement anchors stay blocked after valid sparse extraction',
    () {
      final geometry = WorldCircuitGeometry.fromCatalog(
        _catalog(),
        worldVersion: 326,
      );
      const fragment = WorldCircuitFragment(
        id: 1,
        x: 4,
        y: 6,
        width: 2,
        height: 3,
        cells: 6,
        wireCells: 1,
        flags: 0,
      );
      final cells = <int>[];
      for (var x = 0; x < 2; x++) {
        for (var y = 0; y < 3; y++) {
          cells.addAll([
            4 + x,
            6 + y,
            15 | (1 << 16),
            x * 18 | ([24, 42, 64][y] << 16),
            0,
            1 << 24,
            0,
            0,
          ]);
        }
      }
      final extraction = WorldCircuitExtraction.fromResult(
        _result(8, _words(cells), count: 6, objects: _objects()),
        fragment,
      );
      expect(extraction.canStamp, true);
      expect(geometry.supportsVerifiedFor(extraction), false);
    },
  );

  test(
    'session sends geometry once and requires reset for a changed set',
    () async {
      final backend = _Backend(), geometry = [144, 0, 1 << 16 | 1 << 24, 0];
      final session = WorldCircuitSession(backend, Uint8List(1));
      await session.open();
      await session.fragments(geometry: geometry);
      await session.fragments(geometry: geometry);
      expect(backend.commands[0].records, geometry);
      expect(backend.commands[1].records, isEmpty);
      await expectLater(
        session.fragments(geometry: [4, 0, 1 << 16 | 1 << 24, 13]),
        throwsStateError,
      );
      expect(backend.commands.length, 2);
      await session.reset();
      await session.fragments(geometry: geometry);
      expect(backend.commands.last.records, geometry);
      await session.close();
      session.dispose();
    },
  );

  test('unverified attachment alternates stay blocked while sign branches are exact', () {
    final base = _catalog().families['tile-object-data']!.last.fields;
    final catalog = ResourceCatalog(
      gameVersion: '1.4.5.8',
      provenance: const {},
      families: {
        'tile-object-data': [
          CatalogEntry('tile-object-data', {
            ...base,
            'id': 'alternate',
            'alternate': 1,
            'frameX': 36,
          }),
          CatalogEntry('tile-object-data', {
            ...base,
            'id': 'wall-sign',
            'tile': 55,
            'alternate': 4,
            'frameX': 144,
          }),
        ],
      },
    );
    final geometry = WorldCircuitGeometry.fromCatalog(
      catalog,
      worldVersion: 326,
    );
    expect(geometry.unverifiedSupportFrameCount, 4);
    for (var i = 0; i < geometry.records.length; i += 4) {
      expect(geometry.records[i + 3], geometry.records[i] == 55 ? 6 : 0);
    }
  });

  test('fragment wire commands freeze geometry and bound record budgets', () {
    final geometry = [144, 0, 1 << 16 | 1 << 24, 1];
    final command = WorldCircuitCommand.fragments(geometry: geometry);
    geometry[0] = 4;
    expect(command.words[1], 7);
    expect(command.records.first, 144);
    expect(() => command.records[0] = 4, throwsUnsupportedError);
    expect(
      () => WorldCircuitCommand.fragments(count: 32769),
      throwsFormatException,
    );
    expect(
      () => WorldCircuitCommand.fragments(geometry: [1, 2, 3]),
      throwsFormatException,
    );
    expect(
      () => WorldCircuitCommand.fragments(geometry: [1, 0, 0, 0]),
      throwsFormatException,
    );
    expect(
      () => WorldCircuitCommand.extract(1, maxCells: 0),
      throwsFormatException,
    );
    expect(
      () => WorldCircuitCommand.extract(1, maxObjectBytes: 31),
      throwsFormatException,
    );
    final extract = WorldCircuitCommand.extract(17);
    expect(extract.words[1], 8);
    expect(extract.words[7], 17);
    expect(extract.words[13], 6);
    expect(extract.mutates, false);
  });

  test(
    'READY page total remains distinct from emitted descriptors and flags',
    () {
      final page = WorldCircuitFragmentPage.fromResult(
        _result(7, _pageBytes, count: 18),
        offset: 3,
        count: 1,
      );
      expect(page.total, 18);
      expect(page.hasMore, true);
      expect(page.fragments.single.id, 17);
      expect(page.fragments.single.canStamp, true);
      final flagged = WorldCircuitFragmentPage.fromResult(
        _result(7, _words([8, 0, 0, 2, 2, 4, 2, 15])),
        offset: 0,
        count: 1,
      ).fragments.single;
      expect(flagged.completeFootprint, false);
      expect(flagged.requiresObjects, true);
      expect(flagged.isModded, true);
      expect(flagged.missingSupport, true);
      expect(flagged.canStamp, false);
      expect(
        () => WorldCircuitFragmentPage.fromResult(
          _result(8, _pageBytes),
          offset: 0,
          count: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => WorldCircuitFragmentPage.fromResult(
          _result(7, _pageBytes, count: 0),
          offset: 0,
          count: 1,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'sparse extraction normalizes coordinates and captures independent COB1',
    () {
      final descriptor = WorldCircuitFragmentPage.fromResult(
        _result(7, _pageBytes),
        offset: 0,
        count: 1,
      ).fragments.single;
      final records = Uint8List.fromList(_cellBytes), objects = _objects();
      final extraction = WorldCircuitExtraction.fromResult(
        _result(8, records, count: 2, objects: objects),
        descriptor,
      );
      records.fillRange(0, records.length, 0);
      objects.fillRange(0, objects.length, 0);
      final data = ByteData.sublistView(extraction.records);
      expect(
        [data.getUint32(0, Endian.little), data.getUint32(4, Endian.little)],
        [0, 0],
      );
      expect(
        [data.getUint32(32, Endian.little), data.getUint32(36, Endian.little)],
        [1, 1],
      );
      expect(data.getInt16(12, Endian.little), -1);
      expect(extraction.canStamp, true);
      expect(
        ByteData.sublistView(extraction.objects!).getUint32(20, Endian.little),
        4,
      );
      extraction.records[0] = 99;
      extraction.objects![0] = 0;
      expect(extraction.records[0], 0);
      expect(extraction.objects![0], 0x43);
      expect(
        () => WorldCircuitExtraction.fromResult(
          _result(8, _cellBytes, count: 1, objects: _objects()),
          descriptor,
        ),
        throwsFormatException,
      );
      expect(
        () => WorldCircuitExtraction.fromResult(
          _result(8, _cellBytes, count: 2, objects: _objects(x: 0)),
          descriptor,
        ),
        throwsFormatException,
      );
      final invalid = Uint8List.fromList(_cellBytes)..[24] = 1;
      expect(
        () => WorldCircuitExtraction.fromResult(
          _result(8, invalid, count: 2, objects: _objects()),
          descriptor,
        ),
        throwsFormatException,
      );
    },
  );

  test('missing support is readable but never marked safe to stamp', () {
    const descriptor = WorldCircuitFragment(
      id: 17,
      x: 4,
      y: 6,
      width: 2,
      height: 2,
      cells: 2,
      wireCells: 2,
      flags: 8,
    );
    final extraction = WorldCircuitExtraction.fromResult(
      _result(8, _cellBytes, count: 2, objects: _objects()),
      descriptor,
    );
    expect(extraction.records.length, 64);
    expect(extraction.canStamp, false);
    const needsObject = WorldCircuitFragment(
      id: 17,
      x: 4,
      y: 6,
      width: 2,
      height: 2,
      cells: 2,
      wireCells: 2,
      flags: 2,
    );
    expect(
      () => WorldCircuitExtraction.fromResult(
        _result(8, _cellBytes, count: 2, objects: _objects()),
        needsObject,
      ),
      throwsFormatException,
    );
  });

  test(
    'session queries preserve viewport and extraction settles before snapshot',
    () async {
      final backend = _Backend();
      final active = WorldCircuitSession(backend, Uint8List(1));
      await active.open();
      await active.command(WorldCircuitCommand.viewport(4, 6, 2, 2));
      final viewport = active.result;
      final page = await active.fragments();
      expect(identical(active.result, viewport), true);
      expect(active.dirty, false);
      final pending = active.command(WorldCircuitCommand.ticks(1));
      active.run();
      final snapshot = active.extract(page.fragments.single);
      expect(active.running, false);
      await pending;
      final extracted = await snapshot;
      expect(extracted.recordCount, 2);
      expect(
        backend.events.indexOf('end3'),
        lessThan(backend.events.indexOf('begin8')),
      );
      expect(active.dirty, true);
      await active.reset();
      await expectLater(
        active.extract(page.fragments.single),
        throwsStateError,
      );
      expect(backend.commands.where((c) => c.words[1] == 8).length, 1);
      await active.close();
      active.dispose();
    },
  );
}
