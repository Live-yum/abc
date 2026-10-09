import 'dart:async';
import 'dart:convert';

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
    'revision': 1,
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

Map<String, Object?> previewFixture({String kind = 'route'}) {
  final state = fixture();
  (state['snapshot'] as Map)['preview'] = {
    'kind': kind,
    'token': 'owner-issued-preview-token',
    'editorId': 1,
    'generation': 1,
    'revision': 1,
    'cells': [
      [0, 0, 3],
      [0, 1, 1],
      [1, 1, 2],
    ],
    'count': 3,
    'colourCounts': [2, 2, 0, 0],
  };
  return state;
}

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

Future<void> tapChip(WidgetTester tester, String label) async {
  final chip = find.ancestor(
    of: find.text(label),
    matching: find.byType(FilterChip),
  );
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'route preview uses original endpoints and commits only its token',
    (tester) async {
      addTearDown(tester.view.reset);
      final calls = <(String, Map<String, Object?>)>[];
      final commit = Completer<void>();
      Future<void> dispatch(String name, Map<String, Object?> args) {
        calls.add((name, args));
        return name == 'rulesCommitPreview' ? commit.future : Future.value();
      }

      await mount(tester, fixture(), dispatch);
      await tapChip(tester, '蓝线');
      for (final entry in {
        'X': '4',
        'Y': '6',
        '终点 X': '8',
        '终点 Y': '9',
      }.entries) {
        final field = find.byKey(ValueKey('circuit-${entry.key}'));
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
      }
      await tapText(tester, '预览自动布线');
      expect(calls.map((call) => [call.$1, call.$2]), [
        [
          'rulesPreviewRoute',
          {'startX': 4, 'startY': 6, 'endX': 8, 'endY': 9, 'mask': 3},
        ],
      ]);
      final state = previewFixture();
      final originalDocument = jsonEncode(state['document']);
      await mount(tester, state, dispatch);
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsOneWidget,
      );
      expect(find.text('3 个线格 · 4 条色线'), findsOneWidget);
      expect(find.text('红线 2'), findsOneWidget);
      expect(find.text('蓝线 2'), findsOneWidget);
      expect(find.text('绿线 0'), findsOneWidget);
      expect(find.text('黄线 0'), findsOneWidget);
      final confirm = find.byKey(const ValueKey('circuit-confirm-preview'));
      await tester.ensureVisible(confirm);
      // Two taps before rebuilding must still submit the owner token only once.
      await tester.tap(confirm);
      await tester.tap(confirm);
      await tester.pump();
      expect(calls.last.$1, 'rulesCommitPreview');
      expect(calls.last.$2, {'token': 'owner-issued-preview-token'});
      expect(calls.length, 2);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(jsonEncode(state['document']), originalDocument);
      commit.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'network deletion is previewed and cancel makes no document edit',
    (tester) async {
      addTearDown(tester.view.reset);
      final calls = <(String, Map<String, Object?>)>[];
      Future<void> dispatch(String name, Map<String, Object?> args) async {
        calls.add((name, args));
      }

      await mount(tester, fixture(), dispatch);
      await tapText(tester, '预览删除相连网络');
      expect(calls.map((call) => [call.$1, call.$2]), [
        [
          'rulesPreviewNetwork',
          {'x': 0, 'y': 0, 'mask': 1},
        ],
      ]);
      final state = previewFixture(kind: 'removeNetwork');
      final originalDocument = jsonEncode(state['document']);
      await mount(tester, state, dispatch);
      expect(find.text('确认删除网络'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsOneWidget,
      );
      await tapText(tester, '取消预览');
      expect(calls.last.$1, 'rulesCancelPreview');
      expect(calls.last.$2, isEmpty);
      expect(calls.length, 2);
      expect(jsonEncode(state['document']), originalDocument);
      expect(find.text('确认删除网络'), findsNothing);
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('network canvas tool requests a preview instead of deleting', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final calls = <(String, Map<String, Object?>)>[];
    await mount(tester, fixture(), (name, args) async {
      calls.add((name, args));
    });
    final tool = find.byKey(const ValueKey('circuit-tool-inspect'));
    await tester.ensureVisible(tool);
    await tester.tap(tool);
    await tester.pumpAndSettle();
    final network = find.text('删除相连网络').last;
    await tester.ensureVisible(network);
    await tester.tap(network);
    await tester.pumpAndSettle();
    final stage = find.byKey(const ValueKey('authoritative-circuit-stage'));
    await tester.ensureVisible(stage);
    await tester.tapAt(tester.getTopLeft(stage) + const Offset(36, 60));
    await tester.pumpAndSettle();
    expect(calls.map((call) => [call.$1, call.$2]), [
      [
        'rulesPreviewNetwork',
        {'x': 1, 'y': 2, 'mask': 1},
      ],
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending preview can be cancelled and late results stay hidden', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final calls = <String>[];
    final pending = Completer<void>();
    Future<void> dispatch(String name, Map<String, Object?> args) {
      calls.add(name);
      return name == 'rulesPreviewRoute' ? pending.future : Future.value();
    }

    await mount(tester, fixture(), dispatch);
    await tester.ensureVisible(find.text('预览自动布线'));
    await tester.tap(find.text('预览自动布线'));
    await tester.pump();
    final cancel = find.byKey(const ValueKey('circuit-cancel-preview'));
    expect(tester.widget<OutlinedButton>(cancel).onPressed, isNotNull);
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pump();
    expect(calls, ['rulesPreviewRoute', 'rulesCancelPreview']);
    pending.complete();
    await tester.pumpAndSettle();
    await mount(tester, previewFixture(), dispatch);
    expect(find.byKey(const ValueKey('circuit-preview-overlay')), findsNothing);
    expect(find.byKey(const ValueKey('circuit-confirm-preview')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner-busy preview still allows cancellation', (tester) async {
    addTearDown(tester.view.reset);
    final state = previewFixture()..['busy'] = true;
    final calls = <String>[];
    await mount(tester, state, (name, args) async {
      calls.add(name);
    });
    final confirm = find.byKey(const ValueKey('circuit-confirm-preview'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    final cancel = find.byKey(const ValueKey('circuit-cancel-preview'));
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pump();
    expect(calls, ['rulesCancelPreview']);
    expect(find.byKey(const ValueKey('circuit-preview-overlay')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  for (final input in ['终点 X', 'X', 'colour', 'tool']) {
    testWidgets('$input change cancels the displayed preview', (tester) async {
      addTearDown(tester.view.reset);
      final calls = <String>[];
      final state = previewFixture();
      final originalDocument = jsonEncode(state['document']);
      await mount(tester, state, (name, args) async {
        calls.add(name);
      });
      if (input == 'colour') {
        await tapChip(tester, '蓝线');
      } else if (input == 'tool') {
        final tool = find.byKey(const ValueKey('circuit-tool-inspect'));
        await tester.ensureVisible(tool);
        await tester.tap(tool);
        await tester.pumpAndSettle();
        await tester.tap(find.text('平移画布').last);
        await tester.pumpAndSettle();
      } else {
        final field = find.byKey(ValueKey('circuit-$input'));
        await tester.ensureVisible(field);
        await tester.enterText(field, '7');
        await tester.pumpAndSettle();
      }
      expect(calls, ['rulesCancelPreview']);
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('circuit-confirm-preview')),
        findsNothing,
      );
      expect(jsonEncode(state['document']), originalDocument);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'new document identity removes stale preview and clears endpoints',
    (tester) async {
      addTearDown(tester.view.reset);
      Future<void> dispatch(String name, Map<String, Object?> args) async {}
      await mount(tester, fixture(), dispatch);
      final endpoint = find.byKey(const ValueKey('circuit-终点 X'));
      await tester.ensureVisible(endpoint);
      await tester.enterText(endpoint, '29');
      await mount(tester, previewFixture(), dispatch);
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsOneWidget,
      );
      final newer = previewFixture();
      (newer['snapshot'] as Map)['id'] = 2;
      await mount(tester, newer, dispatch);
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('circuit-confirm-preview')),
        findsNothing,
      );
      expect(tester.widget<TextField>(endpoint).controller!.text, '0');
      expect(tester.takeException(), isNull);
    },
  );

  for (final changed in ['generation', 'revision']) {
    testWidgets('new $changed removes a stale preview', (tester) async {
      addTearDown(tester.view.reset);
      Future<void> dispatch(String name, Map<String, Object?> args) async {}
      await mount(tester, previewFixture(), dispatch);
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsOneWidget,
      );
      final newer = previewFixture();
      (newer['snapshot'] as Map)[changed] = 2;
      await mount(tester, newer, dispatch);
      expect(
        find.byKey(const ValueKey('circuit-preview-overlay')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('circuit-confirm-preview')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('rejected route has no confirmable edit and preserves document', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final state = fixture();
    final originalDocument = jsonEncode(state['document']);
    final calls = <String>[];
    await mount(tester, state, (name, args) async {
      calls.add(name);
      throw StateError('没有可用路径');
    });
    await tapText(tester, '预览自动布线');
    expect(calls, ['rulesPreviewRoute']);
    expect(find.textContaining('没有可用路径'), findsOneWidget);
    expect(find.byKey(const ValueKey('circuit-preview-overlay')), findsNothing);
    expect(find.byKey(const ValueKey('circuit-confirm-preview')), findsNothing);
    expect(jsonEncode(state['document']), originalDocument);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed commit shows the owner error without duplicate edits', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final pending = Completer<void>();
    final calls = <(String, Map<String, Object?>)>[];
    Future<void> dispatch(String name, Map<String, Object?> args) {
      calls.add((name, args));
      return pending.future;
    }

    final state = previewFixture(kind: 'removeNetwork');
    final originalDocument = jsonEncode(state['document']);
    await mount(tester, state, dispatch);
    final confirm = find.byKey(const ValueKey('circuit-confirm-preview'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.tap(confirm);
    await tester.pump();
    expect(calls.length, 1);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    // The owner catches backend failures and publishes an error with the
    // unchanged document, rather than throwing through the UI callback.
    final rejected = {...state, 'error': '预览提交被规则引擎拒绝'};
    await mount(tester, rejected, dispatch);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('预览提交被规则引擎拒绝'), findsOneWidget);
    expect(calls.length, 1);
    expect(calls.single.$1, 'rulesCommitPreview');
    expect(calls.single.$2, {'token': 'owner-issued-preview-token'});
    expect(jsonEncode(rejected['document']), originalDocument);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview controls and masked counts fit a narrow phone', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await mount(
      tester,
      previewFixture(kind: 'removeNetwork'),
      (name, args) async {},
      width: 320,
    );
    await tester.ensureVisible(find.text('确认删除网络'));
    await tester.pump();
    expect(find.text('3 个线格 · 4 条色线'), findsOneWidget);
    expect(find.text('取消预览'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('circuit-终点 X')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

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
