import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/resource_catalog.dart';
import 'package:terraforge/ui/chest_tools_panel.dart';

void main() {
  final chests = <Map<String, Object?>>[
    {
      'name': '空箱',
      'x': 80,
      'y': 20,
      'items': [null],
    },
    {
      'name': '工具箱',
      'x': 2,
      'y': 3,
      'unknown': 'preserve',
      'items': [
        {'itemType': 12, 'stack': 4, 'prefix': 7, 'unknown': 'preserve'},
        {'itemType': 0, 'stack': 0, 'prefix': 0},
      ],
    },
  ];
  final catalog = ResourceCatalog(
    gameVersion: '1',
    provenance: {},
    families: {
      'prefixes': [
        CatalogEntry('prefixes', {
          'id': 1,
          'stats': {'dmg': 1.1},
          'pools': <String>[],
        }),
        CatalogEntry('prefixes', {
          'id': 2,
          'stats': {'dmg': 1.2},
          'pools': <String>[],
        }),
      ],
      'items': [
        CatalogEntry('items', {
          'id': 12,
          'name': '铜工具',
          'maxStack': 99,
          'gameplay': {'damage': 20},
          'eligiblePrefixes': [1, 2],
        }),
      ],
    },
  );
  final calls = <Map<String, Object?>>[];
  Future<void> mount(
    WidgetTester tester, {
    bool verified = true,
    bool readOnly = false,
    bool busy = false,
  }) async {
    calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChestToolsPanel(
              chests: chests,
              busy: busy,
              readOnly: readOnly,
              catalog: catalog,
              verifiedRules: verified,
              worldVersion: 326,
              modifiedIndices: const {1},
              onAction: (action, args) async {
                calls.add({'action': action, ...args});
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('chest-1')));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('decoded null slot can be filled using verified metadata', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('chest-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chest-slot-0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('slot-id')), '12');
    await tester.enterText(find.byKey(const Key('slot-quantity')), '1');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(calls.single, {
      'action': 'stageChest',
      'index': 0,
      'slot': 0,
      'itemId': 12,
      'quantity': 1,
      'prefix': 0,
    });
    expect((chests[0]['items'] as List).single, isNull);
  });

  testWidgets(
    'slot best prefix is a local draft until saved and cancel discards it',
    (tester) async {
      await mount(tester);
      await open(tester);
      await tester.tap(find.byKey(const Key('chest-slot-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('slot-best-prefix')));
      await tester.pump();
      TextField field(String key) =>
          tester.widget<TextField>(find.byKey(Key(key)));
      expect(field('slot-prefix').controller!.text, '2');
      expect(field('slot-id').controller!.text, '12');
      expect(field('slot-quantity').controller!.text, '4');
      expect(calls, isEmpty);
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(calls, isEmpty);
      await tester.tap(find.byKey(const Key('chest-slot-0')));
      await tester.pumpAndSettle();
      expect(field('slot-prefix').controller!.text, '7');
      await tester.tap(find.byKey(const Key('slot-best-prefix')));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(calls.single, {
        'action': 'stageChest',
        'index': 1,
        'slot': 0,
        'itemId': 12,
        'quantity': 4,
        'prefix': 2,
      });
    },
  );
  testWidgets(
    'item search retains original index and rename emits narrow intent',
    (tester) async {
      await mount(tester);
      expect(find.text('宝箱 2 · 非空 1 · 空 1'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('chest-search')), '铜工具');
      await tester.pump();
      expect(find.byKey(const Key('chest-0')), findsNothing);
      await open(tester);
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('chest-name')), '新名称');
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(calls, [
        {'action': 'stageChest', 'index': 1, 'name': '新名称'},
      ]);
      expect(chests[1]['unknown'], 'preserve');
    },
  );
  testWidgets(
    'slot editor initializes actual values and validates without coercion',
    (tester) async {
      await mount(tester);
      await open(tester);
      await tester.tap(find.byKey(const Key('chest-slot-0')));
      await tester.pumpAndSettle();
      TextField field(String key) =>
          tester.widget<TextField>(find.byKey(Key(key)));
      expect(field('slot-id').controller!.text, '12');
      expect(field('slot-quantity').controller!.text, '4');
      expect(field('slot-prefix').controller!.text, '7');
      await tester.enterText(find.byKey(const Key('slot-quantity')), 'oops');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(calls, isEmpty);
      expect(find.textContaining('请输入有效整数'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('slot-quantity')), '5');
      await tester.enterText(find.byKey(const Key('slot-prefix')), '9');
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(calls.single, {
        'action': 'stageChest',
        'index': 1,
        'slot': 0,
        'itemId': 12,
        'quantity': 5,
        'prefix': 9,
      });
    },
  );
  testWidgets('cancel is inert and selected-slot clear is explicit', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    await tester.tap(find.byKey(const Key('chest-slot-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('slot-id')), '15');
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(calls, isEmpty);
    await tester.tap(find.byKey(const Key('chest-slot-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slot-clear')));
    await settle(tester);
    expect(calls.single, {
      'action': 'stageChest',
      'index': 1,
      'slot': 0,
      'itemId': 0,
      'quantity': 0,
      'prefix': 0,
    });
  });
  testWidgets(
    'clear requires confirmation and current/all reforges retain scope',
    (tester) async {
      await mount(tester);
      await open(tester);
      await tester.tap(find.text('清空宝箱'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('清空宝箱'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(calls.last, {
        'action': 'chestClear',
        'index': 1,
        'confirmed': true,
      });
      await tester.tap(find.text('当前最佳前缀'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前 1 个宝箱'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(calls.last, {
        'action': 'chestBestPrefixes',
        'index': 1,
        'confirmed': true,
      });
      await tester.tap(find.text('返回宝箱列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部最佳前缀'));
      await tester.pumpAndSettle();
      expect(find.textContaining('全部 2 个宝箱'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(calls.last, {'action': 'chestBestPrefixes', 'confirmed': true});
    },
  );
  testWidgets(
    'unverified rules and future-version read-only disable automatic edits',
    (tester) async {
      await mount(tester, verified: false);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '全部最佳前缀'),
            )
            .onPressed,
        isNull,
      );
      await open(tester);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '当前最佳前缀'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('chest-slot-0')));
      await tester.pumpAndSettle();
      expect(find.textContaining('资源目录仅用于名称参考'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('slot-catalog-search')))
            .enabled,
        false,
      );
      await tester.tap(find.text('取消'));
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
      await mount(tester, readOnly: true);
      await open(tester);
      for (final label in ['重命名', '整理宝箱', '清空宝箱', '当前最佳前缀']) {
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, label),
              )
              .onPressed,
          isNull,
        );
      }
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('chest-slot-0')))
            .onPressed,
        isNull,
      );
      expect(calls, isEmpty);
    },
  );
  testWidgets(
    'modified filter uses parent indices and layout fits 390 pixels',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      await tester.tap(find.byKey(const Key('chest-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已修改').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chest-0')), findsNothing);
      expect(find.byKey(const Key('chest-1')), findsOneWidget);
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('chest-slot-2')), findsNothing);
      await tester.tap(find.byKey(const Key('chest-slot-0')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await settle(tester);
    },
  );
}
