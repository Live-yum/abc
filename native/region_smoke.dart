// Original synthetic integration test; no real saves or game assets.
import 'dart:io';
import 'dart:typed_data';

import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';

Future<void> main(List<String> args) async {
  final world = File(args.single).readAsBytesSync();
  final original = Uint8List.fromList(world);
  final backend = createTerraEngine() as RegionBackend;
  final matched = await backend.matchColors(
    Uint32List.fromList([0xfe0000, 0xfe]),
    Uint32List.fromList([0xff0000, 0xff0000, 0xff]),
    Uint32List.fromList([0, 3, 2]),
  );
  if (matched[0] != 0 || matched[1] != 2) {
    throw StateError('Core RGB matching mismatch');
  }
  final region = await backend.readRegion(world, 1, 2, 2, 3);
  if (region.length != 192) throw StateError('Incomplete region');
  final words = ByteData.sublistView(region);
  words.setUint32(16, 1 | (4 << 24), Endian.little); // wall and paint
  words.setUint32(
    20,
    128 | (1 << 8) | (2 << 16) | (15 << 24),
    Endian.little,
  ); // liquid, slope, all wires
  final candidate = await backend.regionOperation(world, 'stamp_tiles', {
    'x': 2,
    'y': 4,
    'width': 2,
    'height': 3,
    'recordCount': 6,
    'recordSourceId': 2,
    'mode': 'overlay',
  }, records: region);
  final readback = await backend.readRegion(candidate, 2, 4, 2, 3);
  if (readback.length != region.length) throw StateError('Readback size');
  for (var i = 0; i < region.length; i++) {
    if (region[i] != readback[i]) throw StateError('Layer mismatch at $i');
  }
  final cleared = Uint8List.fromList(readback);
  final clearData = ByteData.sublistView(cleared);
  clearData.setUint32(8, 0, Endian.little);
  clearData.setUint32(16, 0, Endian.little);
  clearData.setUint32(20, 0, Endian.little);
  final replaced = await backend.replaceRegion(candidate, 2, 4, 2, 3, cleared);
  final replacedRead = await backend.readRegion(replaced, 2, 4, 2, 3);
  final rd = ByteData.sublistView(replacedRead);
  if (rd.getUint32(8, Endian.little) != 0 ||
      rd.getUint32(16, Endian.little) != 0 ||
      rd.getUint32(20, Endian.little) != 0) {
    throw StateError('Erase failed');
  }
  final maps = Uint8List(24);
  maps[10] = 3;
  maps[16] = 1;
  maps[22] = 1;
  final pixels = await backend.writeIndexedPixels(
    world,
    2,
    3,
    2,
    2,
    maps,
    Uint16List.fromList([1, 0, 0, 1]),
  );
  if (pixels.isEmpty) throw StateError('Pixel output missing');
  var rejected = false;
  try {
    await backend.regionOperation(world, 'stamp_tiles', {
      'x': 2,
      'y': 4,
      'width': 2,
      'height': 3,
      'recordCount': 6,
      'recordSourceId': 2,
      'mode': 'overlay',
    }, records: region.sublist(0, 32));
  } catch (_) {
    rejected = true;
  }
  if (!rejected) throw StateError('Truncated source accepted');
  for (var i = 0; i < world.length; i++) {
    if (world[i] != original[i]) throw StateError('Source mutated');
  }
  final after = await backend.readRegion(world, 1, 2, 2, 3);
  if (after.length != 192) {
    throw StateError('Failed operation leaked ownership');
  }
  stdout.writeln(
    'PASS: complete tile layers, sparse stamp readback, indexed pixel, rejection, immutable source and cleanup',
  );
  exit(0);
}
