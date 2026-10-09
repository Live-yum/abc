import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/map_markers.dart';
import 'package:terraforge/domain/resource_catalog.dart';
import 'package:terraforge/ui/map_markers_panel.dart';

void main() {
  final calls = <Map<String, Object?>>[];
  final catalog = ResourceCatalog(
    gameVersion: 'test',
    provenance: {},
    families: {
      'items': [
        CatalogEntry('items', {'id': 2, 'name': 'Torch'}),
      ],
      'tiles': [
        CatalogEntry('tiles', {'id': '21:0', 'name': 'Chest'}),
        CatalogEntry('tiles', {'id': '21:1', 'name': 'Gold chest'}),
      ],
    },
  );
  Future<void> mount(
    WidgetTester tester, {
    MapMarkerProfile? profile,
    bool busy = false,
    bool hasWorld = true,
    ResourceCatalog? resources,
  }) async {
    calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MapMarkersPanel(
              profile: profile ?? MapMarkerProfile(),
              catalog: resources ?? catalog,
              busy: busy,
              hasWorld: hasWorld,
              onAction: (name, args) async {
                calls.add({'action': name, ...args});
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'catalog-backed selectors dispatch exact same-ID variants and retain style identity',
    (tester) async {
      final a = MapMarkerSelector(locate: 1, frameX: 0, frameY: 0);
      final b = MapMarkerSelector(locate: 1, frameX: 18, frameY: 0);
      final resources = ResourceCatalog(
        gameVersion: 'test',
        provenance: {},
        families: {
          'entity-markers': [
            CatalogEntry('entity-markers', {
              'id': '42:a',
              'name': 'Synthetic A',
              'selector': {'tile_type': 42, ...a.toJson()},
            }),
            CatalogEntry('entity-markers', {
              'id': '42:b',
              'name': 'Synthetic B',
              'selector': {'tile_type': 42, ...b.toJson()},
            }),
          ],
        },
      );
      await mount(
        tester,
        resources: resources,
        profile: MapMarkerProfile().toggle('tile', 42, selector: a),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('实体方块').last);
      await tester.pumpAndSettle();
      final first = find.byKey(ValueKey('marker-candidate-tile-42:${a.key}'));
      final second = find.byKey(ValueKey('marker-candidate-tile-42:${b.key}'));
      expect(tester.widget<CheckboxListTile>(first).value, isTrue);
      expect(tester.widget<CheckboxListTile>(second).value, isFalse);
      await tester.tap(second);
      await tester.pumpAndSettle();
      expect(calls.single, {
        'action': 'markerToggle',
        'kind': 'tile',
        'id': 42,
        'selector': b.toJson(),
      });
      final style = find.byKey(ValueKey('marker-style-tile:42:${a.key}'));
      await tester.ensureVisible(style);
      await tester.tap(style);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存样式'));
      await tester.pumpAndSettle();
      expect(calls.last['selector'], a.toJson());
      final remove = find.byKey(ValueKey('marker-remove-tile:42:${a.key}'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(calls.last, {
        'action': 'markerRemove',
        'kind': 'tile',
        'id': 42,
        'selector': a.toJson(),
      });
    },
  );
  testWidgets(
    'explicit selector editor rejects malformed frames and does not infer catalog variant frames',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('实体方块').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('输入定位条件'));
      await tester.pumpAndSettle();
      final frame = find.byKey(const ValueKey('marker-selector-frame_x'));
      expect(tester.widget<TextField>(frame).controller!.text, '-1');
      await tester.enterText(frame, '32768');
      await tester.tap(find.text('切换此定位标记'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.enterText(frame, '18');
      await tester.tap(find.text('切换此定位标记'));
      await tester.pumpAndSettle();
      expect(calls.single, {
        'action': 'markerToggle',
        'kind': 'tile',
        'id': 21,
        'selector': {'locate': 1, 'frame_x': 18},
      });
    },
  );
  testWidgets(
    'catalog search and compound tile IDs dispatch validated numeric types',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('marker-candidate-item-2')));
      await tester.pumpAndSettle();
      expect(calls.single, {'action': 'markerToggle', 'kind': 'item', 'id': 2});
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('实体方块').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('marker-candidate-tile-21')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('marker-candidate-tile-21')));
      await tester.pumpAndSettle();
      expect(calls.last, {'action': 'markerToggle', 'kind': 'tile', 'id': 21});
      await tester.enterText(find.byType(TextField), '999999');
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
    },
  );
  testWidgets('clear cancellation and confirmation are explicit', (
    tester,
  ) async {
    await mount(tester, profile: MapMarkerProfile().toggle('item', 2));
    await tester.tap(find.text('清空标记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.text('清空标记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清空'));
    await tester.pumpAndSettle();
    expect(calls.single, {'action': 'markerClear', 'confirmed': true});
  });
  testWidgets(
    'unknown saved marker stays visible; style validates and renders at 390px',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, profile: MapMarkerProfile().toggle('tile', 65535));
      expect(find.textContaining('未知 ID 65535'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('marker-style-tile:65535')),
      );
      await tester.tap(find.byKey(const ValueKey('marker-style-tile:65535')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '颜色 #RRGGBB'),
        '#123456FF',
      );
      await tester.tap(find.text('保存样式'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextField, '颜色 #RRGGBB'),
        '#123456',
      );
      await tester.tap(find.text('保存样式'));
      await tester.pumpAndSettle();
      expect(calls.single, {
        'action': 'markerStyle',
        'kind': 'tile',
        'id': 65535,
        'color': '#123456',
        'radius': 30,
        'lineWidth': 3,
      });
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('busy disables actions; no world disables rendering only', (
    tester,
  ) async {
    await mount(
      tester,
      profile: MapMarkerProfile().toggle('item', 2),
      busy: true,
    );
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await mount(
      tester,
      profile: MapMarkerProfile().toggle('item', 2),
      hasWorld: false,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNotNull,
    );
  });
}
