import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/platform/resource_store.dart';
import 'package:terraforge/ui/catalog_browser.dart';

Uint8List pack(
  Map<String, List<int>> files, {
  void Function(Map<String, dynamic>)? alter,
}) {
  var offset = 0;
  final entries = <Map<String, Object>>[];
  for (final file in files.entries) {
    entries.add({
      'path': file.key,
      'offset': offset,
      'bytes': file.value.length,
      'sha256': sha256.convert(file.value).toString(),
    });
    offset += file.value.length;
  }
  final header = <String, dynamic>{
    'format': 1,
    'gameVersion': 'test-version',
    'provenance': {'source': 'synthetic-tests'},
    'entries': entries,
  };
  alter?.call(header);
  final json = utf8.encode(jsonEncode(header));
  final size = ByteData(4)..setUint32(0, json.length, Endian.little);
  return Uint8List.fromList([
    ...ascii.encode('ABCPACK1'),
    ...size.buffer.asUint8List(),
    ...json,
    ...files.values.expand((v) => v),
  ]);
}

Map<String, List<int>> catalogFiles([List<Map<String, Object?>>? rows]) => {
  'catalog/items.json': utf8.encode(
    jsonEncode(
      rows ??
          [
            {
              'id': 17,
              'name': {'en-US': 'Synthetic tool', 'zh-Hans': '测试工具'},
              'internalName': 'TestTool',
              'category': 'tool',
              'maxStack': 1,
            },
            {'id': 800, 'name': 'Synthetic material', 'category': 'material'},
          ],
    ),
  ),
};
void main() {
  test('preserves version, provenance, IDs and multilingual search', () {
    final store = ResourceStore.importPack(pack(catalogFiles()));
    expect(store.catalog.gameVersion, 'test-version');
    expect(store.catalog.provenance['source'], 'synthetic-tests');
    expect(store.catalog.byId('items', 17)?.name, '测试工具');
    expect(store.catalog.byId('items', 18), isNull);
    expect(
      store.catalog.search('items', query: 'synthetic tool').single.id,
      '17',
    );
    expect(store.catalog.search('items', query: '测试').single.id, '17');
    expect(
      store.catalog.search('items', category: 'material').single.numericId,
      800,
    );
    expect(store.catalog.search('items', query: '17').single.id, '17');
    expect(store.catalog.categories('items'), {'tool', 'material'});
  });
  test('nested verified fields cannot be mutated', () {
    final store = ResourceStore.importPack(
      pack(
        catalogFiles([
          {
            'id': 1,
            'gameplay': {'ammo': 1},
            'eligiblePrefixes': [2, 3],
          },
        ]),
      ),
    );
    final fields = store.catalog.byId('items', 1)!.fields;
    expect(
      () => (fields['gameplay'] as Map)['ammo'] = 0,
      throwsUnsupportedError,
    );
    expect(
      () => (fields['eligiblePrefixes'] as List).add(4),
      throwsUnsupportedError,
    );
    expect(store.catalog.categories('items'), {'弹药'});
  });
  Map<String, List<int>> stableFiles({
    int variant = 0,
    int ordinal = 0,
    int paint = 3,
  }) => {
    'catalog/tiles.json': utf8.encode('[{"id":"0:0","type":0,"variant":0}]'),
    'catalog/walls.json': utf8.encode('[{"id":"42:0","type":42,"variant":0}]'),
    'catalog/paints.json': utf8.encode('[{"id":3}]'),
    'catalog/stable-rgb.json': utf8.encode(
      jsonEncode([
        {
          'id': ordinal,
          'kind': 0,
          'type': 0,
          'variant': variant,
          'paint': 0,
          'rgb': [1, 2, 3],
          'stable': 1,
        },
        {
          'id': 1,
          'kind': 1,
          'type': 42,
          'variant': 0,
          'paint': paint,
          'rgb': [4, 5, 6],
          'stable': 1,
        },
      ]),
    ),
  };
  test('stable RGB retains exact order, paint flags, game IDs and version', () {
    final candidates = ResourceStore.importPack(pack(stableFiles())).catalog
        .stableColorCandidates(expectedVersion: 'test-version');
    expect(candidates[0]['rgb'], 0x010203);
    expect(candidates[0]['flags'], 0);
    expect(
      candidates[0]['blockID'],
      0,
    ); // Dirt ID zero is a valid active block.
    expect(candidates[1]['id'], 1);
    expect(candidates[1]['flags'], 3);
    expect(candidates[1]['wallID'], 42);
    expect(candidates[1]['wallPaint'], 3);
    expect(candidates[1]['blockPaint'], 0);
    expect(candidates[1]['version'], 'test-version');
    expect(() => candidates[1]['rgb'] = 0, throwsUnsupportedError);
  });
  test(
    'stable RGB refuses absence, version mismatch, guessing and invalid order',
    () {
      expect(
        () =>
            ResourceStore.importPack(pack(catalogFiles())).catalog
                .stableColorCandidates(),
        throwsStateError,
      );
      expect(
        () =>
            ResourceStore.importPack(pack(stableFiles())).catalog
                .stableColorCandidates(expectedVersion: 'other-version'),
        throwsStateError,
      );
      for (final files in [
        stableFiles(variant: 1),
        stableFiles(ordinal: 9),
        stableFiles(paint: 2),
      ]) {
        expect(
          () =>
              ResourceStore.importPack(pack(files)).catalog
                  .stableColorCandidates(),
          throwsFormatException,
        );
      }
      final files = stableFiles()..remove('catalog/walls.json');
      expect(
        () =>
            ResourceStore.importPack(pack(files)).catalog
                .stableColorCandidates(),
        throwsFormatException,
      );
    },
  );
  test('preserves compound tile IDs', () {
    final data = pack({
      'catalog/tiles.json': utf8.encode(
        '[{"id":"13:2","type":13,"variant":2}]',
      ),
    });
    expect(
      ResourceStore.importPack(data).catalog.byId('tiles', '13:2')?.numericId,
      isNull,
    );
  });
  test('rejects ZIP and arbitrary inputs', () {
    expect(
      () => ResourceStore.importPack(Uint8List.fromList(List.filled(30, 0))),
      throwsFormatException,
    );
    expect(
      () => ResourceStore.importPack(Uint8List.fromList([80, 75, 3, 4])),
      throwsFormatException,
    );
  });
  test('rejects oversized header before parsing', () {
    final input = pack(catalogFiles());
    ByteData.sublistView(input).setUint32(8, 0xffffffff, Endian.little);
    expect(() => ResourceStore.importPack(input), throwsFormatException);
  });
  test('rejects changed data and trailing bytes', () {
    final input = pack(catalogFiles());
    input[input.length - 1] ^= 1;
    expect(() => ResourceStore.importPack(input), throwsFormatException);
    expect(
      () => ResourceStore.importPack(
        Uint8List.fromList([...pack(catalogFiles()), 0]),
      ),
      throwsFormatException,
    );
  });
  for (final path in [
    '../file',
    '/catalog/items.json',
    'catalog/../items.json',
    'catalog/items.JSON',
    'catalog/items.json\n',
    'C:\\items.json',
    'https://site/icon.png',
  ]) {
    test('rejects unsafe path $path', () {
      expect(
        () => ResourceStore.importPack(pack({path: utf8.encode('[]')})),
        throwsFormatException,
      );
    });
  }
  test(
    'rejects offset overlap, duplicate paths, invalid hash, unknown version',
    () {
      for (final alteration in <void Function(Map<String, dynamic>)>[
        (h) => h['entries'][0]['offset'] = 1,
        (h) => h['entries'].add(h['entries'][0]),
        (h) => h['entries'][0]['sha256'] = '0' * 64,
        (h) => h['format'] = 2,
        (h) => h['gameVersion'] = null,
      ]) {
        expect(
          () =>
              ResourceStore.importPack(pack(catalogFiles(), alter: alteration)),
          throwsFormatException,
        );
      }
    },
  );
  test('rejects duplicate/missing IDs and external icons', () {
    for (final rows in <List<Map<String, Object?>>>[
      [
        {'id': 1},
        {'id': '1'},
      ],
      [
        {'name': 'missing'},
      ],
      [
        {'id': 1, 'icon': 'https://example.com/private.png'},
      ],
    ]) {
      expect(
        () => ResourceStore.importPack(pack(catalogFiles(rows))),
        throwsFormatException,
      );
    }
  });
  test('rejects PNG dimension bomb', () {
    final png = Uint8List(33)..setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
    png.setAll(12, ascii.encode('IHDR'));
    ByteData.sublistView(png)
      ..setUint32(16, 8192)
      ..setUint32(20, 8192);
    final hash = sha256.convert(png).toString();
    expect(
      () => ResourceStore.importPack(
        pack({...catalogFiles(), 'images/$hash.png': png}),
      ),
      throwsFormatException,
    );
  });
  test('icon reads are lazy, immutable, isolated from caller input', () {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=',
    );
    final path = 'images/${sha256.convert(png)}.png';
    final input = pack({
      ...catalogFiles([
        {'id': 1, 'icon': path},
      ]),
      path: png,
    });
    final store = ResourceStore.importPack(input);
    input.fillRange(0, input.length, 0);
    final image = store.iconBytes(store.catalog.byId('items', 1)!);
    expect(image, png);
    expect(() => image![0] = 0, throwsUnsupportedError);
  });
  testWidgets('large catalogs build only viewport rows and search all IDs', (
    tester,
  ) async {
    final store = ResourceStore.importPack(
      pack(
        catalogFiles([
          for (var i = 0; i < 10000; i++) {'id': i, 'name': 'Test row $i'},
        ]),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CatalogBrowser(store: store)),
      ),
    );
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    expect(find.text('Test row 9999'), findsNothing);
    await tester.enterText(find.byType(TextField), '9999');
    await tester.pump();
    expect(find.text('Test row 9999'), findsOneWidget);
    await tester.tap(find.text('Test row 9999'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
