// Static responsive screenshots, not native-device or runtime performance QA.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/computer_display.dart';
import 'package:terraforge/ui/terra_app.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

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
  Future<bool> save(WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async => true;
}

Future<void> _operation(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? failure;
  StackTrace? failureStack;
  final tracked = operation.then<void>((_) { done = true; },
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        done = true;
      });
  for (var turn = 0; turn < 100 && !done; turn++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(done, isTrue, reason: 'Static fixture operation did not settle.');
  await tracked;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Widget tests otherwise substitute test fonts. Load the actual bundled
    // CJK face and SDK Material icon font; do not replace the product theme.
    final cjk = FontLoader(terraFontFamily)
      ..addFont(rootBundle.load('assets/fonts/TerraForgeCJK-Regular.otf'));
    await cjk.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    final name = size.width == 1440 ? 'desktop-1440x1000' : 'mobile-390x844';
    testWidgets('static full application $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final oldDisableShadows = debugDisableShadows;
      final workspace = Workspace(
        engine: FakeEngine(),
        files: FakeFiles()
          ..next = PickedFile('loop.bin', Uint8List.fromList([0x6f, 0, 0, 0])),
        worldCircuitBackend: ComputerCircuitBackend(),
        worldCircuitFiles: _Sources(),
      );
      const capture = ValueKey('full-application-visual');
      Map state() => workspace.view.result['worldCircuit'] as Map;
      try {
        debugDisableShadows = false;
        await _operation(tester, workspace.dispatch('worldCircuitChooseWorld'));
        await _operation(tester, workspace.dispatch('worldCircuitImport'));
        await _operation(tester, workspace.dispatch('worldCircuitLoadProgram'));
        expect(state()['canRunComputer'], isTrue);
        expect(state()['running'], isFalse);
        expect(state()['physicalPulses'], 0);
        expect(state()['clockHz'], 0);
        expect(state()['displayHz'], 0);

        await tester.pumpWidget(RepaintBoundary(
          key: capture,
          child: TerraForgeApp(controller: workspace),
        ));
        await tester.pumpAndSettle();
        if (size.width < 1000) {
          await tester.tap(find.byTooltip('全部功能'));
          await tester.pumpAndSettle();
          final target = find.descendant(of: find.byType(Drawer),
              matching: find.text('电路实验室'));
          await tester.ensureVisible(target);
          await tester.tap(target);
        } else {
          await tester.tap(find.text('电路实验室').first);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('世界电路'));
        await tester.pumpAndSettle();

        final monitor = find.byType(ComputerDisplay);
        expect(monitor, findsOneWidget);
        final rawImage = find.descendant(of: monitor,
            matching: find.byType(RawImage));
        for (var turn = 0; turn < 100 &&
            tester.widget<RawImage>(rawImage).image == null; turn++) {
          await tester.runAsync(() => Future<void>.delayed(
              const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(tester.widget<RawImage>(rawImage).image, isNotNull,
            reason: 'Capture requires the real monitor image decode.');
        // Both viewports show the same paused monitor region within the real
        // scrolling page, keeping the shared shell visible around it.
        await Scrollable.ensureVisible(tester.element(monitor), alignment: .3);
        await tester.pumpAndSettle();
        expect(tester.getRect(monitor).overlaps(Offset.zero & size), isTrue);
        expect(Theme.of(tester.element(find.byType(WorldCircuitPanel)))
            .textTheme.bodyMedium!.fontFamily, terraFontFamily);
        expect(find.byType(NavigationBar), size.width < 1000
            ? findsOneWidget : findsNothing);
        expect(state()['running'], isFalse);
        expect(state()['physicalPulses'], 0);
        expect(tester.takeException(), isNull);
        // --update-goldens creates observations only. The independent runner
        // compares decoded A/B pixels afterward; generation is not a pass.
        await expectLater(find.byKey(capture),
            matchesGoldenFile('goldens/computer-shell/$name.png'));
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await _operation(tester,
              workspace.dispatch('worldCircuitClose', {'discard': true}));
          workspace.dispose();
        } finally {
          debugDisableShadows = oldDisableShadows;
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}
