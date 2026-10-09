import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/platform/files.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;
import 'support/fusion_placement_fixture.dart' show blankRegion;

void main() {
  test('continuous layer strokes preserve unrelated bits and undo as one operation', () async {
    final source = blankRegion();
    source.setCell(0, 0, {'wires': 2, 'wall': 3});
    source.setCell(1, 0, {'wires': 8, 'wall': 4});
    final original = source.records;
    final files = FakeFiles()
      ..next = PickedFile(
        'region.json',
        Uint8List.fromList(utf8.encode(source.encode())),
      );
    final app = Workspace(engine: FakeEngine(), files: files);
    await app.dispatch('import', {'kind': 'project'});
    expect(app.view.error, isEmpty);
    await app.dispatch('regionBrush', {
      'kind': 'wire',
      'mask': 5,
      'remove': false,
    });
    await app.dispatch('strokeStart', {'canvas': 'fusion'});
    for (var x = 0; x < 2; x++) {
      await app.dispatch('paint', {
        'canvas': 'fusion',
        'x': x,
        'y': 0,
        'tool': 'brush',
      });
    }
    await app.dispatch('strokeEnd', {'canvas': 'fusion'});
    expect(app.view.error, isEmpty);
    expect(app.view.region!.cellAt(0, 0)!['wires'], 7);
    expect(app.view.region!.cellAt(1, 0)!['wires'], 13);
    expect(app.view.region!.cellAt(1, 0)!['wall'], 4);
    await app.dispatch('undo', {'canvas': 'fusion'});
    expect(app.view.region!.records, original);
    await app.dispatch('regionBrush', {
      'kind': 'liquid',
      'liquidType': 4,
      'amount': 128,
    });
    await app.dispatch('paint', {
      'canvas': 'fusion',
      'x': 0,
      'y': 0,
      'tool': 'brush',
    });
    expect(app.view.error, isEmpty);
    expect(app.view.region!.cellAt(0, 0)!['liquidType'], 4);
    expect(app.view.region!.cellAt(0, 0)!['wires'], 2);
    await app.dispatch('undo', {'canvas': 'fusion'});
    expect(app.view.region!.records, original);
    await app.dispatch('regionBrush', {'kind': 'shape', 'shape': 7});
    expect(app.view.error, isNotEmpty);
    expect((app.view.result['regionBrush'] as Map)['kind'], 'liquid');
    await app.close();
    app.dispose();
  });
}
