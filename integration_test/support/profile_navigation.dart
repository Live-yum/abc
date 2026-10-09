import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/terra_app.dart';

/// Drives the actual sidebar, including rows that ListView has not built yet.
/// No route callbacks, controller dispatches or offscreen taps substitute for UI.
class ProfileNavigation {
  ProfileNavigation(this.tester, this.settle);
  final WidgetTester tester;
  final Future<void> Function() settle;
  String? requested;
  String step = 'idle';

  static const destinations = {
    '工作台': 'home',
    '世界档案': 'world',
    '存档中心': 'saves',
    '像素工坊': 'pixel',
    '角色实验室': 'player',
    '电路实验室': 'circuit',
    '融合画布': 'fusion',
    '世界生成': 'generation',
    '写入工作流': 'write',
    '图鉴与成就': 'codex',
    '映射方案': 'mapping',
    '设置与资源': 'settings',
  };

  Finder get workspace => find.byType(TerraWorkspace);
  Finder get scaffold =>
      find.descendant(of: workspace, matching: find.byType(Scaffold)).first;

  Finder navigationList() {
    // The fixed brand header survives lazy-list eviction. Its sidebar Column
    // directly owns Expanded(ListView); the inner brand Column does not.
    final brand = find.descendant(
      of: workspace,
      matching: find.text('STUDIO FOR TERRARIA'),
    );
    expect(
      brand,
      findsOneWidget,
      reason: 'Expected the active sidebar brand header',
    );
    final sidebar = find.ancestor(
      of: brand,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Column &&
            widget.children.any(
              (child) => child is Expanded && child.child is ListView,
            ),
        description:
            'sidebar Column that directly owns the navigation ListView',
      ),
    );
    expect(sidebar, findsOneWidget);
    final list = find.descendant(of: sidebar, matching: find.byType(ListView));
    expect(list, findsOneWidget);
    return list;
  }

  Future<void> go(String title) async {
    requested = title;
    step = 'identify active scaffold';
    expect(workspace, findsOneWidget);
    final state = tester.state<ScaffoldState>(scaffold);
    if (state.widget.drawer != null && !state.isDrawerOpen) {
      step = 'open drawer with menu button';
      final menu = find.descendant(
        of: workspace,
        matching: find.byTooltip('全部功能'),
      );
      expect(menu.hitTestable(), findsOneWidget);
      await tester.tap(menu);
      await settle();
    }

    step = 'locate sidebar list';
    final list = navigationList();
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final scrollState = tester.state<ScrollableState>(scrollable);
    final label = find.descendant(of: list, matching: find.text(title));

    // A missing label can be above or below the live child/cache range. Scan
    // toward the start, then toward the end, bounded by the real scroll extent
    // and a finite number of gestures. Never call ensureVisible on no element.
    for (final towardStart in [true, false]) {
      for (
        var attempt = 0;
        attempt < 20 && label.evaluate().isEmpty;
        attempt++
      ) {
        final position = scrollState.position;
        final before = position.pixels;
        final boundary = towardStart
            ? position.minScrollExtent
            : position.maxScrollExtent;
        if ((before - boundary).abs() < .5) break;
        step = 'scroll sidebar ${towardStart ? 'up' : 'down'} ${attempt + 1}';
        final distance = (position.viewportDimension * .7).clamp(48.0, 360.0);
        await tester.timedDrag(
          list,
          Offset(0, towardStart ? distance : -distance),
          const Duration(milliseconds: 180),
        );
        await settle();
        if ((position.pixels - before).abs() < .5) break;
      }
      if (label.evaluate().isNotEmpty) break;
    }
    step = 'tap visible sidebar destination';
    expect(
      label,
      findsOneWidget,
      reason: 'Destination was not found in bounded sidebar traversal: $title',
    );
    final tile = find.ancestor(of: label, matching: find.byType(InkWell));
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await settle();
    expect(
      tile.hitTestable(),
      findsOneWidget,
      reason: 'Sidebar destination must receive the pointer: $title',
    );
    await tester.tap(tile);
    await settle();
    step = 'verify selected page';
    final section = destinations[title];
    if (section == null) {
      throw StateError('Unknown benchmark destination: $title');
    }
    expect(
      find.byKey(PageStorageKey(section)),
      findsOneWidget,
      reason: 'The actual sidebar tap must open $section',
    );
    step = 'complete';
  }

  Map<String, Object?> viewport() {
    final view = tester.view;
    final elements = workspace.evaluate();
    final size = elements.length == 1 ? tester.getSize(workspace) : null;
    final media = elements.length == 1
        ? MediaQuery.maybeOf(elements.single)
        : null;
    return {
      'physicalWidth': view.physicalSize.width,
      'physicalHeight': view.physicalSize.height,
      'devicePixelRatio': view.devicePixelRatio,
      'logicalViewWidth': view.physicalSize.width / view.devicePixelRatio,
      'logicalViewHeight': view.physicalSize.height / view.devicePixelRatio,
      'workspaceWidth': size?.width,
      'workspaceHeight': size?.height,
      'mediaQueryWidth': media?.size.width,
      'mediaQueryHeight': media?.size.height,
      'displayWidth': view.display.size.width,
      'displayHeight': view.display.size.height,
    };
  }

  Future<Map<String, Object?>> diagnose() async {
    final result = <String, Object?>{
      ...viewport(),
      'requestedDestination': requested,
      'navigationStep': step,
    };
    try {
      final state = tester.state<ScaffoldState>(scaffold);
      result['usesDrawer'] = state.widget.drawer != null;
      result['drawerOpen'] = state.isDrawerOpen;
      final list = navigationList();
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      result['sidebarScroll'] = {
        'pixels': position.pixels,
        'min': position.minScrollExtent,
        'max': position.maxScrollExtent,
        'viewport': position.viewportDimension,
      };
      result['mountedDestinations'] = [
        for (final title in destinations.keys)
          if (find
              .descendant(of: list, matching: find.text(title))
              .evaluate()
              .isNotEmpty)
            title,
      ];
      final handle = tester.ensureSemantics();
      try {
        await tester.pump();
        final nodes = <Map<String, Object?>>[];
        final root = tester.getSemantics(list);
        var visited = 0;
        void visit(SemanticsNode node) {
          if (visited++ >= 100) return;
          final data = node.getSemanticsData();
          final labels = [
            for (final title in destinations.keys)
              if (data.label.split('\n').contains(title)) title,
          ];
          if (labels.isNotEmpty) {
            nodes.add({
              'destinations': labels,
              'tappable': data.hasAction(SemanticsAction.tap),
            });
          }
          node.visitChildren((child) {
            visit(child);
            return visited < 100;
          });
        }

        visit(root);
        result['navigationSemantics'] = nodes;
        result['semanticsNodesVisited'] = visited;
      } finally {
        handle.dispose();
      }
    } catch (error) {
      result['diagnosticsErrorType'] = error.runtimeType.toString();
    }
    return result;
  }
}
