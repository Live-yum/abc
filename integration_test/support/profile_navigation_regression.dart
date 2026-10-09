import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/terra_app.dart';

import 'profile_navigation.dart';

class _NoFilesController extends TerraController {
  @override
  TerraViewState get view => const TerraViewState();
  @override
  Future<void> dispatch(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {}
}

/// Imported by a normal flutter_test wrapper to validate navigation finders.
/// These are UI correctness regressions, never profile performance evidence.
void runNavigationRegressionTests() {
  for (final size in [
    const Size(1280, 720),
    const Size(1280, 540),
    const Size(800, 600),
  ]) {
    testWidgets('profile navigation scrolls lazy sidebar at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      WidgetController.hitTestWarningShouldBeFatal = true;
      final controller = _NoFilesController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(TerraForgeApp(controller: controller));
      Future<void> settle() async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await settle();
      final navigation = ProfileNavigation(tester, settle);
      // Two full trips exercise both direction changes and lazy child eviction.
      for (var cycle = 0; cycle < 2; cycle++) {
        for (final title in [
          '世界档案',
          '存档中心',
          '像素工坊',
          '角色实验室',
          '电路实验室',
          '融合画布',
          '世界生成',
          '写入工作流',
          '图鉴与成就',
          '映射方案',
          '设置与资源',
          '工作台',
        ]) {
          await navigation.go(title);
        }
      }
      final viewport = navigation.viewport();
      expect(viewport['workspaceWidth'], size.width);
      expect(viewport['workspaceHeight'], size.height);
      if (size.width >= 1000) {
        await navigation.go('设置与资源');
        final list = navigation.navigationList();
        final scroller = tester.state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        );
        scroller.position.jumpTo(scroller.position.maxScrollExtent);
        await settle();
        if (size.height == 540) {
          expect(
            find.descendant(of: list, matching: find.text('工作台')),
            findsNothing,
            reason: 'Reproduce an evicted row, not only an offscreen row',
          );
        }
        final diagnostics = await navigation.diagnose();
        expect(diagnostics['usesDrawer'], isFalse);
        expect(diagnostics['navigationSemantics'], isA<List>());
        await navigation.go('工作台');
      }
      expect(find.byKey(const PageStorageKey('home')), findsOneWidget);
    });
  }
}
