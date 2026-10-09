import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/named_scheme_library.dart';
import 'package:terraforge/domain/world_rules.dart';
import 'package:terraforge/ui/named_scheme_panel.dart';

void main() {
  NamedSchemeLibrary library() =>
      NamedSchemeLibrary(kind: NamedSchemeKind.mapping)
          .create(name: 'First')
          .create(name: 'Second');
  Widget host(
    NamedSchemeLibrary value,
    Future<void> Function(String, Map<String, Object?>) action, {
    bool busy = false,
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: NamedSchemePanel(library: value, busy: busy, onAction: action),
      ),
    ),
  );

  testWidgets('390px management validates names and emits stable ID intents', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final actions = <(String, Map<String, Object?>)>[];
    final value = library();
    await tester.pumpWidget(
      host(value, (action, args) async {
        actions.add((action, args));
      }),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('schemeNameInput')),
      ' first ',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('方案名称已存在，请使用其他名称'), findsOneWidget);
    expect(actions, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('schemeNameInput')),
      ' Renamed ',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(actions.single.$1, 'schemeRename');
    expect(actions.single.$2, {
      'kind': 'mapping',
      'id': value.selectedId,
      'name': 'Renamed',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'delete only dispatches after explicit confirmation, cancel and back are inert',
    (tester) async {
      final actions = <(String, Map<String, Object?>)>[];
      final value = library();
      await tester.pumpWidget(
        host(value, (action, args) async {
          actions.add((action, args));
        }),
      );
      await tester.tap(find.text('删除方案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(actions, isEmpty);
      await tester.tap(find.text('删除方案'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(actions, isEmpty);
      await tester.tap(find.text('删除方案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(actions.single.$1, 'schemeDelete');
      expect(actions.single.$2, {
        'kind': 'mapping',
        'id': value.selectedId,
        'confirmed': true,
      });
    },
  );

  testWidgets(
    'create and clone dialogs cancel safely and suggest distinct names',
    (tester) async {
      final actions = <(String, Map<String, Object?>)>[];
      final value = library();
      await tester.pumpWidget(
        host(value, (action, args) async {
          actions.add((action, args));
        }),
      );
      await tester.tap(find.text('新建方案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(actions, isEmpty);
      await tester.tap(find.text('复制新建'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('schemeNameInput')))
            .controller!
            .text,
        'Second 副本',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(actions.single.$1, 'schemeClone');
      expect(actions.single.$2, {
        'kind': 'mapping',
        'id': value.selectedId,
        'name': 'Second 副本',
      });
    },
  );

  testWidgets(
    'pending operation blocks repeated actions and surfaces failure',
    (tester) async {
      final completion = Completer<void>();
      final actions = <String>[];
      await tester.pumpWidget(
        host(library(), (action, args) {
          actions.add(action);
          return completion.future;
        }),
      );
      await tester.tap(find.text('设为默认'));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '设为默认'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '新建方案'))
            .onPressed,
        isNull,
      );
      expect(actions, ['schemeSetDefault']);
      completion.completeError(StateError('保存失败'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '新建方案'))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('selection sends stable ID independent of its default label', (
    tester,
  ) async {
    final actions = <(String, Map<String, Object?>)>[];
    final value = library();
    await tester.pumpWidget(
      host(value, (action, args) async {
        actions.add((action, args));
      }),
    );
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First · 默认').last);
    await tester.pumpAndSettle();
    expect(actions.single.$1, 'schemeSelect');
    expect(actions.single.$2, {
      'kind': 'mapping',
      'id': value.schemes.first.id,
    });
  });

  testWidgets('stale delete dialog cannot delete externally changed scheme', (
    tester,
  ) async {
    final actions = <String>[];
    var value = library();
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return NamedSchemePanel(
                library: value,
                busy: false,
                onAction: (action, args) async {
                  actions.add(action);
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('删除方案'));
    await tester.pumpAndSettle();
    rebuild(() => value = value.rename(value.selectedId!, 'Changed elsewhere'));
    await tester.pump();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
    expect(find.text('方案已变化，请重新操作'), findsOneWidget);
  });

  testWidgets('builtin actions disclose core expansion limitation', (
    tester,
  ) async {
    final builtin = NamedScheme(
      id: 'builtin:purify',
      name: '净化',
      kind: NamedSchemeKind.worldRules,
      payload: WorldRuleScheme(name: '净化', biomeMode: 'purify').toJson(),
      isBuiltin: true,
    );
    final value = NamedSchemeLibrary(
      kind: NamedSchemeKind.worldRules,
      schemes: [builtin],
      selectedId: builtin.id,
      defaultId: builtin.id,
    );
    await tester.pumpWidget(host(value, (_, _) async {}));
    expect(find.textContaining('尚未提供可编辑规则展开'), findsOneWidget);
    for (final label in ['复制新建', '重命名', '设为默认']) {
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
            .onPressed,
        isNull,
      );
    }
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '删除方案'))
          .onPressed,
      isNull,
    );
  });
}
