import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/computer_display.dart';
import 'package:terraforge/ui/terra_app.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

import '../integration_test/support/profile_controller.dart';
import '../integration_test/support/profile_recorder.dart';
import 'support/computer_circuit_backend.dart';
import 'workspace_test.dart' show FakeEngine, FakeFiles;

class _Sources implements WorldCircuitFileGateway {
  @override
  Future<WorldCircuitSource?> pick() async => const WorldCircuitSource.file(
    path: '/fixture/computer.wld',
    length: 405983441,
    name: 'computer.wld',
  );

  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async => true;
}

class _Backend extends ComputerCircuitBackend {
  int completedClocks = 0;

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    final result = await super.commandWorldCircuit(session, command);
    if (command.words[1] == 2 && command.words[2] == 3194) {
      completedClocks++;
    }
    if (command.words[1] == 9 && completedClocks.isOdd) {
      ByteData.sublistView(result.records).setInt16(12, 18, Endian.little);
    }
    return result;
  }
}

class _Workspace extends Workspace {
  _Workspace(_Backend backend)
    : super(
        engine: FakeEngine(),
        files: FakeFiles()
          ..next = PickedFile('loop.bin', Uint8List.fromList([0x6f, 0, 0, 0])),
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

Future<void> _completeBatch(WidgetTester tester, _Backend backend) async {
  final gate = backend.holdClock!;
  await tester.pump(const Duration(milliseconds: 1));
  // The production throttle intentionally uses Stopwatch, not the fake widget
  // clock. Advance wall time with the backend held; no timing is asserted.
  await tester.runAsync(() => Future<void>.delayed(
    const Duration(milliseconds: 20),
  ));
  backend.holdClock = Completer<void>();
  gate.complete();
  await tester.pump();
}

Future<void> _pause(
  WidgetTester tester,
  Workspace workspace,
  _Backend backend,
) async {
  final paused = workspace.dispatch('worldCircuitPause');
  if (!(backend.holdClock?.isCompleted ?? true)) backend.holdClock!.complete();
  backend.holdClock = null;
  await tester.pump();
  await paused;
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    testWidgets('runtime stays inside panel at ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = _Backend();
      final workspace = _Workspace(backend);
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitImport');
      await workspace.dispatch('worldCircuitLoadProgram');
      expect(workspace.worldCircuitView['canRunComputer'], isTrue);
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
          .colorScheme.primary;
      expect(find.byType(NavigationBar), size.width < 1000
          ? findsOneWidget : findsNothing);

      backend.holdClock = Completer<void>();
      await workspace.dispatch('worldCircuitToggle');
      await tester.pump();
      final runningScaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(runningScaffold, isNot(same(scaffold)));
      final monitorRect = tester.getRect(find.byType(ComputerDisplay));
      expect(monitorRect.width, greaterThan(0));
      expect(monitorRect.width, lessThanOrEqualTo(size.width));
      expect(monitorRect.width / monitorRect.height, closeTo(64 / 48, .001));
      var broadEvents = 0;
      workspace.addListener(() => broadEvents++);
      for (final pulses in [128, 256, 384]) {
        workspace.viewReads = 0;
        workspace.circuitReads = 0;
        await _completeBatch(tester, backend);
        expect(workspace.viewReads, 0);
        expect(workspace.circuitReads, greaterThan(0));
        expect(broadEvents, pulses ~/ 128);
        expect(tester.widget<Scaffold>(find.byType(Scaffold)),
            same(runningScaffold));
        expect(tester.state(find.byType(WorldCircuitPanel)), same(panelState));
        expect(tester.getRect(find.byType(ComputerDisplay)), monitorRect);
        expect(find.textContaining('已执行 $pulses 个物理时钟脉冲'), findsOneWidget);
        final expected = workspace.worldCircuitView['displayFrames'] as Map;
        expect(tester.widget<ComputerDisplay>(find.byType(ComputerDisplay)).rgba,
            same(expected['黑白显示器']));
      }
      expect(Theme.of(tester.element(find.byType(WorldCircuitPanel)))
          .colorScheme.primary, color);

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
      await _completeBatch(tester, backend);
      workspace.removeListener(ordinaryReentry);
      expect(reentered, isTrue);
      expect(workspace.viewReads, greaterThan(0));

      await _navigate(tester, '工作台');
      workspace.viewReads = 0;
      workspace.circuitReads = 0;
      await _completeBatch(tester, backend);
      expect(workspace.viewReads, 0);
      expect(workspace.circuitReads, 0,
          reason: 'No offscreen panel reads or full-shell snapshots');
      await _navigate(tester, '电路实验室');
      expect(find.textContaining('已执行 640 个物理时钟脉冲'), findsOneWidget);

      await _pause(tester, workspace, backend);
      workspace.viewReads = 0;
      await workspace.dispatch('worldCircuitInput', {'direction': 'invalid'});
      await tester.pump();
      expect(workspace.viewReads, greaterThan(0));
      expect(find.textContaining('未知的计算机方向键'), findsWidgets);
      await workspace.dispatch('dismissError');
      await tester.pump();
      expect(find.textContaining('未知的计算机方向键'), findsNothing);

      workspace.viewReads = 0;
      await workspace.dispatch('worldCircuitSave');
      await tester.pumpAndSettle();
      expect(workspace.viewReads, greaterThan(0));
      expect(workspace.worldCircuitView['dirty'], isFalse);
      expect(find.textContaining('已导出模拟世界 WLD 副本'), findsOneWidget);
      backend.holdClock = Completer<void>();
      await workspace.dispatch('worldCircuitToggle');
      await tester.pump();
      workspace.viewReads = 0;
      await _completeBatch(tester, backend);
      expect(workspace.viewReads, greaterThan(0),
          reason: 'First dirty transition also refreshes shell');
      expect(workspace.worldCircuitView['dirty'], isTrue);
      await _pause(tester, workspace, backend);

      final oldIdentity = workspace.worldCircuitView['displayIdentity'];
      await workspace.dispatch('worldCircuitClose', {'discard': true});
      await tester.pumpAndSettle();
      expect(find.byType(ComputerDisplay), findsNothing);
      expect(workspace.worldCircuitView['open'], isFalse);
      backend.holdOpen = Completer<void>();
      workspace.viewReads = 0;
      final importing = workspace.dispatch('worldCircuitImport');
      await tester.pump();
      expect(workspace.viewReads, greaterThan(0));
      expect(workspace.worldCircuitView['importing'], isTrue);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      backend.holdOpen!.complete();
      backend.holdOpen = null;
      await tester.pump();
      await importing;
      await tester.pumpAndSettle();
      expect(workspace.worldCircuitView['busy'], isFalse);
      expect(workspace.worldCircuitView['importing'], isFalse);
      expect(workspace.worldCircuitView['displayIdentity'], isNot(same(oldIdentity)));
      expect(find.byType(ComputerDisplay), findsOneWidget);

      await _navigate(tester, '工作台');
      expect(find.byType(WorldCircuitPanel), findsNothing);
      await _navigate(tester, '电路实验室');
      expect(find.byType(WorldCircuitPanel), findsOneWidget);
      final replacement = _Workspace(_Backend());
      await tester.pumpWidget(TerraForgeApp(controller: replacement));
      await tester.pumpAndSettle();
      replacement.viewReads = 0;
      workspace.notifyListeners();
      await tester.pump();
      expect(replacement.viewReads, 0, reason: 'Old controller detached');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      proxy?.dispose();
      await workspace.close();
      workspace.dispose();
      await replacement.close();
      replacement.dispose();
      expect(tester.takeException(), isNull);
    });
  }
}
