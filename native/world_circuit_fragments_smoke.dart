import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:terraforge/domain/region_document.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

Future<void> main(List<String> args) async {
  final engine = createTerraEngine(), backend = engine as WorldCircuitBackend;
  final region = engine as RegionBackend,
      source = File(args.first).readAsBytesSync();
  final geometry = <int>[];
  for (final shape in [(21, 2, 2), (55, 2, 2), (378, 2, 3)]) {
    for (var x = 0; x < shape.$2; x++) {
      for (var y = 0; y < shape.$3; y++) {
        geometry.addAll([
          shape.$1,
          x * 18 | (y * 18 << 16),
          x | (y << 8) | (shape.$2 << 16) | (shape.$3 << 24),
          1,
        ]);
      }
    }
  }
  void check(bool valid, String text) {
    if (!valid) throw StateError(text);
  }

  final opened = await backend.openWorldCircuit(source), id = opened.session;
  final first = WorldCircuitFragmentPage.fromResult(
    await backend.commandWorldCircuit(
      id,
      WorldCircuitCommand.fragments(count: 1, geometry: geometry),
    ),
    offset: 0,
    count: 1,
  );
  check(
    first.total == 2 && first.hasMore,
    'Missing paged electrical fragments',
  );
  final page2 = WorldCircuitFragmentPage.fromResult(
    await backend.commandWorldCircuit(
      id,
      WorldCircuitCommand.fragments(offset: 1, count: 1),
    ),
    offset: 1,
    count: 1,
  );
  final selected = [
    ...first.fragments,
    ...page2.fragments,
  ].singleWhere((f) => f.requiresObjects);
  check(
    selected.canStamp,
    'Source object/support footprint incomplete: ${selected.flags}',
  );
  final extracted = WorldCircuitExtraction.fromResult(
    await backend.commandWorldCircuit(
      id,
      WorldCircuitCommand.extract(selected.id),
    ),
    selected,
  );
  check(
    extracted.objectCount == 3 && extracted.canStamp,
    'Missing chest/sign/entity companion',
  );
  final companion = extracted.objects!,
      captured = Uint8List.fromList(companion);
  final wires = [
    ...first.fragments,
    ...page2.fragments,
  ].singleWhere((f) => !f.requiresObjects);
  final next = WorldCircuitExtraction.fromResult(
    await backend.commandWorldCircuit(
      id,
      WorldCircuitCommand.extract(wires.id),
    ),
    wires,
  );
  check(
    next.objectCount == 0 && next.records.length == 64,
    'Wire-only fragment changed',
  );
  check(
    base64Encode(extracted.objects!) == base64Encode(captured),
    'COB1 sink alias',
  );
  var rejected = false;
  try {
    await backend.commandWorldCircuit(
      id,
      WorldCircuitCommand.extract(selected.id, maxCells: 1),
    );
  } catch (_) {
    rejected = true;
  }
  check(rejected, 'Oversize extraction accepted');
  await backend.commandWorldCircuit(
    id,
    WorldCircuitCommand.extract(selected.id),
  );
  await backend.closeWorldCircuit(id);
  final doc = AdvancedRegionDocument(
    width: selected.width,
    height: selected.height,
    sourceX: selected.x,
    sourceY: selected.y,
    records: extracted.records,
    objects: companion,
  );
  final request = doc.stampRequest(18, 10);
  final candidate = await region.regionOperation(
    source,
    'stamp_tiles',
    request,
    records: doc.records,
    objects: doc.objects,
  );
  final objects = await region.readRegionObjects(
    candidate,
    18,
    10,
    doc.width,
    doc.height,
  );
  check(
    base64Encode(objects.sublist(32)) == base64Encode(companion.sublist(32)),
    'Object bytes changed during stamp',
  );
  var collision = false;
  try {
    await region.regionOperation(
      candidate,
      'stamp_tiles',
      request,
      records: doc.records,
      objects: doc.objects,
    );
  } catch (_) {
    collision = true;
  }
  check(collision, 'Occupied destination accepted');
  check(
    base64Encode(source) == base64Encode(File(args.first).readAsBytesSync()),
    'Original changed',
  );
  if (args.length > 1) {
    final directory = Directory(args[1])..createSync(recursive: true);
    File('${directory.path}/source.wld').writeAsBytesSync(source);
    File('${directory.path}/fragment.json').writeAsStringSync(
      jsonEncode({
        'geometry': geometry,
        'selectedId': selected.id,
        'records': base64Encode(doc.records),
        'objects': base64Encode(companion),
        'request': request,
      }),
    );
  }
  stdout.writeln(
    'PASS: native real commands 7/8, pagination, sparse supported footprints, immutable nonempty COB1, budget rejection/recovery, safe stamp/readback and collision rejection',
  );
}
