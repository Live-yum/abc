import 'dart:typed_data';

import 'package:terraforge/domain/region_document.dart';
import 'package:terraforge/domain/resource_catalog.dart';

/// Small invented metadata rows for protocol/geometry tests, not a game catalog.
ResourceCatalog placementCatalog({String version = '1.4.5.8'}) =>
    ResourceCatalog(
      gameVersion: version,
      provenance: const {'fixture': 'synthetic'},
      families: {
        'items': [
          CatalogEntry('items', {
            'id': 34,
            'name': 'Test furniture',
            'createTile': 15,
            'placeStyle': 0,
          }),
          CatalogEntry('items', {
            'id': 1000,
            'name': 'Test sword',
            'createTile': -1,
          }),
          CatalogEntry('items', {
            'id': 48,
            'name': 'Test chest',
            'createTile': 21,
            'placeStyle': 0,
          }),
          CatalogEntry('items', {
            'id': 3276,
            'name': 'Test frame',
            'createTile': 395,
            'placeStyle': 0,
          }),
          CatalogEntry('items', {
            'id': 999,
            'name': 'Missing geometry',
            'createTile': 12,
            'placeStyle': 0,
          }),
        ],
        'tile-object-data': [
          CatalogEntry('tile-object-data', {
            'id': '21:0:0:0',
            'tile': 21,
            'style': 0,
            'width': 2,
            'height': 2,
            'frameX': 0,
            'frameY': 0,
            'coordinateWidth': 16,
            'coordinatePadding': 2,
            'coordinateHeights': [16, 18],
            'alternate': 0,
            'random': 0,
          }),
          for (var alternate = 0; alternate < 2; alternate++)
            CatalogEntry('tile-object-data', {
              'id': '15:0:$alternate:0',
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
              'random': 0,
            }),
          CatalogEntry('tile-object-data', {
            'id': '395:0:0:0',
            'tile': 395,
            'style': 0,
            'width': 2,
            'height': 2,
            'frameX': 0,
            'frameY': 0,
            'coordinateWidth': 16,
            'coordinatePadding': 2,
            'coordinateHeights': [16, 16],
            'alternate': 0,
            'random': 0,
          }),
        ],
      },
    );

AdvancedRegionDocument blankRegion({
  int width = 6,
  int height = 5,
  int sourceX = 10,
  int sourceY = 20,
  Uint8List? objects,
}) {
  final data = ByteData(width * height * 32);
  for (var x = 0; x < width; x++) {
    for (var y = 0; y < height; y++) {
      final at = (x * height + y) * 32;
      data.setUint32(at, x, Endian.little);
      data.setUint32(at + 4, y, Endian.little);
      data.setInt16(at + 12, -1, Endian.little);
      data.setInt16(at + 14, -1, Endian.little);
    }
  }
  return AdvancedRegionDocument(
    width: width,
    height: height,
    sourceX: sourceX,
    sourceY: sourceY,
    records: data.buffer.asUint8List(),
    objects: objects,
  );
}

// Deliberately synthetic item IDs, names and rows for companion schema tests.
const metadataTestShapes = <int, (int, int)>{
  21: (2, 2),
  88: (3, 2),
  467: (2, 2),
  55: (2, 2),
  85: (2, 2),
  425: (2, 2),
  573: (2, 2),
  378: (2, 3),
  395: (2, 2),
  423: (1, 1),
  470: (2, 3),
  471: (3, 3),
  475: (3, 4),
  520: (1, 1),
  597: (3, 4),
  698: (1, 2),
  723: (1, 1),
  724: (1, 1),
};
ResourceCatalog metadataPlacementCatalog({
  Map<int, Map<String, Object?>> overrides = const {},
}) => ResourceCatalog(
  gameVersion: '1.4.5.8',
  provenance: const {'fixture': 'synthetic'},
  families: {
    'items': [
      for (final tile in metadataTestShapes.keys)
        CatalogEntry('items', {
          'id': 6000 + tile,
          'name': 'Test metadata $tile',
          'createTile': tile,
          'placeStyle': tile == 423 ? 6 : 0,
        }),
    ],
    'tile-object-data': [
      for (final entry in metadataTestShapes.entries)
        CatalogEntry('tile-object-data', {
          'id': '${entry.key}:synthetic',
          'tile': entry.key,
          'style': entry.key == 423 ? 6 : 0,
          'width': entry.value.$1,
          'height': entry.value.$2,
          'frameX': 0,
          'frameY': entry.key == 423 ? 108 : 0,
          'coordinateWidth': 16,
          'coordinatePadding': 2,
          'coordinateHeights': List.filled(entry.value.$2, 16),
          ...?overrides[entry.key],
        }),
    ],
  },
);
