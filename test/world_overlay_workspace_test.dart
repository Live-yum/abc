import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/files.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;

class _Engine extends FakeEngine {
  @override
  Future<Map<String, dynamic>> inspect(EngineDocument doc) async => {
    'header': {
      'worldName': 'Overlay fixture',
      'maxTilesX': 1024,
      'maxTilesY': 512,
    },
    'format': {'version': 326},
  };
}

class _Region implements RegionBackend {
  int calls = 0;
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<Uint8List> readRegion(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
  ) async {
    calls++;
    await pending?.future;
    if (fail) throw const EngineException('overlay read failed');
    final bytes = Uint8List(width * height * 32),
        data = ByteData.sublistView(bytes);
    for (var xx = 0; xx < width; xx++) {
      for (var yy = 0; yy < height; yy++) {
        final offset = (xx * height + yy) * 32;
        data.setUint32(offset, xx, Endian.little);
        data.setUint32(offset + 4, yy, Endian.little);
        data.setUint32(offset + 20, 128 | (1 << 8) | (15 << 24), Endian.little);
      }
    }
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused');
}

void main() {
  test(
    'viewport reads preserve save, validate bounds and clear on edit/switch',
    () async {
      final engine = _Engine(),
          region = _Region(),
          files = FakeFiles()
            ..next = PickedFile('first.wld', Uint8List.fromList([1, 2]));
      final app = Workspace(
        engine: engine,
        files: files,
        regionBackend: region,
      );
      await app.dispatch('import', {'kind': 'world'});
      await app.dispatch('worldOverlay', {
        'x': 2,
        'y': 3,
        'width': 2,
        'height': 4,
      });
      expect(app.view.error, isEmpty);
      expect(app.view.worldOverlay, isNotNull);
      expect(app.view.worldOverlay!.x, 2);
      expect(app.view.worldOverlay!.height, 4);
      expect(app.view.result['worldModified'], isFalse);
      expect(app.view.result['worldCanUndo'], isFalse);
      expect(engine.handles.length, 1);
      await app.dispatch('export', {'kind': 'world'});
      expect(files.bytes, [1, 2]);
      for (final invalid in [
        {'x': 0, 'y': 0, 'width': 1024, 'height': 512},
        {'x': 1023, 'y': 0, 'width': 2, 'height': 1},
        {'x': 0.5, 'y': 0, 'width': 2, 'height': 1},
      ]) {
        await app.dispatch('worldOverlay', invalid);
        expect(app.view.error, isNotEmpty);
      }
      expect(region.calls, 1);
      await app.dispatch('stageWorld', {'field': 'name', 'value': 'Changed'});
      expect(app.view.error, isEmpty);
      expect(app.view.worldOverlay, isNull);
      await app.dispatch('worldOverlay', {
        'x': 0,
        'y': 0,
        'width': 1,
        'height': 1,
      });
      expect(app.view.worldOverlay, isNotNull);
      files.next = PickedFile('second.wld', Uint8List.fromList([3, 4]));
      await app.dispatch('import', {'kind': 'world'});
      expect(app.view.worldOverlay, isNull);
      await app.close();
      app.dispose();
    },
  );

  test(
    'failed overlay parse reopens intact world and leaves no stale overlay',
    () async {
      final engine = _Engine(),
          region = _Region()..fail = true,
          files = FakeFiles()
            ..next = PickedFile('first.wld', Uint8List.fromList([1, 2]));
      final app = Workspace(
        engine: engine,
        files: files,
        regionBackend: region,
      );
      await app.dispatch('import', {'kind': 'world'});
      await app.dispatch('worldOverlay', {
        'x': 0,
        'y': 0,
        'width': 1,
        'height': 1,
      });
      expect(app.view.error, 'overlay read failed');
      expect(app.view.worldOverlay, isNull);
      expect(app.view.world['name'], 'Overlay fixture');
      expect(engine.handles.length, 1);
      await app.dispatch('export', {'kind': 'world'});
      expect(files.bytes, [1, 2]);
      await app.close();
      app.dispose();
    },
  );
  test(
    'world metadata remains visible while the singleton engine is released',
    () async {
      final region = _Region()..pending = Completer<void>();
      final files = FakeFiles()
        ..next = PickedFile('world.wld', Uint8List.fromList([1, 2]));
      final app = Workspace(
        engine: _Engine(),
        files: files,
        regionBackend: region,
      );
      await app.dispatch('import', {'kind': 'world'});
      final loading = app.dispatch('worldOverlay', {
        'x': 0,
        'y': 0,
        'width': 1,
        'height': 1,
      });
      await Future<void>.delayed(Duration.zero);
      expect(app.view.busy, isTrue);
      expect(app.view.world['maxTilesX'], 1024);
      expect(app.view.world['name'], 'Overlay fixture');
      region.pending!.complete();
      await loading;
      expect(app.view.error, isEmpty);
      expect(app.view.worldOverlay, isNotNull);
      await app.close();
      app.dispose();
    },
  );
}
