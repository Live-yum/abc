import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/player_tools_panel.dart';
import 'package:terraforge/ui/terra_theme.dart';

void main() {
  final player = <String, Object?>{
    'version': 279,
    'name': 'Synthetic',
    'difficulty': 0,
    'statLife': 100,
    'statLifeMax': 100,
    'statMana': 20,
    'extraAccessory': false,
    'inventory': List.generate(
      58,
      (_) => {'itemType': 0, 'stack': 0, 'prefix': 0, 'favorited': false},
    ),
    'armor': List.generate(20, (_) => {'itemType': 0, 'stack': 0, 'prefix': 0}),
    'buffs': List.generate(44, (_) => {'buffType': 0, 'buffTime': 0}),
    'creativeItemSacrifices': <Object?>[],
    'creativePowers': {
      'godmodeEnabled': false,
      'farPlacementEnabled': true,
      'spawnRateSlider': 0.5,
    },
  };
  testWidgets(
    'specialized tabs display schema controls and submit a power edit',
    (tester) async {
      final actions = <Map<String, Object?>>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: terraTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlayerToolsPanel(
                player: player,
                dispatch: (action, args) async {
                  actions.add({'action': action, ...args});
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('角色属性'), findsOneWidget);
      await tester.tap(find.text('库存'));
      await tester.pumpAndSettle();
      expect(find.text('快捷 1'), findsOneWidget);
      expect(find.text('钱币 1'), findsOneWidget);
      expect(find.text('弹药 1'), findsOneWidget);
      await tester.tap(find.text('旅行与研究'));
      await tester.pumpAndSettle();
      expect(find.text('旅行能力'), findsOneWidget);
      await tester.tap(find.widgetWithText(SwitchListTile, '上帝模式'));
      await tester.pumpAndSettle();
      expect(actions.single['action'], 'stagePlayer');
      expect(actions.single['field'], 'creativePowers');
      expect((actions.single['value'] as Map)['godmodeEnabled'], true);
      expect((actions.single['value'] as Map)['farPlacementEnabled'], true);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unsupported research is explicitly gated and advanced is opt-in',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: terraTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlayerToolsPanel(
                player: {'version': 100, 'name': 'Old'},
                dispatch: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('查看解码后的 JSON'), findsNothing);
      await tester.tap(find.text('旅行与研究'));
      await tester.pumpAndSettle();
      expect(find.text('此版本不支持研究。'), findsOneWidget);
      await tester.tap(find.text('高级'));
      await tester.pumpAndSettle();
      expect(find.text('查看解码后的 JSON'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
