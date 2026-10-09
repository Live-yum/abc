import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/world_properties_panel.dart';

void main() {
  final edits = <MapEntry<String, Object>>[];
  Future<void> mount(
    WidgetTester tester,
    Map<String, Object?> world, {
    bool busy = false,
  }) async {
    edits.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldPropertiesPanel(
              world: world,
              busy: busy,
              onEdit: (field, value) async {
                edits.add(MapEntry(field, value));
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> search(WidgetTester tester, String field) async {
    await tester.enterText(
      find.byKey(const ValueKey('world-property-search')),
      field,
    );
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String field, String value) async {
    await search(tester, field);
    await tester.tap(find.byKey(ValueKey('world-property-$field')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('world-property-input')),
      value,
    );
    await tester.tap(find.text('暂存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'actual header bool callback, search, no nested or synthetic values',
    (tester) async {
      await mount(tester, {
        'version': 139,
        'outside': 'hidden',
        'header': {
          'dayTime': false,
          'downedEyeOfCthulhu': false,
          'newUnknownBool': false,
          'nested': {'name': 'hidden'},
          'nullField': null,
        },
      });
      await search(tester, 'downedEye');
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(edits.single.key, 'downedEyeOfCthulhu');
      expect(edits.single.value, true);
      await search(tester, 'outside');
      expect(find.text('没有匹配的实际字段'), findsOneWidget);
      await search(tester, 'nested');
      expect(find.text('没有匹配的实际字段'), findsOneWidget);
    },
  );

  testWidgets('integers and doubles retain actual types and zero', (
    tester,
  ) async {
    await mount(tester, {'version': 139, 'moonPhase': 2, 'maxRain': 0.5});
    await enter(tester, 'moonPhase', '0');
    expect(edits.last.value, isA<int>());
    expect(edits.last.value, 0);
    await enter(tester, 'maxRain', '0.25');
    expect(edits.last.value, isA<double>());
    expect(edits.last.value, 0.25);
  });

  testWidgets('reject invalid spawn, fractional integer and nonfinite number', (
    tester,
  ) async {
    await mount(tester, {
      'version': 139,
      'maxTilesX': 100,
      'spawnTileX': 0,
      'maxRain': 0.0,
    });
    await enter(tester, 'spawnTileX', '-1');
    expect(find.textContaining('数值范围'), findsOneWidget);
    expect(edits, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('world-property-input')),
      '100',
    );
    await tester.tap(find.text('暂存'));
    await tester.pumpAndSettle();
    expect(edits, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('world-property-input')),
      '1.5',
    );
    await tester.tap(find.text('暂存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('整数不能包含小数'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await enter(tester, 'maxRain', 'NaN');
    expect(find.textContaining('有限数值'), findsOneWidget);
    expect(edits, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('cancel leaves name unchanged; strings are not coerced', (
    tester,
  ) async {
    await mount(tester, {'version': 179, 'name': 'Original', 'seed': '0000'});
    await search(tester, 'name');
    await tester.tap(find.byKey(const ValueKey('world-property-name')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('world-property-input')),
      'New',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(edits, isEmpty);
    await enter(tester, 'seed', '0001');
    expect(edits.single.value, '0001');
  });

  testWidgets(
    'structural, unknown, future progression and locked worlds read-only',
    (tester) async {
      final world = <String, Object?>{
        'version': 139,
        'worldId': 9223372036854775807,
        'maxTilesX': 100,
        'mystery': 3,
        'downedUnknownFutureBoss': false,
        'dayTime': true,
      };
      await mount(tester, world);
      for (final field in ['worldId', 'maxTilesX', 'mystery']) {
        await search(tester, field);
        expect(
          tester
              .widget<ListTile>(find.byKey(ValueKey('world-property-$field')))
              .onTap,
          isNull,
        );
      }
      await search(tester, 'downedUnknown');
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      for (final lock in ['readOnly', 'futureVersion']) {
        await mount(tester, {...world, lock: true});
        await search(tester, 'dayTime');
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
          isNull,
        );
      }
      await mount(tester, world, busy: true);
      await search(tester, 'dayTime');
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      expect(edits, isEmpty);
    },
  );

  testWidgets(
    'normalized zero uses floating schema and version gates mode and seed',
    (tester) async {
      await mount(tester, {
        'version': 139,
        'time': 0,
        'maxRain': 0,
        'gameMode': 0,
        'seed': '0',
        'moondialCooldown': 0,
      });
      await enter(tester, 'time', '123.5');
      expect(edits.last.value, 123.5);
      expect(edits.last.value, isA<double>());
      await enter(tester, 'maxRain', '0.5');
      expect(edits.last.value, 0.5);
      for (final field in ['seed', 'moondialCooldown']) {
        await search(tester, field);
        expect(
          tester
              .widget<ListTile>(find.byKey(ValueKey('world-property-$field')))
              .onTap,
          isNull,
        );
      }
      final count = edits.length;
      await enter(tester, 'gameMode', '2');
      expect(edits.length, count);
      expect(find.textContaining('数值范围'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await mount(tester, {'version': 208, 'gameMode': 0});
      await enter(tester, 'gameMode', '2');
      expect(edits.single.value, 2);
      await mount(tester, {'version': 209, 'gameMode': 0});
      await enter(tester, 'gameMode', '3');
      expect(edits.single.value, 3);
    },
  );

  testWidgets('future versions lock editing without metadata flags', (
    tester,
  ) async {
    await mount(tester, {'version': 327, 'dayTime': true, 'name': 'Future'});
    await search(tester, 'dayTime');
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    await search(tester, 'name');
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('world-property-name')))
          .onTap,
      isNull,
    );
    expect(edits, isEmpty);
  });

  testWidgets('390px layout uses bounded lazy list', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, {
      'version': 139,
      'name': 'World',
      'dayTime': true,
      for (int i = 0; i < 300; i++) 'unknownField$i': i,
    });
    await tester.pumpAndSettle();
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
  });
}
