// Independent regression coverage for application safety.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/platform/files.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;

class ControlledEngine extends FakeEngine {
  Completer<void>? closing;
  bool strict = false;
  int overlap = 0;
  int? reject;
  @override
  Future<EngineDocument> open(Uint8List bytes, {required String kind}) async {
    if (bytes.first == reject) {
      throw const EngineException('Rejected on reopen');
    }
    if (strict && handles.isNotEmpty) {
      overlap++;
      throw const EngineException('Only one world');
    }
    return super.open(bytes, kind: kind);
  }

  @override
  Future<void> close(EngineDocument doc) async {
    await closing?.future;
    await super.close(doc);
  }
}

void main() {
  test(
    'pending save undo blocks export from colliding with live world',
    () async {
      final e = ControlledEngine()..strict = true;
      final f = FakeFiles()
        ..next = PickedFile('a.wld', Uint8List.fromList([1, 2]));
      final w = Workspace(engine: e, files: f);
      await w.dispatch('import');
      await w.dispatch('stageWorld', {'field': 'name', 'value': 'new'});
      e.closing = Completer<void>();
      final undo = w.dispatch('undo', {'canvas': 'world'});
      await Future<void>.delayed(Duration.zero);
      expect(w.view.busy, true);
      await w.dispatch('export', {'kind': 'world'});
      expect(e.overlap, 0);
      expect(w.view.error, isEmpty);
      e.closing!.complete();
      await undo;
      await w.close();
    },
  );
  test('failed file activation restores previous working document', () async {
    final e = ControlledEngine();
    final f = FakeFiles()..next = PickedFile('a.wld', Uint8List.fromList([1]));
    final w = Workspace(engine: e, files: f);
    await w.dispatch('import');
    final first = w.view.files.first.id;
    f.next = PickedFile('b.wld', Uint8List.fromList([2]));
    await w.dispatch('import');
    e.reject = 1;
    await w.dispatch('openFile', {'id': first});
    expect(w.view.world, isNotEmpty);
    expect(e.handles.length, 1);
    expect(w.view.error, contains('Rejected on reopen'));
  });
  test(
    'resize does not create per-pixel undo that erases copied work',
    () async {
      final w = Workspace(engine: FakeEngine(), files: FakeFiles());
      await w.dispatch('paint', {
        'canvas': 'pixel',
        'x': 0,
        'y': 0,
        'color': 0xffaabbcc,
      });
      await w.dispatch('resize', {'canvas': 'pixel', 'width': 2, 'height': 2});
      expect(w.view.canvases['pixel']!.colors.first, 0xffaabbcc);
      await w.dispatch('undo', {'canvas': 'pixel'});
      expect(w.view.canvases['pixel']!.colors.first, 0xffaabbcc);
    },
  );
  test(
    'circuit placement respects configured interval and initial state',
    () async {
      final w = Workspace(engine: FakeEngine(), files: FakeFiles());
      await w.dispatch('circuitPlace', {
        'x': 1,
        'y': 1,
        'element': 'timer',
        'interval': 120,
        'initialOn': true,
      });
      final cell = (w.view.result['circuitCells'] as List).single as Map;
      expect(cell['interval'], 120);
      expect(cell['on'], true);
    },
  );
}
