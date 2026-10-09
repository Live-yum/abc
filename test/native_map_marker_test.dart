import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  final Uint8List source;
  Uint8List? output;
  _Files(this.source);
  @override
  Future<PickedFile?> pick(String kind) async =>
      PickedFile('markers.wld', source);
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = bytes;
    return true;
  }
}

void main() {
  test(
    'actual native chest-item and tile markers render requested colors without world mutation',
    () async {
      final original = await File('assets/qa/synthetic-objects.wld')
          .readAsBytes();
      final engine = createTerraEngine(), files = _Files(original);
      final app = Workspace(
        engine: engine,
        files: files,
        regionBackend: engine as RegionBackend,
      );
      await app.dispatch('import', {'kind': 'world'});
      final base = app.view.worldPreview;
      await app.dispatch('markerToggle', {'kind': 'item', 'id': 8});
      await app.dispatch('markerStyle', {
        'kind': 'item',
        'id': 8,
        'color': '#FF00FF',
        'radius': 2,
        'lineWidth': 1,
      });
      await app.dispatch('markerToggle', {'kind': 'tile', 'id': 55});
      await app.dispatch('markerStyle', {
        'kind': 'tile',
        'id': 55,
        'color': '#00FFFF',
        'radius': 2,
        'lineWidth': 1,
      });
      await app.dispatch('markerRender');
      expect(app.view.error, isEmpty);
      expect(app.view.result['markersVisible'], isTrue);
      expect(app.view.worldPreview, isNot(base));
      final image = img.decodePng(app.view.worldPreview!)!;
      final colors = <int>{
        for (final p in image)
          (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt(),
      };
      expect(colors, contains(0xff00ff));
      expect(colors, contains(0x00ffff));
      expect(app.view.result['worldModified'], isFalse);
      expect(app.view.result['worldCanUndo'], isFalse);
      await app.dispatch('export', {'kind': 'world'});
      expect(files.output, original);
      await app.dispatch('markerVisibility', {'visible': false});
      expect(app.view.worldPreview, base);
      await app.dispatch('markerClear', {'confirmed': true});
      for (final frame in [0, 18]) {
        final selector = {'locate': 1, 'frame_x': frame, 'frame_y': 0};
        await app.dispatch('markerToggle', {
          'kind': 'tile',
          'id': 55,
          'selector': selector,
        });
        await app.dispatch('markerStyle', {
          'kind': 'tile',
          'id': 55,
          'selector': selector,
          'color': frame == 0 ? '#FF00FF' : '#00FFFF',
          'radius': 1,
          'lineWidth': 1,
        });
      }
      expect(app.view.markerProfile!.length, 2);
      await app.dispatch('markerRender');
      expect(app.view.error, isEmpty);
      final variants = img.decodePng(app.view.worldPreview!)!;
      final variantColors = {
        for (final p in variants)
          (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt(),
      };
      expect(variantColors, containsAll([0xff00ff, 0x00ffff]));
      await app.dispatch('export', {'kind': 'world'});
      expect(files.output, original);
      await app.close();
      app.dispose();
    },
    skip: Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Requires native engine'
        : false,
  );
}
