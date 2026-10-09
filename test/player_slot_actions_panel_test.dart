import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/resource_catalog.dart';
import 'package:terraforge/ui/player_tools_panel.dart';

import 'support/player_action_fixtures.dart';

Widget panel(
  Map<String, Object?> p,
  List<Map<String, Object?>> actions, {
  ResourceCatalog? catalog,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: PlayerToolsPanel(
        player: p,
        catalog: catalog,
        dispatch: (action, args) async =>
            actions.add({'action': action, ...args}),
      ),
    ),
  ),
);
Future<void> tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'copy, paste and best prefix stay in draft until one bounded slot edit',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final actions = <Map<String, Object?>>[];
      final p = <String, Object?>{
        'version': 326,
        'inventory': [
          {
            ...slot(10, count: 3, prefix: 1, favorite: true),
            'sourceExtra': {'value': 7},
          },
          {...slot(0), 'destinationExtra': 9},
        ],
      };
      await tester.pumpWidget(
        panel(p, actions, catalog: playerActionCatalog(eligible: [1, 2, 3])),
      );
      await tap(tester, '库存');
      await tap(tester, '快捷 1');
      await tap(tester, '复制');
      await tap(tester, '取消');
      expect(actions, isEmpty);
      await tap(tester, '快捷 2');
      await tap(tester, '粘贴');
      await tap(tester, '最佳前缀');
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
        '2',
      );
      await tap(tester, '取消');
      expect(actions, isEmpty);
      expect((p['inventory'] as List)[1]['itemType'], 0);
      await tap(tester, '快捷 2');
      await tap(tester, '粘贴');
      await tap(tester, '最佳前缀');
      await tap(tester, '暂存');
      expect(actions, hasLength(1));
      expect(actions.single.keys.toSet(), {'action', 'group', 'index', 'slot'});
      expect(actions.single['action'], 'playerSlotEdit');
      expect(actions.single['group'], 'inventory');
      expect(actions.single['index'], 1);
      final edited = actions.single['slot'] as Map;
      expect(edited['prefix'], 2);
      expect(edited['stack'], 3);
      expect(edited['favorited'], true);
      expect(edited['sourceExtra'], {'value': 7});
      expect(edited['destinationExtra'], 9);
      expect((p['inventory'] as List)[1]['itemType'], 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsupported paste fails in place without changing draft or dispatching',
    (tester) async {
      final actions = <Map<String, Object?>>[];
      final p = <String, Object?>{
        'version': 326,
        'inventory': [slot(10, prefix: 2), slot(0)],
      };
      await tester.pumpWidget(panel(p, actions));
      await tap(tester, '库存');
      await tap(tester, '快捷 1');
      await tap(tester, '复制');
      await tap(tester, '取消');
      await tap(tester, '快捷 2');
      await tap(tester, '粘贴');
      expect(find.textContaining('缺少此物品与前缀兼容的可靠资料'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '0',
      );
      expect(actions, isEmpty);
      await tap(tester, '取消');
      expect(actions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bulk scopes are explicit and cancel or back make no changes', (
    tester,
  ) async {
    final actions = <Map<String, Object?>>[];
    final p = <String, Object?>{
      'version': 326,
      'inventory': [slot(10)],
      'safe': [slot(10)],
      'armor': [slot(10)],
    };
    await tester.pumpWidget(panel(p, actions, catalog: playerActionCatalog()));
    await tap(tester, '库存');
    await tap(tester, '当前储物栏最佳前缀');
    expect(find.textContaining('将修改 1 件物品'), findsOneWidget);
    await tap(tester, '取消');
    expect(actions, isEmpty);
    await tap(tester, '全部储物栏最佳前缀');
    expect(find.textContaining('将修改 2 件物品'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
    await tap(tester, '全部储物栏最佳前缀');
    await tap(tester, '确认应用');
    expect(actions, [
      {
        'action': 'playerBestPrefixes',
        'groups': ['inventory', 'safe'],
        'confirmed': true,
      },
    ]);
    expect((p['inventory'] as List).single['prefix'], 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changing player while confirmation is open rejects the stale action',
    (tester) async {
      final actions = <Map<String, Object?>>[];
      final catalog = playerActionCatalog();
      final p = <String, Object?>{
        'version': 326,
        'inventory': [slot(10)],
      };
      await tester.pumpWidget(panel(p, actions, catalog: catalog));
      await tap(tester, '库存');
      await tap(tester, '当前储物栏最佳前缀');
      await tester.pumpWidget(panel({...p}, actions, catalog: catalog));
      await tester.pump();
      await tap(tester, '确认应用');
      expect(actions, isEmpty);
      expect(find.textContaining('角色或资源资料已改变'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy slot editing and missing prefix metadata are visibly gated',
    (tester) async {
      final actions = <Map<String, Object?>>[];
      await tester.pumpWidget(
        panel(
          {
            'version': 37,
            'inventory': [slot(10)],
          },
          actions,
          catalog: playerActionCatalog(),
        ),
      );
      await tap(tester, '库存');
      expect(find.textContaining('此版本使用旧物品格式'), findsOneWidget);
      final tile = find.ancestor(
        of: find.text('快捷 1'),
        matching: find.byType(OutlinedButton),
      );
      expect(tester.widget<OutlinedButton>(tile).onPressed, isNull);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '当前储物栏最佳前缀'),
            )
            .onPressed,
        isNull,
      );
      expect(actions, isEmpty);
    },
  );
}
