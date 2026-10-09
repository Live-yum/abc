import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/terraria_map.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/ui/terra_app.dart';

import '../tool/perf/map_fixture.dart';
import 'cloud_app_routes_test.dart' show navigate;
import 'workspace_test.dart' show FakeEngine, FakeFiles;

void main() {
  for (final width in [1440.0, 390.0]) {
    testWidgets('actual MAP tab is reachable without WLD at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final files = FakeFiles()
        ..next = PickedFile('synthetic.map', syntheticMap());
      final workspace = Workspace(engine: FakeEngine(), files: files);
      addTearDown(workspace.dispose);
      await tester.pumpWidget(TerraForgeApp(controller: workspace));
      await tester.pumpAndSettle();
      await navigate(tester, '世界档案', width);
      await tester.ensureVisible(find.text('MAP 探索存档'));
      await tester.tap(find.text('MAP 探索存档'));
      await tester.pumpAndSettle();
      expect(find.text('探索存档 · .MAP'), findsOneWidget);
      expect(find.textContaining('探索亮度的灰度图'), findsOneWidget);
      expect(find.text('从世界生成全亮 MAP'), findsNothing);
      await tester.ensureVisible(find.text('打开 .MAP'));
      await tester.runAsync(() async {
        await tester.tap(find.text('打开 .MAP'));
        final stop = DateTime.now().add(const Duration(seconds: 5));
        while (workspace.view.busy && DateTime.now().isBefore(stop)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(workspace.view.error, isEmpty);
      expect(workspace.view.map, isNotNull);
      expect(
        find.textContaining('Repository MAP fixture · 130 × 70'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('导出 .MAP'));
      await tester.runAsync(() async {
        await tester.tap(find.text('导出 .MAP'));
        final stop = DateTime.now().add(const Duration(seconds: 5));
        while (workspace.view.busy && DateTime.now().isBefore(stop)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(workspace.view.error, isEmpty);
      expect(files.saved, 'synthetic_terraforge.map');
      final reopened = TerrariaMapSession.decode(files.bytes!);
      expect(reopened.width, 130);
      reopened.close();
      await tester.ensureVisible(find.text('关闭 MAP'));
      await tester.tap(find.text('关闭 MAP'));
      await tester.pumpAndSettle();
      expect(workspace.view.map, isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
