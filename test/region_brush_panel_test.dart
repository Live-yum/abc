import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/region_brush.dart';
import 'package:terraforge/ui/region_brush_panel.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    RegionBrush? brush,
    bool busy = false,
    bool readOnly = false,
    Future<void> Function(String, Map<String, Object?>)? action,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: RegionBrushPanel(
                brush: brush,
                busy: busy,
                readOnly: readOnly,
                onAction: action ?? (_, _) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> apply(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('region-brush-apply'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('equivalent host rebuild retains uncommitted numeric edits', (
    tester,
  ) async {
    await show(tester, brush: RegionBrush.wall(17));
    final input = find.byKey(const ValueKey('region-brush-id'));
    await tester.enterText(input, '30');
    await show(tester, brush: RegionBrush.wall(17));
    expect(tester.widget<TextField>(input).controller!.text, '30');
    await show(tester, brush: RegionBrush.wall(18));
    expect(tester.widget<TextField>(input).controller!.text, '18');
  });

  testWidgets(
    '390px panel emits combined wire intent and preserves last color',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = <(String, Map<String, Object?>)>[];
      await show(
        tester,
        brush: RegionBrush.fromIntent({
          'kind': 'wire',
          'mask': 1,
          'remove': false,
        }),
        action: (action, intent) async => events.add((action, intent)),
      );
      await tester.tap(find.byKey(const ValueKey('region-brush-wire-1')));
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const ValueKey('region-brush-wire-1')),
            )
            .selected,
        true,
      );
      await tester.tap(find.byKey(const ValueKey('region-brush-wire-4')));
      await tester.tap(find.byKey(const ValueKey('region-brush-remove-true')));
      await apply(tester);
      expect(events.single.$1, 'regionBrush');
      expect(events.single.$2, {'kind': 'wire', 'mask': 5, 'remove': true});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('every tool fits 390px and emits only its documented config', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final intent in <Map<String, Object?>>[
      {'kind': 'block', 'id': 0},
      {'kind': 'wall', 'id': 65535},
      {'kind': 'paint', 'layer': 'wall', 'paint': 30},
      {'kind': 'liquid', 'liquidType': 4, 'amount': 255},
      {'kind': 'wire', 'mask': 15, 'remove': true},
      {'kind': 'shape', 'shape': 1},
      {'kind': 'actuator', 'remove': true},
      {'kind': 'erase', 'layer': 'all'},
    ]) {
      final events = <Map<String, Object?>>[];
      await show(
        tester,
        brush: RegionBrush.fromIntent(intent),
        action: (_, data) async => events.add(data),
      );
      await apply(tester);
      expect(events.single, intent);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'liquid kind and amount, zero clear, and invalid input are explicit',
    (tester) async {
      final events = <Map<String, Object?>>[];
      await show(
        tester,
        brush: RegionBrush.fromIntent({
          'kind': 'liquid',
          'liquidType': 1,
          'amount': 255,
        }),
        action: (_, intent) async => events.add(intent),
      );
      await tester.tap(find.byKey(const ValueKey('region-brush-liquid-4')));
      await tester.enterText(
        find.byKey(const ValueKey('region-brush-amount')),
        '0',
      );
      await apply(tester);
      expect(events.single, {'kind': 'liquid', 'liquidType': 4, 'amount': 0});
      await tester.enterText(
        find.byKey(const ValueKey('region-brush-amount')),
        '256',
      );
      await apply(tester);
      expect(events, hasLength(1));
      expect(find.byKey(const ValueKey('region-brush-error')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('region-brush-amount')),
        '100',
      );
      await apply(tester);
      expect(events.last['amount'], 100);
      expect(find.byKey(const ValueKey('region-brush-error')), findsNothing);
    },
  );

  testWidgets('erase-to-paint resets invalid layer, paint range rejects 31', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    await show(
      tester,
      brush: RegionBrush.fromIntent({'kind': 'erase', 'layer': 'all'}),
      action: (_, intent) async => events.add(intent),
    );
    await tester.tap(find.byKey(const ValueKey('region-brush-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('涂漆 / 去漆').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<RegionBrushLayer>>(
            find.byKey(const ValueKey('region-brush-layer')),
          )
          .value,
      RegionBrushLayer.block,
    );
    await tester.enterText(
      find.byKey(const ValueKey('region-brush-paint')),
      '31',
    );
    await apply(tester);
    expect(events, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('region-brush-paint')),
      '30',
    );
    await tester.tap(find.byKey(const ValueKey('region-brush-layer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('背景墙').last);
    await tester.pumpAndSettle();
    await apply(tester);
    expect(events.single, {'kind': 'paint', 'layer': 'wall', 'paint': 30});
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'repeat apply pending emits once and recovers after host rejection',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      await show(
        tester,
        brush: RegionBrush.wall(17),
        action: (_, _) {
          calls++;
          return calls == 1 ? pending.future : Future.value();
        },
      );
      final button = find.byKey(const ValueKey('region-brush-apply'));
      await tester.tap(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      expect(calls, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('region-brush-id')))
            .enabled,
        false,
      );
      pending.completeError(StateError('Read only'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Read only'), findsOneWidget);
      await apply(tester);
      expect(calls, 2);
      expect(find.byKey(const ValueKey('region-brush-error')), findsNothing);
    },
  );

  testWidgets('busy and read-only disable intents and parameter editing', (
    tester,
  ) async {
    var calls = 0;
    for (final busy in [false, true]) {
      await show(
        tester,
        busy: busy,
        readOnly: !busy,
        brush: RegionBrush.wall(17),
        action: (_, _) async => calls++,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('region-brush-apply')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('region-brush-id')))
            .enabled,
        false,
      );
    }
    expect(calls, 0);
  });
}
