import 'dart:io';
import 'dart:typed_data';

import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/domain/region_document.dart';

Future<void> main(List<String> args) async {
  final backend = createTerraEngine() as RegionBackend,
      world = File(args.single).readAsBytesSync();
  final records = await backend.readRegion(world, 1, 2, 8, 3),
      objects = await backend.readRegionObjects(world, 1, 2, 8, 3);
  final doc = AdvancedRegionDocument(
    width: 8,
    height: 3,
    records: records,
    objects: objects,
    sourceX: 1,
    sourceY: 2,
  );
  if (doc.objectCount != 3) throw StateError('Missing chest/sign/entity');
  final copy = AdvancedRegionDocument.decode(doc.encode());
  final pasted = await backend.regionOperation(
    world,
    'stamp_tiles',
    copy.stampRequest(1, 10),
    records: copy.records,
    objects: copy.objects,
  );
  final reread = await backend.readRegionObjects(pasted, 1, 10, 8, 3);
  for (var i = 32; i < objects.length; i++) {
    if (reread[i] != objects[i]) throw StateError('Object payload lost at $i');
  }
  copy.setCell(0, 0, {'blockPaint': 3, 'wires': 15});
  final edited = await backend.replaceRegion(world, 1, 2, 8, 3, copy.records);
  final preserved = await backend.readRegionObjects(edited, 1, 2, 8, 3);
  if (base64(preserved) != base64(objects)) {
    throw StateError('In-place metadata changed');
  }
  var partial = false;
  try {
    await backend.readRegionObjects(world, 2, 2, 1, 2);
  } catch (_) {
    partial = true;
  }
  if (!partial) throw StateError('Partial chest accepted');
  copy.setCell(0, 0, {'active': 0});
  var structural = false;
  try {
    await backend.replaceRegion(world, 1, 2, 8, 3, copy.records);
  } catch (_) {
    structural = true;
  }
  if (!structural) throw StateError('Chest deletion orphaned inventory');
  var occupied = false;
  try {
    await backend.regionOperation(
      world,
      'stamp_tiles',
      doc.stampRequest(1, 2),
      records: records,
      objects: objects,
    );
  } catch (_) {
    occupied = true;
  }
  if (!occupied) throw StateError('Occupied furniture target accepted');
  stdout.writeln(
    'PASS: chest inventory/sign text/tile entity clipboard, cosmetic edit preservation, partial selection/structural change/occupancy rejection',
  );
  exit(0);
}

String base64(Uint8List value) => value.join(',');
