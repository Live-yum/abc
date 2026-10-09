import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/bestiary_tools_panel.dart';

import 'bestiary_tools_test.dart'
    show bestiaryCatalog, bestiaryRow, emptyBestiary;

void main() {
  final calls = <Map<String, Object?>>[];
  Future<void> mount(
    WidgetTester tester, {
    bool readOnly = false,
    bool busy = false,
    bool metadata = true,
    Future<void> Function()? action,
  }) async {
    calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BestiaryToolsPanel(
              bestiary: emptyBestiary()..['sightings'] = ['Unknown'],
              catalog: metadata
                  ? bestiaryCatalog([
                      bestiaryRow(1, 'Enemy'),
                      bestiaryRow(2, 'Friendly', kind: 'chat'),
                    ])
                  : null,
              readOnly: readOnly,
              busy: busy,
              onAction: (name, args) async {
                calls.add({'action': name, ...args});
                await action?.call();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('readonly, busy, and absent metadata cannot dispatch mutations', (
    tester,
  ) async {
    for (final mode in ['readonly', 'busy', 'missing']) {
      await mount(
        tester,
        readOnly: mode == 'readonly',
        busy: mode == 'busy',
        metadata: mode != 'missing',
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '一键解锁'))
            .onPressed,
        isNull,
      );
      if (mode != 'missing') {
        expect(
          tester.widget<IconButton>(find.byType(IconButton).first).onPressed,
          isNull,
        );
        expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      }
      expect(calls, isEmpty);
    }
  });
  testWidgets('390px layout, search and readonly filtering do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'Friendly');
    await tester.pumpAndSettle();
    expect(find.text('Creature 2'), findsOneWidget);
    expect(find.text('Creature 1'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.widgetWithText(ChoiceChip, '未知/只读'));
    await tester.pumpAndSettle();
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'cancel and invalid kill count retain state; valid count dispatches once',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byTooltip('编辑击杀数量'));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '1000000000');
      await tester.tap(find.text('暂存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 0–999,999,999 的整数'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.byTooltip('编辑击杀数量'));
      await tester.pumpAndSettle();
      await tester.enterText(field, '23');
      await tester.tap(find.text('暂存'));
      await tester.pumpAndSettle();
      expect(calls, [
        {
          'action': 'bestiaryEntry',
          'id': 'Enemy',
          'kind': 'kills',
          'value': 23,
        },
      ]);
    },
  );
  testWidgets(
    'bulk cancel is inert and pending confirmation cannot dispatch twice',
    (tester) async {
      final pending = Completer<void>();
      await mount(tester, action: () => pending.future);
      await tester.tap(find.text('一键解锁'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('一键解锁'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认解锁'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, [
        {'action': 'bestiaryUnlockKnown', 'confirmed': true},
      ]);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '一键解锁'))
            .onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '一键解锁'))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets('action failure stays visible and controls recover', (
    tester,
  ) async {
    await mount(tester, action: () async => throw StateError('write rejected'));
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.textContaining('write rejected'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
    expect(calls.single['kind'], 'chats');
  });
}
