import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/world_rules.dart';
import 'package:terraforge/ui/world_rules_panel.dart';

void main() {
  final scheme = WorldRuleScheme(
    name: '测试',
    rules: [
      WorldTileRule(patch: {'type': 1}),
    ],
  );
  testWidgets('390px panel, explicit confirmation and cancellation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldRulesPanel(
              scheme: scheme,
              busy: false,
              hasWorld: true,
              readOnly: false,
              preview: {
                'fingerprint': scheme.fingerprint,
                'bytes': 123,
                'sourceName': 'test.wld',
                'stale': false,
              },
              onAction: (action, args) async {
                actions.add(action);
                if (action == 'worldRulesApply') {
                  expect(args['confirmed'], true);
                }
              },
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('应用预览'));
    await tester.tap(find.text('应用预览'));
    await tester.pumpAndSettle();
    expect(find.text('应用到整个世界？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
    await tester.tap(find.text('应用预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();
    expect(actions, ['worldRulesApply']);
  });
  testWidgets('stale preview and draft rename disable apply', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldRulesPanel(
              scheme: scheme,
              busy: false,
              hasWorld: true,
              readOnly: false,
              preview: {'fingerprint': scheme.fingerprint, 'stale': false},
              onAction: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('worldRuleName')),
      'Changed',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用预览'))
          .onPressed,
      isNull,
    );
    expect(find.text('预览已过期，请重新生成。'), findsOneWidget);
  });
  testWidgets(
    'empty draft cannot preview and rule builder rejects missing patch',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: WorldRulesPanel(
                scheme: WorldRuleScheme(name: 'Draft'),
                busy: false,
                hasWorld: true,
                readOnly: false,
                onAction: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '生成预览'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('添加规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存规则'));
      await tester.pump();
      expect(find.textContaining('替换属性不能为空'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('空方案可保存；添加规则后才能生成预览。'), findsOneWidget);
    },
  );
  testWidgets('rule ordering and deletion are included in saved scheme', (
    tester,
  ) async {
    final initial = WorldRuleScheme(
      name: 'Ordered',
      rules: [
        WorldTileRule(patch: {'type': 1}),
        WorldTileRule(patch: {'wall': 2}),
      ],
    );
    Map<String, Object?>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldRulesPanel(
              scheme: initial,
              busy: false,
              hasWorld: true,
              readOnly: false,
              onAction: (action, args) async {
                if (action == 'worldRulesSave') saved = args;
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('下移规则 1'));
    await tester.pump();
    await tester.ensureVisible(find.text('保存方案'));
    await tester.tap(find.text('保存方案'));
    await tester.pump();
    expect(WorldRuleScheme.fromJson(saved!['scheme']).rules.first.patch, {
      'wall': 2,
    });
    await tester.ensureVisible(find.byTooltip('删除规则 1'));
    await tester.tap(find.byTooltip('删除规则 1'));
    await tester.pump();
    await tester.ensureVisible(find.text('保存方案'));
    await tester.tap(find.text('保存方案'));
    await tester.pump();
    expect(WorldRuleScheme.fromJson(saved!['scheme']).rules.single.patch, {
      'type': 1,
    });
  });
  testWidgets('material layout is editable with typed fields at 390px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldRulesPanel(
              scheme: WorldRuleScheme(name: 'Material'),
              busy: false,
              hasWorld: true,
              readOnly: false,
              onAction: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加高级材质布局').first);
    await tester.pumpAndSettle();
    expect(find.text('高级材质布局'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('保存布局'));
    await tester.pumpAndSettle();
    expect(find.textContaining('编辑材质布局'), findsOneWidget);
    await tester.tap(find.text('保存规则'));
    await tester.pump();
    // A layout alone never implicitly broadens matching to the entire world.
    expect(find.textContaining('替换属性不能为空'), findsOneWidget);
  });
}
