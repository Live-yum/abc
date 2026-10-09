import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/resource_catalog.dart';
import 'package:terraforge/ui/achievement_tools_panel.dart';

ResourceCatalog catalog({String kind = 'int', Object? maximum = 10}) =>
    ResourceCatalog(
      gameVersion: 'synthetic',
      provenance: const {},
      families: {
        'achievements': [
          CatalogEntry('achievements', {
            'id': 'COUNT',
            'name': 'Synthetic Counter',
            'description': 'Collect synthetic tokens',
            'category': 'Explorer',
            'conditions': [
              {'id': 'count', 'kind': kind, 'max': maximum},
            ],
          }),
          CatalogEntry('achievements', {
            'id': 'FLAG',
            'name': 'Synthetic Flag',
            'category': 'Builder',
            'conditions': [
              {'id': 'flag', 'kind': 'boolean'},
            ],
          }),
        ],
      },
    );

Map<String, Object?> record(
  String id,
  String condition,
  String kind, {
  bool completed = false,
  Object? value = 3,
}) => {
  'id': id,
  'completed': completed,
  'editable': true,
  'conditions': [
    {
      'id': condition,
      'kind': kind,
      'value': value,
      'completed': completed,
      'editable': true,
    },
  ],
};

void main() {
  late List<(String, Map<String, Object?>)> actions;
  setUp(() => actions = []);
  Future<void> mount(
    WidgetTester tester, {
    ResourceCatalog? resources,
    List<Map<String, Object?>>? records,
    bool busy = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: AchievementToolsPanel(
                records: records ?? [record('COUNT', 'count', 'int')],
                catalog: resources,
                busy: busy,
                onAction: (action, args) => actions.add((action, args)),
              ),
            ),
          ),
        ),
      ),
    );
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Future<void> openCount(WidgetTester tester) async {
    await tap(tester, find.byKey(const Key('achievement-COUNT')));
  }

  testWidgets('search names descriptions IDs, category and completed status', (
    tester,
  ) async {
    await mount(
      tester,
      resources: catalog(),
      records: [
        record('COUNT', 'count', 'int'),
        record('FLAG', 'flag', 'boolean', completed: true),
      ],
    );
    for (final query in ['counter', 'TOKENS', 'COUNT']) {
      await tester.enterText(
        find.byKey(const Key('achievement-search')),
        query,
      );
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byKey(const Key('achievement-COUNT')), findsOneWidget);
      expect(find.byKey(const Key('achievement-FLAG')), findsNothing);
    }
    await tester.enterText(find.byKey(const Key('achievement-search')), '');
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tap(tester, find.byKey(const Key('achievement-category-filter-')));
    await tap(tester, find.text('Builder').last);
    expect(find.byKey(const Key('achievement-COUNT')), findsNothing);
    expect(find.byKey(const Key('achievement-FLAG')), findsOneWidget);
    await tap(tester, find.byKey(const Key('achievement-status-filter')));
    await tap(tester, find.text('未完成').last);
    expect(find.text('没有匹配当前搜索与筛选的成就。'), findsOneWidget);
    await tap(tester, find.byKey(const Key('achievement-status-filter')));
    await tap(tester, find.text('已完成').last);
    expect(find.byKey(const Key('achievement-FLAG')), findsOneWidget);
    expect(actions, isEmpty);
  });

  testWidgets(
    'integer progress requires a finite integer within verified target',
    (tester) async {
      await mount(tester, resources: catalog());
      await openCount(tester);
      await tap(
        tester,
        find.byKey(const Key('achievement-progress-COUNT-count')),
      );
      expect(find.text('目录目标值：10。达到目标时自动标记完成。'), findsOneWidget);
      for (final input in ['NaN', 'Infinity', '1.5', '-1', '11']) {
        await tester.enterText(
          find.byKey(const Key('achievement-progress-value')),
          input,
        );
        await tap(tester, find.byKey(const Key('achievement-progress-save')));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(actions, isEmpty);
      }
      await tester.enterText(
        find.byKey(const Key('achievement-progress-value')),
        '7',
      );
      await tap(tester, find.byKey(const Key('achievement-progress-save')));
      expect(actions, hasLength(1));
      expect(actions.single.$1, 'achievementCondition');
      expect(actions.single.$2, {
        'id': 'COUNT',
        'conditionId': 'count',
        'value': 7,
      });
      expect(actions.single.$2['value'], isA<int>());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'float progress accepts fractional values and cancel emits nothing',
    (tester) async {
      await mount(
        tester,
        resources: catalog(kind: 'float', maximum: 2.5),
        records: [record('COUNT', 'count', 'float', value: 0.5)],
      );
      await openCount(tester);
      await tap(
        tester,
        find.byKey(const Key('achievement-progress-COUNT-count')),
      );
      await tester.enterText(
        find.byKey(const Key('achievement-progress-value')),
        '2.6',
      );
      await tap(tester, find.byKey(const Key('achievement-progress-save')));
      expect(actions, isEmpty);
      await tap(tester, find.text('取消'));
      expect(actions, isEmpty);
      await tap(
        tester,
        find.byKey(const Key('achievement-progress-COUNT-count')),
      );
      await tester.enterText(
        find.byKey(const Key('achievement-progress-value')),
        '1.25',
      );
      await tap(tester, find.byKey(const Key('achievement-progress-save')));
      expect(actions.single.$2['value'], 1.25);
    },
  );

  testWidgets('unknown numeric and mismatched conditions are read only', (
    tester,
  ) async {
    for (final resources in [
      null,
      catalog(kind: 'float'),
      catalog(maximum: null),
    ]) {
      await mount(tester, resources: resources);
      // The same panel state can retain the expanded tile between rebuilds.
      if (find
          .byKey(const Key('achievement-toggle-COUNT-count'))
          .evaluate()
          .isEmpty) {
        await openCount(tester);
      }
      final toggle = tester.widget<Checkbox>(
        find.byKey(const Key('achievement-toggle-COUNT-count')),
      );
      final progress = tester.widget<OutlinedButton>(
        find.byKey(const Key('achievement-progress-COUNT-count')),
      );
      expect(toggle.onChanged, isNull);
      expect(progress.onPressed, isNull);
    }
    expect(actions, isEmpty);
  });

  testWidgets('legacy unknown boolean remains manually editable', (
    tester,
  ) async {
    await mount(tester, records: [record('LEGACY', 'switch', 'boolean')]);
    await tap(tester, find.byKey(const Key('achievement-LEGACY')));
    await tap(
      tester,
      find.byKey(const Key('achievement-toggle-LEGACY-switch')),
    );
    expect(actions, hasLength(1));
    expect(actions.single.$1, 'achievementCondition');
    expect(actions.single.$2, {
      'id': 'LEGACY',
      'conditionId': 'switch',
      'completed': true,
    });
  });

  testWidgets(
    'bulk confirmation explains known intersection and ignores filters',
    (tester) async {
      await mount(tester, resources: catalog());
      await tester.enterText(
        find.byKey(const Key('achievement-search')),
        'nothing',
      );
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tap(tester, find.byKey(const Key('achievement-complete-known')));
      expect(find.textContaining('目录外成就、未知条件和未验证的数值均保留'), findsOneWidget);
      expect(find.textContaining('不受当前搜索或筛选限制'), findsOneWidget);
      await tap(tester, find.text('取消'));
      expect(actions, isEmpty);
      await tap(tester, find.byKey(const Key('achievement-complete-known')));
      await tap(tester, find.text('确认'));
      expect(actions, hasLength(1));
      expect(actions.single.$1, 'achievementCompleteKnown');
      expect(actions.single.$2, {'confirmed': true});
    },
  );

  testWidgets('new file warns of replacement and requires confirmation', (
    tester,
  ) async {
    await mount(tester, resources: catalog());
    await tap(tester, find.byKey(const Key('achievement-new')));
    expect(find.textContaining('替换当前工作区中的成就文档'), findsOneWidget);
    await tap(tester, find.text('取消'));
    expect(actions, isEmpty);
    await tap(tester, find.byKey(const Key('achievement-new')));
    await tap(tester, find.text('确认'));
    expect(actions, hasLength(1));
    expect(actions.single.$1, 'achievementNew');
    expect(actions.single.$2, {'confirmed': true});
  });

  testWidgets('missing catalog and busy state disable unsafe actions', (
    tester,
  ) async {
    await mount(tester);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('achievement-new')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('achievement-complete-known')),
          )
          .onPressed,
      isNull,
    );
    await mount(tester, resources: catalog(), busy: true);
    await openCount(tester);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('achievement-new')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const Key('achievement-toggle-COUNT-count')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('achievement-progress-COUNT-count')),
          )
          .onPressed,
      isNull,
    );
    expect(actions, isEmpty);
  });

  testWidgets('390px layout and numeric dialog have no overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, resources: catalog());
    await openCount(tester);
    expect(tester.takeException(), isNull);
    await tap(
      tester,
      find.byKey(const Key('achievement-progress-COUNT-count')),
    );
    expect(tester.takeException(), isNull);
    await tap(tester, find.text('取消'));
    expect(tester.takeException(), isNull);
  });
}
