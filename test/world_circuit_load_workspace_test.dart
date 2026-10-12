import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/world_circuit_files.dart';

import 'support/generic_world_circuit_backend.dart';
import 'workspace_test.dart' show FakeEngine, FakeFiles;

const _loading = WorldCircuitProgress(
  stage: 'compile',
  phase: 2,
  completed: 16,
  total: 40,
  diagnostics: {
    'nativeActiveBytes': 2 * 1048576,
    'nativePeakBytes': 3 * 1048576,
    'wasmHeapBytes': 16 * 1048576,
  },
);

class _Sources implements WorldCircuitFileGateway {
  WorldCircuitSource? next = const WorldCircuitSource.file(
    path: '/fixture/ordinary.wld',
    length: 1365,
    name: 'ordinary.wld',
  );

  @override
  Future<WorldCircuitSource?> pick() async => next;

  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async => throw UnsupportedError('No export in these tests');
}

class _LoadBackend extends GenericWorldCircuitBackend
    implements WorldCircuitIdleCleanupBackend {
  WorldCircuitProgress? nextProgress = _loading;
  bool failOpen = true;
  int polls = 0, cleanups = 0;

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    final result = await super.openWorldCircuitSource(
      world,
      onProgress: onProgress,
    );
    if (failOpen) throw StateError('import owner failed');
    return result;
  }

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() async {
    polls++;
    return nextProgress;
  }

  @override
  Future<void> cleanupWorldCircuit() async {
    cleanups++;
    nextProgress = const WorldCircuitProgress(
      stage: 'closed',
      phase: 0,
      completed: 0,
      total: 0,
      diagnostics: {'nativeActiveBytes': 0},
    );
  }
}

Map<String, Object?> _state(Workspace workspace) =>
    workspace.view.result['worldCircuit'] as Map<String, Object?>;

Future<Workspace> _selected(_LoadBackend backend, _Sources sources) async {
  final workspace = Workspace(
    engine: FakeEngine(),
    files: FakeFiles(),
    worldCircuitBackend: backend,
    worldCircuitFiles: sources,
  );
  await workspace.dispatch('worldCircuitChooseWorld');
  return workspace;
}

Future<void> _failImport(
  WidgetTester tester,
  Workspace workspace,
  _LoadBackend backend,
) async {
  backend.holdOpen = Completer<void>();
  final importing = workspace.dispatch('worldCircuitImport');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  backend.holdOpen!.complete();
  await tester.pump();
  await importing;
}

void main() {
  testWidgets('failed owner cleanup retains the last valid loading report', (
    tester,
  ) async {
    final backend = _LoadBackend();
    final workspace = await _selected(backend, _Sources());
    backend.holdOpen = Completer<void>();
    final importing = workspace.dispatch('worldCircuitImport');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_state(workspace)['loadProgress'], same(_loading));
    expect(backend.polls, 1, reason: 'Use the existing 250 ms progress poll');

    for (final report in [
      const WorldCircuitProgress(
        stage: 'compile',
        phase: 2,
        completed: -1,
        total: 40,
      ),
      const WorldCircuitProgress(
        stage: 'error',
        phase: 0,
        completed: 0,
        total: 0,
        diagnostics: {'nativeActiveBytes': 0},
      ),
    ]) {
      backend.nextProgress = report;
      await tester.pump(const Duration(milliseconds: 250));
      expect(_state(workspace)['loadProgress'], same(_loading));
    }
    backend.holdOpen!.complete();
    await tester.pump();
    await importing;
    final state = _state(workspace);
    expect(state['open'], isFalse);
    expect(state['progress'], isNull, reason: 'The failed session was cleared');
    expect(state['loadProgress'], same(_loading));
    expect(state['loadError'], contains('import owner failed'));
    expect(state['error'], contains('import owner failed'));
    expect(state['importing'], isFalse);
    expect(state['busy'], isFalse);
    expect(backend.cleanups, 1);
    final pollsAfterClose = backend.polls;
    await tester.pump(const Duration(seconds: 1));
    expect(
      backend.polls,
      pollsAfterClose,
      reason: 'No diagnostic polling after close',
    );
    await workspace.close();
    workspace.dispose();
  });

  testWidgets(
    'retry clears old report before polling and can open successfully',
    (tester) async {
      final backend = _LoadBackend();
      final workspace = await _selected(backend, _Sources());
      await _failImport(tester, workspace, backend);
      expect(_state(workspace)['loadError'], isNotNull);
      backend
        ..holdOpen = Completer<void>()
        ..nextProgress = null
        ..failOpen = false;
      final importing = workspace.dispatch('worldCircuitImport');
      await tester.pump();
      expect(_state(workspace)['loadProgress'], isNull);
      expect(_state(workspace)['loadError'], isNull);
      expect(_state(workspace)['error'], isNull);
      expect(_state(workspace)['importing'], isTrue);
      const fresh = WorldCircuitProgress(
        stage: 'hash',
        phase: 0,
        completed: 1,
        total: 20,
      );
      backend.nextProgress = fresh;
      await tester.pump(const Duration(milliseconds: 250));
      expect(_state(workspace)['loadProgress'], same(fresh));
      backend.holdOpen!.complete();
      await tester.pump();
      await importing;
      expect(_state(workspace)['open'], isTrue);
      expect(_state(workspace)['loadError'], isNull);
      expect(workspace.view.error, isEmpty);
      await workspace.close();
      workspace.dispose();
    },
  );

  for (final cancelPicker in [false, true]) {
    testWidgets('new source selection clears failure: cancel=$cancelPicker', (
      tester,
    ) async {
      final backend = _LoadBackend(), sources = _Sources();
      final workspace = await _selected(backend, sources);
      await _failImport(tester, workspace, backend);
      expect(_state(workspace)['loadProgress'], same(_loading));
      if (cancelPicker) sources.next = null;
      await workspace.dispatch('worldCircuitChooseWorld');
      expect(_state(workspace)['loadProgress'], isNull);
      expect(_state(workspace)['loadError'], isNull);
      expect(_state(workspace)['error'], isNull);
      await workspace.close();
      workspace.dispose();
    });
  }

  testWidgets('cancelled import is not retained as a loading failure', (
    tester,
  ) async {
    final backend = _LoadBackend();
    final workspace = await _selected(backend, _Sources());
    backend.holdOpen = Completer<void>();
    final importing = workspace.dispatch('worldCircuitImport');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_state(workspace)['loadProgress'], same(_loading));
    await workspace.dispatch('worldCircuitCancel');
    expect(_state(workspace)['loadError'], isNull);
    backend.holdOpen!.complete();
    await tester.pump();
    await importing;
    expect(_state(workspace)['open'], isFalse);
    expect(_state(workspace)['loadProgress'], isNull);
    expect(_state(workspace)['loadError'], isNull);
    expect(_state(workspace)['error'], isNull);
    expect(workspace.view.error, isEmpty);
    expect(workspace.view.status, contains('已取消导入'));
    await workspace.close();
    workspace.dispose();
  });
}
