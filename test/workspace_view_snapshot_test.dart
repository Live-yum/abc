import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/computer_display.dart';
import 'package:terraforge/ui/terra_app.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

class _CountingController extends TerraController {
  int viewReads = 0, ticks = 0;
  String error = '';
  Map<String, Object?> world = {};
  List<TerraFile> files = [];
  List<Map<String, Object?>> mapping = [];
  Uint8List frame = Uint8List(4 * 3 * 4)..[47] = 255;
  final Object displayIdentity = Object();
  final actions = <String>[];
  Completer<void>? extraction;

  @override
  TerraViewState get view {
    viewReads++;
    return TerraViewState(
      status: 'snapshot $ticks',
      error: error,
      world: world,
      files: files,
      mapping: mapping,
      result: {
        'worldCircuit': {
          'open': true,
          'optimizationSupported': true,
          'width': 600,
          'height': 400,
          'ticks': ticks,
          'viewport': {'x': 40, 'y': 50, 'width': 4, 'height': 3},
          'displayRegion': {
            'name': 'selected pixels',
            'x': 40,
            'y': 50,
            'width': 4,
            'height': 3,
          },
          'displayFrame': frame,
          'displayPixelCount': 1,
          'displayIdentity': displayIdentity,
        },
      },
    );
  }

  void publish() => notifyListeners();

  @override
  Future<void> dispatch(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    actions.add(action);
    if (action == 'worldCircuitExtract') await extraction?.future;
  }
}

Future<void> _show(WidgetTester tester, _CountingController controller) async {
  tester.view.physicalSize = const Size(1440, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(TerraForgeApp(controller: controller));
  await tester.pumpAndSettle();
}

Future<void> _showCircuit(WidgetTester tester) async {
  await tester.tap(find.text('电路实验室').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('世界电路'));
  await tester.pumpAndSettle();
}

Future<void> _finish(
  WidgetTester tester,
  _CountingController controller,
) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  controller.dispose();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'one snapshot per rebuild updates selected pixels and tick counters',
    (tester) async {
      final controller = _CountingController();
      await _show(tester, controller);
      controller.viewReads = 0;
      controller.publish();
      await tester.pump();
      expect(
        controller.viewReads,
        1,
        reason: 'Deferred home and heading layouts share the root snapshot',
      );
      await _showCircuit(tester);

      for (final ticks in [6, 12, 18]) {
        final frame = Uint8List(4 * 3 * 4)
          ..[44] = ticks ~/ 6
          ..[47] = 255;
        controller
          ..ticks = ticks
          ..frame = frame
          ..viewReads = 0
          ..publish();
        await tester.pump();
        expect(controller.viewReads, 1);
        expect(
          tester.widget<ComputerDisplay>(find.byType(ComputerDisplay)).rgba,
          same(frame),
        );
        expect(find.textContaining(' · $ticks ticks · '), findsOneWidget);
        expect(find.text('snapshot $ticks'), findsOneWidget);
      }
      await _finish(tester, controller);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets('an existing button reads live state before the next rebuild', (
    tester,
  ) async {
    final controller = _CountingController();
    await _show(tester, controller);
    expect(find.text('打开世界'), findsOneWidget);

    // A callback can run before a controller update is rendered. It must use
    // current state even though the button still has the previous build's label.
    controller.world = {'name': 'newly opened world'};
    await tester.tap(find.text('打开世界'));
    await tester.pumpAndSettle();
    expect(controller.actions, isNot(contains('import')));
    expect(find.text('地图与基本信息'), findsOneWidget);
    await _finish(tester, controller);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('extraction checks live error state after its await', (
    tester,
  ) async {
    final controller = _CountingController();
    await _show(tester, controller);
    await _showCircuit(tester);
    final panel = tester.widget<WorldCircuitPanel>(
      find.byType(WorldCircuitPanel),
    );
    controller.extraction = Completer<void>();
    final extracting = panel.dispatch('worldCircuitExtract', const {'id': 1});
    controller.error = 'extraction failed after the displayed snapshot';
    controller.extraction!.complete();
    await extracting;
    await tester.pump();
    expect(find.byType(WorldCircuitPanel), findsOneWidget);

    controller.extraction = Completer<void>();
    final retrying = panel.dispatch('worldCircuitExtract', const {'id': 1});
    controller.error = '';
    controller.extraction!.complete();
    await retrying;
    await tester.pumpAndSettle();
    expect(find.byType(WorldCircuitPanel), findsNothing);
    expect(find.text('LIVE FUSION CANVAS'), findsOneWidget);
    await _finish(tester, controller);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('search dialog rebuilds read current files', (tester) async {
    final controller = _CountingController();
    await _show(tester, controller);
    await tester.tap(find.text('搜索功能、存档、物品'));
    await tester.pumpAndSettle();
    controller.files = const [
      TerraFile(id: 'new-file', name: 'newly-arrived.wld', kind: 'wld'),
    ];
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'newly-arrived',
    );
    await tester.pump();
    expect(find.text('newly-arrived.wld'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await _finish(tester, controller);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('lazy mapping rows share their list snapshot and refresh', (
    tester,
  ) async {
    final controller = _CountingController()
      ..mapping = [
        {'source': 'old-color', 'target': 'old-block'},
      ];
    await _show(tester, controller);
    await tester.tap(find.text('映射方案').first);
    await tester.pumpAndSettle();
    expect(find.text('old-color → old-block'), findsOneWidget);
    controller
      ..mapping = [
        {'source': 'new-color', 'target': 'new-block'},
      ]
      ..viewReads = 0
      ..publish();
    await tester.pump();
    expect(controller.viewReads, 1);
    expect(find.text('old-color → old-block'), findsNothing);
    expect(find.text('new-color → new-block'), findsOneWidget);
    await _finish(tester, controller);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
