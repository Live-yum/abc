import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/terraria_map.dart';
import 'package:terraforge/engine/map_backend.dart';
import 'package:terraforge/ui/terraria_map_panel.dart';

import '../tool/perf/map_fixture.dart';

void main() {
  testWidgets(
    'dirty MAP close/replacement requires explicit discard; cancel preserves session',
    (tester) async {
      final session = TerrariaMapSession.decode(syntheticMap());
      session.editRect(0, 0, 1, 1, light: 99);
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerrariaMapPanel(
              session: MapSessionInfo.fromJson({
                ...session.metadata,
                'token': 1,
                'revision': session.revision,
                'ownedBytes': session.ownedBytes,
                'canUndo': session.canUndo,
                'canRedo': session.canRedo,
              }),
              canGenerateWorldMap: true,
              onAction: (action, args) async {
                calls.add(action);
              },
            ),
          ),
        ),
      );
      for (final label in ['关闭 MAP', '打开 .MAP', '从世界生成全亮 MAP']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text('放弃当前 MAP 修改？'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        expect(session.cellAt(0, 0).light, 99);
      }
      await tester.tap(find.text('关闭 MAP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改并继续'));
      await tester.pumpAndSettle();
      expect(calls, ['closeMap']);
      await tester.pumpWidget(const SizedBox());
      session.close();
    },
  );
  testWidgets('narrow MAP panel scrolls without overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = TerrariaMapSession.decode(syntheticMap());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerrariaMapPanel(
            session: MapSessionInfo.fromJson({
              ...session.metadata,
              'token': 1,
              'revision': session.revision,
              'ownedBytes': session.ownedBytes,
              'canUndo': session.canUndo,
              'canRedo': session.canRedo,
            }),
            onAction: (action, args) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.close();
  });
}
