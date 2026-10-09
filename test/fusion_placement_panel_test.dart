import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/region_document.dart';
import 'package:terraforge/domain/resource_catalog.dart';
import 'package:terraforge/ui/fusion_placement_panel.dart';

import 'support/fusion_placement_fixture.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    AdvancedRegionDocument? document,
    ResourceCatalog? catalog,
    int version = 326,
    Future<void> Function(String, Map<String, Object?>)? action,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FusionPlacementPanel(
              catalog: catalog ?? placementCatalog(),
              document: document ?? blankRegion(),
              worldVersion: version,
              x: 1,
              y: 1,
              onAction: action ?? (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'select exact variant, preview footprint and emit narrow stage intent',
    (tester) async {
      final events = <(String, Map<String, Object?>)>[];
      await show(tester, action: (a, b) async => events.add((a, b)));
      await tester.tap(find.byKey(const ValueKey('fusion-item-34')));
      await tester.pumpAndSettle();
      final variant = find.byKey(const ValueKey('fusion-placement-variant'));
      await tester.ensureVisible(variant);
      await tester.tap(variant);
      await tester.pumpAndSettle();
      await tester.tap(find.text('变体 1 · 随机样式 0 · 2 × 3').last);
      await tester.pumpAndSettle();
      final stage = find.byKey(const ValueKey('fusion-placement-stage'));
      await tester.ensureVisible(stage);
      await tester.tap(stage);
      await tester.pumpAndSettle();
      expect(events.single.$1, 'fusionPlace');
      expect(events.single.$2, {
        'itemId': 34,
        'variantIndex': 1,
        'display': false,
        'x': 1,
        'y': 1,
      });
      expect(
        find.byKey(const ValueKey('fusion-placement-footprint')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'container name, sign text and sensor state emit only owned options',
    (tester) async {
      final events = <Map<String, Object?>>[];
      for (final testCase in [
        (6021, 'fusion-placement-name', '箱😀', 'name'),
        (6055, 'fusion-placement-text', 'First\n第二行', 'text'),
        (6423, 'fusion-placement-logic-on', '', 'logicOn'),
      ]) {
        await show(
          tester,
          catalog: metadataPlacementCatalog(),
          action: (_, args) async => events.add(args),
        );
        await tester.enterText(
          find.byKey(const ValueKey('fusion-placement-search')),
          '${testCase.$1}',
        );
        await tester.pumpAndSettle();
        final item = find.byKey(ValueKey('fusion-item-${testCase.$1}'));
        await tester.ensureVisible(item);
        await tester.tap(item);
        await tester.pumpAndSettle();
        final field = find.byKey(ValueKey(testCase.$2));
        await tester.ensureVisible(field);
        if (testCase.$4 == 'logicOn') {
          await tester.tap(field);
        } else {
          await tester.enterText(field, testCase.$3);
        }
        await tester.pumpAndSettle();
        final stage = find.byKey(const ValueKey('fusion-placement-stage'));
        await tester.ensureVisible(stage);
        await tester.tap(stage);
        await tester.pumpAndSettle();
        expect(
          events.last[testCase.$4],
          testCase.$4 == 'logicOn' ? true : testCase.$3,
        );
        expect(events.last.keys.toSet(), {
          'itemId',
          'variantIndex',
          'display',
          'x',
          'y',
          testCase.$4,
        });
        expect(tester.takeException(), isNull);
      }
      expect(events.length, 3);
    },
  );

  testWidgets(
    'invalid container name disables placement and switching clears options',
    (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('fusion-item-48')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('fusion-placement-name'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '😀' * 11);
      await tester.pumpAndSettle();
      expect(find.textContaining('最多 20'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('fusion-placement-stage')),
            )
            .onPressed,
        isNull,
      );
      final display = find.byKey(const ValueKey('fusion-mode-display'));
      await tester.ensureVisible(display);
      await tester.tap(display);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fusion-placement-name')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('fusion-placement-stage')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('display mode searches inventory and respects WLD 326 guard', (
    tester,
  ) async {
    await show(tester, version: 325);
    await tester.tap(find.byKey(const ValueKey('fusion-mode-display')));
    await tester.enterText(
      find.byKey(const ValueKey('fusion-placement-search')),
      'sword',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fusion-item-1000')));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅支持 WLD 326'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('fusion-placement-stage')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('occupied target disables stage with visible reason', (
    tester,
  ) async {
    final document = blankRegion()..setCell(2, 2, {'active': 1, 'block': 1});
    await show(tester, document: document);
    await tester.tap(find.byKey(const ValueKey('fusion-item-34')));
    await tester.pumpAndSettle();
    expect(find.textContaining('目标已有物块'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('fusion-placement-stage')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'repeat taps while stage is pending emit once and recover on failure',
    (tester) async {
      final pending = Completer<void>();
      var count = 0;
      await show(
        tester,
        action: (_, _) {
          count++;
          return pending.future;
        },
      );
      await tester.tap(find.byKey(const ValueKey('fusion-item-34')));
      await tester.pumpAndSettle();
      final stage = find.byKey(const ValueKey('fusion-placement-stage'));
      await tester.ensureVisible(stage);
      await tester.tap(stage);
      await tester.pump();
      await tester.tap(stage);
      expect(count, 1);
      pending.completeError(StateError('retry safely'));
      await tester.pumpAndSettle();
      expect(find.textContaining('retry safely'), findsOneWidget);
      expect(tester.widget<FilledButton>(stage).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
}
