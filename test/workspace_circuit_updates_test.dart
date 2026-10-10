import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/computer_display.dart';
import 'package:terraforge/ui/terra_app.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

import '../integration_test/support/profile_controller.dart';
import '../integration_test/support/profile_recorder.dart';
import 'support/generic_circuit_backend.dart';
import 'workspace_test.dart' show FakeEngine, FakeFiles;

class _Sources implements WorldCircuitFileGateway {
  @override
  Future<WorldCircuitSource?> pick() async => const WorldCircuitSource.file(
    path: '/fixture/generic.wld',
    length: 2048,
    name: 'generic.wld',
  );

  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async => true;
}

class _WideBoundsBackend extends GenericCircuitBackend {
  @override
  List<int> get stats => super.stats
    ..[2] = 1200
    ..[3] = 1000
    ..[6] = 40
    ..[7] = 50
    ..[8] = 900
    ..[9] = 850
    ..[10] = 2
    ..[11] = 2;

  @override
  List<(int, int, int, int, int)> get cells => [
    (40, 850, 135, 1, 0),
    (900, 50, 144, 1, 0),
  ];
}

class _TallBoundsBackend extends GenericCircuitBackend {
  @override
  List<int> get stats => super.stats
    ..[3] = 140000
    ..[6] = 40
    ..[7] = 50
    ..[8] = 400
    ..[9] = 131200
    ..[10] = 2
    ..[11] = 2;

  @override
  List<(int, int, int, int, int)> get cells => [
    (40, 131200, 135, 1, 0),
    (400, 50, 144, 1, 0),
  ];
}

class _Workspace extends Workspace {
  _Workspace(GenericCircuitBackend backend)
    : super(
        engine: FakeEngine(),
        files: FakeFiles(),
        worldCircuitBackend: backend,
        worldCircuitFiles: _Sources(),
      );
  int viewReads = 0;
  int circuitReads = 0;

  @override
  TerraViewState get view {
    viewReads++;
    return super.view;
  }

  @override
  Map<String, Object?> get worldCircuitView {
    circuitReads++;
    return super.worldCircuitView;
  }
}

Future<void> _navigate(WidgetTester tester, String title) async {
  if (tester.view.physicalSize.width < 1000) {
    await tester.tap(find.byTooltip('全部功能'));
    await tester.pumpAndSettle();
    final target = find.descendant(
      of: find.byType(Drawer),
      matching: find.text(title),
    );
    await tester.ensureVisible(target);
    await tester.tap(target);
  } else {
    await tester.tap(find.text(title).first);
  }
  await tester.pumpAndSettle();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() complete,
  String label,
) async {
  for (var turn = 0; turn < 100 && !complete(); turn++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(complete(), isTrue, reason: '$label did not finish in 100 pump turns');
}

Future<void> _pumpOperation(
  WidgetTester tester,
  Future<void> operation,
  String label,
) async {
  var complete = false;
  Object? failure;
  StackTrace? failureStack;
  final tracked = operation.then<void>(
    (_) {
      complete = true;
    },
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      complete = true;
    },
  );
  await _pumpUntil(tester, () => complete, label);
  await tracked;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

Future<void> _completeBatch(
  WidgetTester tester,
  Workspace workspace,
  GenericCircuitBackend backend,
) async {
  final gate = backend.holdTicks!;
  await _pumpUntil(
    tester,
    () => identical(backend.activeTicks, gate),
    'tick batch accepts held gate',
  );
  final before = backend.completedTickBatches;
  var published = false;
  void observe() => published = true;
  workspace.addListener(observe);
  try {
    backend.holdTicks = Completer<void>();
    gate.complete();
    await _pumpUntil(
      tester,
      () => backend.completedTickBatches == before + 1 && published,
      'completed batch publishes',
    );
  } finally {
    workspace.removeListener(observe);
  }
}

Future<void> _pause(
  WidgetTester tester,
  Workspace workspace,
  GenericCircuitBackend backend,
) async {
  final paused = workspace.dispatch('worldCircuitPause');
  if (!(backend.holdTicks?.isCompleted ?? true)) backend.holdTicks!.complete();
  backend.holdTicks = null;
  await _pumpOperation(tester, paused, 'pause and refresh');
  await tester.pumpAndSettle();
}

void main() {
  test('wide wire bounds locate a real cell below an empty top-left crop', () async {
    final backend = _WideBoundsBackend();
    final workspace = _Workspace(backend);
    try {
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitImport');
      expect(workspace.view.error, isEmpty);
      final state = workspace.worldCircuitView;
      expect(state['viewport'],
          {'x': 40, 'y': 595, 'width': 256, 'height': 256});
      final records = state['records'] as Uint8List;
      expect(records, hasLength(16));
      final data = ByteData.sublistView(records);
      expect(data.getUint32(0, Endian.little), 40);
      expect(data.getUint32(4, Endian.little), 850);
      expect(backend.commands.first.words.sublist(2, 6), [40, 50, 1, 801]);
      expect(backend.commands.every((command) => command.words[1] == 1), isTrue,
          reason: 'Import locates wiring without operating any input');
      expect(state['dirty'], isFalse);
    } finally {
      await workspace.close();
      workspace.dispose();
    }
  });

  test('a long leftmost column is read in bounded single-column segments', () async {
    final backend = _TallBoundsBackend();
    final workspace = _Workspace(backend);
    try {
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitImport');
      expect(workspace.view.error, isEmpty);
      final probes = backend.commands.take(3).map(
          (command) => command.words.sublist(2, 6)).toList();
      expect(probes, [
        [40, 50, 1, 65536],
        [40, 65586, 1, 65536],
        [40, 131122, 1, 79],
      ]);
      expect(backend.commands, hasLength(4));
      expect(backend.commands.every((command) =>
          command.words[1] == 1 &&
          command.words[4] * command.words[5] <= 65536), isTrue);
      final state = workspace.worldCircuitView;
      expect(state['viewport'],
          {'x': 40, 'y': 130945, 'width': 256, 'height': 256});
      expect((state['records'] as Uint8List).length, 16);
      expect(state['dirty'], isFalse);
    } finally {
      await workspace.close();
      workspace.dispose();
    }
  });

  test('viewport notifications publish matching records and retain a failed ROI', () async {
    final backend = GenericCircuitBackend();
    final workspace = _Workspace(backend);
    final observed = <Map<String, Object?>>[];
    void observe() => observed.add(workspace.worldCircuitView);
    try {
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitImport');
      workspace.addListener(observe);
      await workspace.dispatch('worldCircuitViewport',
          {'x': 42, 'y': 50, 'width': 2, 'height': 3});
      expect(workspace.view.error, isEmpty);
      expect(observed, isNotEmpty);
      for (final state in observed) {
        final viewport = state['viewport'] as Map;
        final bytes = state['records'] as Uint8List;
        final data = ByteData.sublistView(bytes);
        for (var at = 0; at < bytes.length; at += 16) {
          final x = data.getUint32(at, Endian.little);
          final y = data.getUint32(at + 4, Endian.little);
          expect(x, inInclusiveRange(viewport['x'] as int,
              (viewport['x'] as int) + (viewport['width'] as int) - 1));
          expect(y, inInclusiveRange(viewport['y'] as int,
              (viewport['y'] as int) + (viewport['height'] as int) - 1));
        }
      }
      final before = workspace.worldCircuitView;
      expect(before['viewport'], {'x': 42, 'y': 50, 'width': 2, 'height': 3});
      backend.failNextViewport = true;
      await workspace.dispatch('worldCircuitViewport',
          {'x': 40, 'y': 50, 'width': 4, 'height': 3});
      final failed = workspace.worldCircuitView;
      expect(workspace.view.error, contains('viewport read rejected'));
      expect(failed['viewport'], before['viewport']);
      expect(failed['records'], same(before['records']));
    } finally {
      workspace.removeListener(observe);
      await workspace.close();
      workspace.dispose();
    }
  });

  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    testWidgets('runtime stays inside panel at ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = GenericCircuitBackend();
      final workspace = _Workspace(backend);
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitImport');
      expect(workspace.worldCircuitView['open'], isTrue);
      expect(workspace.worldCircuitView['viewport'],
          {'x': 40, 'y': 50, 'width': 4, 'height': 3});
      await workspace.dispatch('worldCircuitReadDisplay',
          {'x': 40, 'y': 50, 'width': 4, 'height': 3});
      // Establish a normal dirty state before measuring steady runtime frames.
      await workspace.dispatch('worldCircuitTrigger',
          {'x': 40, 'y': 50, 'mask': 1});
      expect(workspace.worldCircuitView['dirty'], isTrue);
      final proxy = size.width < 1000
          ? ProfiledTerraController(
              workspace,
              ProfileRecorder(frameBudgetUs: 1000000 / 60, profile: false),
              0,
              false,
            )
          : null;
      if (proxy != null) {
        expect(proxy.workspaceChanges, same(workspace.workspaceChanges));
        expect(proxy.worldCircuitChanges, same(workspace.worldCircuitChanges));
      }
      await tester.pumpWidget(TerraForgeApp(controller: proxy ?? workspace));
      await tester.pumpAndSettle();
      await _navigate(tester, '电路实验室');
      await tester.tap(find.text('世界电路'));
      await tester.pumpAndSettle();
      final panelState = tester.state(find.byType(WorldCircuitPanel));
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      final color = Theme.of(tester.element(find.byType(WorldCircuitPanel)))
          .colorScheme
          .primary;
      expect(
        find.byType(NavigationBar),
        size.width < 1000 ? findsOneWidget : findsNothing,
      );

      workspace.viewReads = 0;
      await workspace.dispatch('worldCircuitTrigger',
          {'x': 40, 'y': 50, 'mask': 1});
      await tester.pump();
      expect(workspace.viewReads, greaterThan(0),
          reason: 'An explicit input operation refreshes the workspace');

      backend.holdTicks = Completer<void>();
      await workspace.dispatch('worldCircuitToggle');
      await tester.pump();
      final runningScaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(runningScaffold, isNot(same(scaffold)));
      final monitorRect = tester.getRect(find.byType(ComputerDisplay));
      expect(monitorRect.width, greaterThan(0));
      expect(monitorRect.width, lessThanOrEqualTo(size.width));
      expect(monitorRect.width / monitorRect.height, closeTo(4 / 3, .001));
      var broadEvents = 0;
      workspace.addListener(() => broadEvents++);
      for (final ticks in [6, 12, 18]) {
        workspace.viewReads = 0;
        workspace.circuitReads = 0;
        await _completeBatch(tester, workspace, backend);
        expect(workspace.viewReads, 0);
        expect(workspace.circuitReads, greaterThan(0));
        expect(broadEvents, ticks ~/ 6);
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold)),
          same(runningScaffold),
        );
        expect(tester.state(find.byType(WorldCircuitPanel)), same(panelState));
        expect(tester.getRect(find.byType(ComputerDisplay)), monitorRect);
        expect(find.textContaining(' · $ticks ticks · '), findsOneWidget);
        final expected = workspace.worldCircuitView['displayFrame'];
        expect(
          tester.widget<ComputerDisplay>(find.byType(ComputerDisplay)).rgba,
          same(expected),
        );
      }
      expect(
        Theme.of(tester.element(find.byType(WorldCircuitPanel)))
            .colorScheme
            .primary,
        color,
      );

      // A broad consumer may synchronously publish an ordinary workspace
      // change while handling a runtime event. It must still reach the root.
      var reentered = false;
      void ordinaryReentry() {
        if (!reentered) {
          reentered = true;
          workspace.notifyListeners();
        }
      }

      workspace.addListener(ordinaryReentry);
      workspace.viewReads = 0;
      await _completeBatch(tester, workspace, backend);
      workspace.removeListener(ordinaryReentry);
      expect(reentered, isTrue);
      expect(workspace.viewReads, greaterThan(0));

      await _navigate(tester, '工作台');
      workspace.viewReads = 0;
      workspace.circuitReads = 0;
      await _completeBatch(tester, workspace, backend);
      expect(workspace.viewReads, 0);
      expect(
        workspace.circuitReads,
        0,
        reason: 'No offscreen panel reads or full-shell snapshots',
      );
      await _navigate(tester, '电路实验室');
      expect(find.textContaining(' · 30 ticks · '), findsOneWidget);

      workspace.viewReads = 0;
      await _pause(tester, workspace, backend);
      expect(workspace.viewReads, greaterThan(0));
      expect(workspace.worldCircuitView['running'], isFalse);
      workspace.viewReads = 0;
      await workspace.dispatch('worldCircuitViewport',
          {'x': -1, 'y': 0, 'width': 1, 'height': 1});
      await tester.pump();
      expect(workspace.viewReads, greaterThan(0));
      expect(find.textContaining('x 必须在'), findsWidgets);
      await workspace.dispatch('dismissError');
      await tester.pump();
      expect(find.textContaining('x 必须在'), findsNothing);

      workspace.viewReads = 0;
      await _pumpOperation(
        tester,
        workspace.dispatch('worldCircuitSave'),
        'save world',
      );
      await tester.pumpAndSettle();
      expect(workspace.viewReads, greaterThan(0));
      expect(workspace.worldCircuitView['dirty'], isFalse);
      expect(find.textContaining('已导出模拟世界 WLD 副本'), findsOneWidget);
      backend.holdTicks = Completer<void>();
      await workspace.dispatch('worldCircuitToggle');
      await tester.pump();
      workspace.viewReads = 0;
      await _completeBatch(tester, workspace, backend);
      expect(
        workspace.viewReads,
        greaterThan(0),
        reason: 'First dirty transition also refreshes shell',
      );
      expect(workspace.worldCircuitView['dirty'], isTrue);
      await _pause(tester, workspace, backend);

      final oldIdentity = workspace.worldCircuitView['displayIdentity'];
      workspace.viewReads = 0;
      await _pumpOperation(
        tester,
        workspace.dispatch('worldCircuitClose', {'discard': true}),
        'close world',
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComputerDisplay), findsNothing);
      expect(workspace.worldCircuitView['open'], isFalse);
      expect(workspace.viewReads, greaterThan(0));
      backend.holdOpen = Completer<void>();
      workspace.viewReads = 0;
      final importing = workspace.dispatch('worldCircuitImport');
      await tester.pump();
      expect(workspace.viewReads, greaterThan(0));
      expect(workspace.worldCircuitView['importing'], isTrue);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      backend.holdOpen!.complete();
      backend.holdOpen = null;
      await _pumpOperation(tester, importing, 'reimport world');
      await tester.pumpAndSettle();
      expect(workspace.worldCircuitView['busy'], isFalse);
      expect(workspace.worldCircuitView['importing'], isFalse);
      expect(
        workspace.worldCircuitView['displayIdentity'],
        isNot(same(oldIdentity)),
      );
      expect(find.byType(ComputerDisplay), findsNothing);
      await workspace.dispatch('worldCircuitReadDisplay',
          {'x': 40, 'y': 50, 'width': 4, 'height': 3});
      await tester.pumpAndSettle();
      expect(find.byType(ComputerDisplay), findsOneWidget);

      await _navigate(tester, '工作台');
      expect(find.byType(WorldCircuitPanel), findsNothing);
      await _navigate(tester, '电路实验室');
      expect(find.byType(WorldCircuitPanel), findsOneWidget);
      final replacement = _Workspace(GenericCircuitBackend());
      await tester.pumpWidget(TerraForgeApp(controller: replacement));
      await tester.pumpAndSettle();
      replacement.viewReads = 0;
      workspace.notifyListeners();
      await tester.pump();
      expect(replacement.viewReads, 0, reason: 'Old controller detached');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      proxy?.dispose();
      await _pumpOperation(tester, workspace.close(), 'workspace teardown');
      workspace.dispose();
      await _pumpOperation(tester, replacement.close(), 'replacement teardown');
      replacement.dispose();
      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}
