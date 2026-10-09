import 'dart:io';
import 'dart:typed_data';

import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/engine.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Provide WLD and PLR fixture paths');
  }
  final engine = createTerraEngine();
  for (final kind in ['wld', 'plr']) {
    final original = await File(args[kind == 'wld' ? 0 : 1]).readAsBytes();
    var doc = await engine.open(original, kind: kind);
    final json = await engine.inspect(doc);
    if (json.isEmpty) throw StateError('Empty $kind metadata');
    final clean = await engine.save(doc);
    if (!_same(original, clean)) {
      throw StateError('$kind clean save changed bytes');
    }
    if (kind == 'wld') {
      await engine.mutate(doc, 'header_patch', {
        'patch': {'spawnTileX': 3, 'spawnTileY': 15},
      });
      final preview = await engine.preview(doc);
      if (preview == null || preview.length < 8 || preview[0] != 137) {
        throw StateError('Missing PNG');
      }
    } else {
      await engine.mutate(doc, 'player_patch', {'name': 'ABC Dart FFI proof'});
    }
    final edited = await engine.save(doc);
    await engine.close(doc);
    doc = await engine.open(edited, kind: kind);
    final updated = await engine.inspect(doc);
    if (kind == 'plr' && updated['name'] != 'ABC Dart FFI proof') {
      throw StateError('Edit lost');
    }
    await engine.close(doc);
    stdout.writeln(
      'PASS Dart isolate FFI $kind: open/inspect/clean save/edit/export/reopen',
    );
  }
  final created = await (engine as CreatablePlayerEngine).createPlayer(
    'ABC empty player',
  );
  final createdBytes = await engine.save(created);
  await engine.close(created);
  final reopened = await engine.open(createdBytes, kind: 'plr');
  if ((await engine.inspect(reopened))['name'] != 'ABC empty player') {
    throw StateError('Created player round-trip failed');
  }
  await engine.close(reopened);
  stdout.writeln('PASS Dart new player: schema/create/encrypt/export/reopen');
  // The app's engine isolate intentionally remains alive for the app lifetime.
  exit(0);
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
