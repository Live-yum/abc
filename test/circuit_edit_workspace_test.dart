import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/circuit_backend.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;

class _Traversal implements CircuitBackend {
  Completer<List<int>>? pending;
  @override
  Future<List<int>> propagate(
    int width,
    int height,
    List<int> cells,
    int x,
    int y,
    int colour,
  ) async => pending?.future ?? [33, 34, 35];
}

void main() {
  test('controller cancellation reaches in-flight planner and clipboard edits undo', () async {
    final backend = _Traversal();
    final workspace = Workspace(
      engine: FakeEngine(),
      files: FakeFiles(),
      circuitBackend: backend,
    );
    for (var x = 1; x <= 3; x++) {
      await workspace.dispatch('paint', {
        'canvas': 'circuit',
        'x': x,
        'y': 1,
        'wireColor': 0,
      });
    }
    final before = List<int>.from(workspace.view.canvases['circuit']!.colors);
    backend.pending = Completer<List<int>>();
    final pending = workspace.dispatch('circuitNetworkPreview', {
      'x': 1,
      'y': 1,
      'mask': 1,
    });
    await Future<void>.delayed(Duration.zero);
    expect(workspace.view.busy, isTrue);
    await workspace.dispatch('circuitCancelEdit');
    backend.pending!.complete([33, 34, 35]);
    await pending;
    expect((workspace.view.result['circuitEditor'] as Map)['preview'], isNull);
    expect(workspace.view.canvases['circuit']!.colors, before);
    backend.pending = null;
    await workspace.dispatch('circuitNetworkPreview', {
      'x': 1,
      'y': 1,
      'mask': 1,
    });
    expect(workspace.view.error, isEmpty);
    expect(workspace.view.canvases['circuit']!.colors, isNot(before));
    await workspace.dispatch('circuitConfirmEdit');
    expect(workspace.view.canvases['circuit']!.colors[33], 0);
    await workspace.dispatch('undo', {'canvas': 'circuit'});
    expect(workspace.view.canvases['circuit']!.colors, before);
    await workspace.dispatch('circuitSelect', {
      'x': 1,
      'y': 1,
      'width': 3,
      'height': 1,
    });
    await workspace.dispatch('circuitCopy');
    await workspace.dispatch('circuitRotate');
    await workspace.dispatch('circuitPaste', {'x': 5, 'y': 2});
    expect(workspace.view.error, isEmpty);
    expect(workspace.view.canvases['circuit']!.colors[69], isNot(0));
    await workspace.dispatch('undo', {'canvas': 'circuit'});
    expect(workspace.view.canvases['circuit']!.colors, before);
    await workspace.close();
    workspace.dispose();
  });
}
