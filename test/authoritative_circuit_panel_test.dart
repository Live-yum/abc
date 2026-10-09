import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/authoritative_circuit_panel.dart';
import 'package:terraforge/ui/terra_theme.dart';

Map<String, Object?> fixture({bool dirty = false}) => {
  'ready': true,
  'busy': false,
  'error': '',
  'catalog': {
    'target': {'game': '1.4.5.8'},
    'definitions': {
      'switch': {'name': '开关', 'group': '输入', 'width': 1, 'height': 1},
      'lever': {'name': '拉杆', 'group': '输入', 'width': 2, 'height': 2},
      'announcementBox': {
        'name': '广播盒',
        'group': '环境',
        'width': 2,
        'height': 2,
      },
    },
    'palette': [
      {'id': 'switch', 'kind': 'switch', 'label': '开关', 'itemId': 538},
      {'id': 'lever', 'kind': 'lever', 'label': '拉杆 2×2', 'itemId': 513},
      {
        'id': 'announcement',
        'kind': 'announcementBox',
        'label': '广播盒',
        'itemId': 3614,
      },
    ],
    'demos': ['logic', 'timer', 'storage'],
    'wireColors': ['#ef5350', '#42a5f5', '#66bb6a', '#ffee58'],
    'wireNames': ['红线', '蓝线', '绿线', '黄线'],
  },
  'snapshot': {
    'id': 1,
    'generation': 1,
    'dirty': dirty,
    'canUndo': true,
    'canRedo': false,
    'canReset': true,
    'clipboardAvailable': true,
    'selection': {'x': 2, 'y': 3, 'width': 2, 'height': 2},
  },
  'document': {
    'format': 'viewer-terralogic',
    'version': 1,
    'title': 'Widget fixture',
    'tick': 12,
    'world': {
      'width': 2147483647,
      'height': 2147483647,
      'wires': [
        [0, 0, 15],
        [1, 0, 15],
      ],
      'tiles': [
        {
          'kind': 'switch',
          'x': 0,
          'y': 0,
          'width': 1,
          'height': 1,
          'style': 0,
          'on': false,
          'color': '#ffffff',
        },
        {
          'kind': 'lever',
          'x': 2,
          'y': 3,
          'width': 2,
          'height': 2,
          'style': 0,
          'on': true,
          'actuator': false,
          'cooldown': 0,
        },
        {
          'kind': 'announcementBox',
          'x': 5,
          'y': 3,
          'width': 2,
          'height': 2,
          'style': 0,
          'on': false,
          'message': 'Hello',
          'cellActuators': <int>[],
        },
      ],
    },
  },
};

Future<void> mount(
  WidgetTester tester,
  Map<String, Object?> state,
  Future<void> Function(String, Map<String, Object?>) dispatch, {
  double width = 390,
}) async {
  tester.view.reset();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  await tester.pumpWidget(
    MaterialApp(
      theme: terraTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: AuthoritativeCircuitPanel(state: state, onAction: dispatch),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('edit generations retain the current sparse viewport', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    Future<void> dispatch(String name, Map<String, Object?> args) async {}
    await mount(tester, fixture(), dispatch);
    for (final entry in {'X': '100', 'Y': '200'}.entries) {
      final field = find.byKey(ValueKey('circuit-${entry.key}'));
      await tester.ensureVisible(field);
      await tester.enterText(field, entry.value);
    }
    await tapText(tester, '定位坐标');
    final updated = fixture();
    (updated['snapshot'] as Map)['generation'] = 2;
    await mount(tester, updated, dispatch);
    final stage = find.byKey(const ValueKey('authoritative-circuit-stage'));
    await tester.ensureVisible(stage);
    await tester.tapAt(tester.getTopLeft(stage) + const Offset(36, 60));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('circuit-X')))
          .controller!
          .text,
      '99',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('circuit-Y')))
          .controller!
          .text,
      '200',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('state-reported validation errors keep the property draft open', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    var state = fixture();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: terraTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => SingleChildScrollView(
              child: AuthoritativeCircuitPanel(
                state: state,
                onAction: (name, args) async {
                  attempts++;
                  update(() {
                    state = {
                      ...state,
                      'error': attempts == 1 ? 'Rejected actual property' : '',
                    };
                  });
                },
              ),
            ),
          ),
        ),
      ),
    );
    final stage = find.byKey(const ValueKey('authoritative-circuit-stage'));
    await tester.ensureVisible(stage);
    await tester.tapAt(tester.getTopLeft(stage) + const Offset(12, 12));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('circuit-property-color')),
      '#112233',
    );
    await tester.tap(find.text('应用属性'));
    await tester.pumpAndSettle();
    expect(find.text('开关 · 实际属性'), findsOneWidget);
    expect(find.text('Rejected actual property'), findsWidgets);
    expect(find.text('#112233'), findsOneWidget);
    await tester.tap(find.text('应用属性'));
    await tester.pumpAndSettle();
    expect(find.text('开关 · 实际属性'), findsNothing);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'owner-managed running clock can be paused while a tick is busy',
    (tester) async {
      addTearDown(tester.view.reset);
      final state = fixture()
        ..['running'] = true
        ..['busy'] = true;
      final calls = <String>[];
      await mount(tester, state, (name, args) async {
        calls.add(name);
      });
      await tester.ensureVisible(find.text('暂停'));
      await tester.tap(find.text('暂停'));
      await tester.pump();
      expect(calls, ['rulesToggleRun']);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unloaded engine is honest and duplicate opens are suppressed', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final calls = <String>[];
    final pending = Completer<void>();
    await mount(tester, {'ready': false}, (name, args) {
      calls.add(name);
      return pending.future;
    });
    await tester.tap(find.text('加载电路规则'));
    await tester.tap(find.text('加载电路规则'));
    await tester.pump();
    expect(calls, ['rulesOpen']);
    expect(find.text('运行'), findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phone layout keeps schema, four channels and full catalog actions',
    (tester) async {
      addTearDown(tester.view.reset);
      final calls = <(String, Map<String, Object?>)>[];
      await mount(tester, fixture(), (name, args) async {
        calls.add((name, args));
      });
      expect(find.text('红线'), findsOneWidget);
      expect(find.text('蓝线'), findsOneWidget);
      expect(find.text('绿线'), findsOneWidget);
      expect(find.text('黄线'), findsOneWidget);
      await tapText(tester, '单步');
      expect(calls.last.$1, 'rulesSimulate');
      expect(calls.last.$2, {
        'method': 'step',
        'args': [1],
      });
      await tapText(tester, '元件库 (3)');
      await tester.enterText(
        find.byKey(const ValueKey('circuit-palette-search')),
        '513',
      );
      await tester.pump();
      expect(find.text('拉杆 2×2'), findsOneWidget);
      expect(find.text('广播盒'), findsNothing);
      await tester.tap(find.text('拉杆 2×2'));
      await tester.pumpAndSettle();
      final stage = find.byKey(const ValueKey('authoritative-circuit-stage'));
      await tester.ensureVisible(stage);
      await tester.tapAt(tester.getTopLeft(stage) + const Offset(36, 60));
      await tester.pumpAndSettle();
      expect(calls.last.$1, 'rulesEdit');
      expect(calls.last.$2['method'], 'placeTile');
      expect((calls.last.$2['args'] as List)[1], {'x': 1, 'y': 2});
      expect(((calls.last.$2['args'] as List)[0] as Map)['kind'], 'lever');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'numeric selection and clipboard transforms forward original arguments',
    (tester) async {
      addTearDown(tester.view.reset);
      final calls = <Map<String, Object?>>[];
      await mount(tester, fixture(), (name, args) async {
        calls.add(args);
      });
      for (final entry in {'X': '8', 'Y': '9', '宽': '7', '高': '6'}.entries) {
        final input = find.byKey(ValueKey('circuit-${entry.key}'));
        await tester.ensureVisible(input);
        await tester.enterText(input, entry.value);
      }
      await tapText(tester, '框选区域');
      expect(calls.last, {
        'method': 'select',
        'args': [
          {'x': 8, 'y': 9, 'width': 7, 'height': 6},
        ],
      });
      await tapText(tester, '旋转剪贴板');
      expect(calls.last, {
        'method': 'transformClipboard',
        'args': ['rotate'],
      });
      await tapText(tester, '粘贴到坐标');
      expect(calls.last, {
        'method': 'paste',
        'args': [
          {'x': 8, 'y': 9},
          {'merge': false},
        ],
      });
      await tapText(tester, '推进黎明边界');
      expect(calls.last, {
        'method': 'advanceBoundary',
        'args': ['dawn'],
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual tile properties survive cancel and send only changed values',
    (tester) async {
      addTearDown(tester.view.reset);
      final calls = <Map<String, Object?>>[];
      await mount(tester, fixture(), (name, args) async {
        calls.add(args);
      });
      final stage = find.byKey(const ValueKey('authoritative-circuit-stage'));
      await tester.ensureVisible(stage);
      await tester.tapAt(tester.getTopLeft(stage) + const Offset(132, 84));
      await tester.pumpAndSettle();
      expect(find.text('广播盒 · 实际属性'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('circuit-property-message')),
        'Changed',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tapAt(tester.getTopLeft(stage) + const Offset(132, 84));
      await tester.pumpAndSettle();
      expect(find.text('Hello'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('circuit-property-message')),
        'Real message',
      );
      await tester.tap(find.text('应用属性'));
      await tester.pumpAndSettle();
      expect(calls.last, {
        'method': 'updateTile',
        'args': [
          5,
          3,
          {'message': 'Real message'},
        ],
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dirty close can be cancelled with back and confirmed explicitly',
    (tester) async {
      addTearDown(tester.view.reset);
      final calls = <String>[];
      await mount(tester, fixture(dirty: true), (name, args) async {
        calls.add(name);
      });
      await tapText(tester, '关闭电路');
      expect(find.text('丢弃并继续'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tapText(tester, '关闭电路');
      await tester.tap(find.text('丢弃并继续'));
      await tester.pumpAndSettle();
      expect(calls, ['rulesClose']);
    },
  );

  testWidgets('backend rejection remains visible and retry is possible', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    var attempts = 0;
    await mount(tester, fixture(), (name, args) async {
      attempts++;
      if (attempts == 1) throw StateError('Authoritative failure');
    });
    await tapText(tester, '单步');
    expect(find.textContaining('Authoritative failure'), findsOneWidget);
    await tapText(tester, '单步');
    expect(attempts, 2);
    expect(find.textContaining('Authoritative failure'), findsNothing);
  });

  testWidgets('large actual catalog is virtualized and searchable on desktop', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final state = fixture();
    final catalog = state['catalog'] as Map<String, Object?>;
    catalog['palette'] = List.generate(
      2776,
      (i) => {
        'id': 'test-$i',
        'kind': 'switch',
        'label': 'Fixture $i',
        'itemId': i,
      },
    );
    await mount(tester, state, (name, args) async {}, width: 1280);
    expect(find.text('实际元件库 · 2776/2776'), findsOneWidget);
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    await tester.enterText(
      find.byKey(const ValueKey('circuit-palette-search')),
      '2775',
    );
    await tester.pump();
    expect(find.text('Fixture 2775'), findsOneWidget);
    expect(find.text('实际元件库 · 1/2776'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
