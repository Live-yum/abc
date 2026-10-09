import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/map_backend.dart';

import '../tool/perf/map_fixture.dart';

void main() {
  test('real isolate owns MAP grid, validates export and preserves old session on rejection', () async {
    final backend = createMapBackend(), source = syntheticMap();
    try {
      final info = await backend.open(source);
      expect(info.width, 130);
      expect(info.canUndo, isFalse);
      expect(await backend.exportVerified(), source);
      await expectLater(backend.open(Uint8List(4)), throwsStateError);
      expect(await backend.exportVerified(), source);
      await expectLater(
        backend.open(source, expectedWorld: {'worldId': -99}),
        throwsStateError,
      );
      expect(await backend.exportVerified(), source);
      final edit = await backend.editRect(0, 0, 64, 64, light: 211, color: 8);
      expect(edit.isModified, isTrue);
      expect(edit.canUndo, isTrue);
      final changed = await backend.exportVerified();
      expect(changed, isNot(source));
      await backend.undo();
      expect(await backend.exportVerified(), source);
      await backend.redo();
      expect(await backend.exportVerified(), changed);
      final raster = await backend.render(maxWidth: 65);
      expect(raster.rgba.length, raster.width * raster.height * 4);
      await backend.close();
      await expectLater(backend.exportVerified(), throwsStateError);
      await backend.open(source);
      expect(await backend.exportVerified(), source);
    } finally {
      await backend.dispose();
    }
    await expectLater(backend.open(source), throwsStateError);
  });
  test(
    'closing owner cancels pending work without accepting a stale response',
    () async {
      final backend = createMapBackend();
      final pending = backend.open(syntheticMap());
      final check = expectLater(pending, throwsStateError);
      await backend.close();
      await check;
      await backend.open(syntheticMap());
      await backend.dispose();
    },
  );
  test('open snapshots caller bytes before isolate startup', () async {
    final backend = createMapBackend(), source = syntheticMap();
    final original = Uint8List.fromList(source);
    final opening = backend.open(source);
    source.fillRange(0, source.length, 0);
    try {
      await opening;
      expect(await backend.exportVerified(), original);
    } finally {
      await backend.dispose();
    }
  });
}
