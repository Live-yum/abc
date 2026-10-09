import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'terra_contract.dart';
import 'terra_theme.dart';
import 'world_map_view.dart';
import 'world_properties_panel.dart';
import 'chest_tools_panel.dart';
import 'bestiary_tools_panel.dart';
import 'achievement_tools_panel.dart';
import 'map_markers_panel.dart';
import 'world_rules_panel.dart';
import 'circuit_edit_tools.dart';
import 'authoritative_circuit_panel.dart';
import 'named_scheme_panel.dart';
import '../domain/world_rules.dart';
import '../domain/world_rule_presets.dart';
import '../domain/map_markers.dart';
import 'catalog_browser.dart';
import 'player_tools_panel.dart';
import '../domain/player_tools.dart';
import 'world_circuit_panel.dart';
import 'region_texture_canvas.dart';
import 'region_inspector.dart';
import 'region_brush_panel.dart';
import '../domain/region_brush.dart';
import 'fusion_placement_panel.dart';
import 'cloud_workspace_panel.dart';
import 'online_resources_panel.dart';
import 'terraria_map_panel.dart';
import 'vault_history_panel.dart';
import '../platform/vault.dart';
import 'terra_painters.dart';
export 'terra_contract.dart';

class TerraForgeApp extends StatelessWidget {
  final TerraController controller;
  const TerraForgeApp({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TerraForge · 泰拉工坊',
    debugShowCheckedModeBanner: false,
    theme: terraTheme(),
    home: TerraWorkspace(controller: controller),
  );
}

class _Section {
  final String id, title, eyebrow, description;
  final IconData icon;
  const _Section(
    this.id,
    this.title,
    this.icon,
    this.eyebrow,
    this.description,
  );
}

const _sections = [
  _Section(
    'home',
    '工作台',
    Icons.space_dashboard_outlined,
    'WELCOME TO YOUR WORKSPACE',
    '面向 Terraria 玩家的世界、角色与创作工作空间。',
  ),
  _Section(
    'world',
    '世界档案',
    Icons.map_outlined,
    'WORLD ARCHIVE / WLD',
    '查看地图、世界属性和宝箱。所有更改先暂存，再验证并导出副本。',
  ),
  _Section(
    'saves',
    '存档中心',
    Icons.folder_open_outlined,
    'SAVE VAULT / LOCAL FIRST',
    '管理本次工作空间的世界、角色与创作工程。',
  ),
  _Section(
    'pixel',
    '像素工坊',
    Icons.brush_outlined,
    'PIXEL STUDIO / COLOR & ART',
    '从一个像素开始。绘画、填充、取色，将灵感变成你的作品。',
  ),
  _Section(
    'player',
    '角色实验室',
    Icons.person_outline,
    'CHARACTER LAB / PLR',
    '编辑角色属性与背包内容，原始文件保留，修改导出为新副本。',
  ),
  _Section(
    'circuit',
    '电路实验室',
    Icons.bolt_outlined,
    'CIRCUIT LAB / LOGIC & SIGNAL',
    '绘制四色线路，逐步观察信号变化，保存独立电路工程。',
  ),
  _Section(
    'fusion',
    '融合画布',
    Icons.layers_outlined,
    'FUSION CANVAS / BUILD TOGETHER',
    '在同一张可编辑画布中组合地形、建筑、墙壁和液体。',
  ),
  _Section(
    'generation',
    '世界生成',
    Icons.auto_awesome_outlined,
    'WORLD GENERATOR / YOUR NEXT ADVENTURE',
    '配置世界参数。生成能力与输出范围会在执行前明确说明。',
  ),
  _Section(
    'write',
    '写入工作流',
    Icons.output_outlined,
    'WRITE WORKFLOW / SAFE OUTPUT',
    '选择来源、定位目标、预览校验，最后生成新副本。',
  ),
  _Section(
    'codex',
    '图鉴与成就',
    Icons.menu_book_outlined,
    'GAME CODEX / DISCOVER & COLLECT',
    '搜索资料索引，管理物品标记与成就文件。',
  ),
  _Section(
    'mapping',
    '映射方案',
    Icons.tune_outlined,
    'MAPPING RULES / PALETTE & TERRAIN',
    '配置像素颜色和方块对应关系，保留可复用的创作方案。',
  ),
  _Section(
    'settings',
    '设置与资源',
    Icons.settings_outlined,
    'PREFERENCES / RESOURCES / ABOUT',
    '本地优先的工作空间，透明的文件支持范围与安全设置。',
  ),
];
const _palette = [
  0xffefbf77,
  0xffa6dbb6,
  0xff75acb4,
  0xff7aa5df,
  0xffbca0d6,
  0xffe4a7a2,
  0xffaf875f,
  0xfff5e5a8,
  0xff627a87,
  0xffffffff,
  0xff364653,
  0xff1b252f,
  0xff85c078,
  0xffc6ad94,
  0xffb6a5e2,
  0xffd27d76,
];

class TerraWorkspace extends StatefulWidget {
  final TerraController controller;
  const TerraWorkspace({super.key, required this.controller});
  @override
  State<TerraWorkspace> createState() => _TerraWorkspaceState();
}

class _TerraWorkspaceState extends State<TerraWorkspace> {
  String section = 'home',
      tool = 'brush',
      material = 'wood',
      search = '',
      filter = '全部';
  final Map<String, int> tabs = {'circuit': 3};
  final Map<String, Object?> form = {};
  int color = _palette[1], slot = 0;
  bool grid = true;
  double zoom = 1;
  final _scaffold = GlobalKey<ScaffoldState>();
  TerraViewState? _buildingView;
  bool _readingBuildView = false;
  TerraViewState get v => _readingBuildView
      ? (_buildingView ??= widget.controller.view)
      : widget.controller.view;

  Widget _withViewSnapshot(
    TerraViewState? snapshot,
    Widget Function() builder,
  ) {
    final previous = _buildingView;
    final wasReadingBuildView = _readingBuildView;
    _buildingView = snapshot;
    _readingBuildView = true;
    try {
      return builder();
    } finally {
      // Events, dialog builders and code resuming after await need live state.
      _buildingView = previous;
      _readingBuildView = wasReadingBuildView;
    }
  }

  Widget _viewLayoutBuilder({required LayoutWidgetBuilder builder}) {
    // Deferred child layouts belong to the same snapshot as their parent.
    // The root reads lazily, inside its existing layout timing measurement.
    final snapshot = _readingBuildView ? v : null;
    return LayoutBuilder(
      builder: (context, constraints) =>
          _withViewSnapshot(snapshot, () => builder(context, constraints)),
    );
  }

  _Section get selected => _sections.firstWhere((s) => s.id == section);
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant TerraWorkspace old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void go(String id) {
    if (section == 'circuit' && id != 'circuit') _pauseRulesIfRunning();
    setState(() {
      section = id;
      search = '';
      filter = '全部';
    });
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
  }

  void _pauseRulesIfRunning() {
    final rules = v.result['rulesCircuit'];
    if (rules is Map && rules['running'] == true) {
      unawaited(act('rulesPause'));
    }
  }

  Future<void> act(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      await widget.controller.dispatch(action, args);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作未完成：$e')));
      }
    }
  }

  Widget button(
    String text,
    IconData icon,
    VoidCallback? callback, {
    bool primary = false,
  }) => primary
      ? FilledButton.icon(
          onPressed: v.busy ? null : callback,
          icon: Icon(icon, size: 16),
          label: Text(text),
        )
      : OutlinedButton.icon(
          onPressed: v.busy ? null : callback,
          icon: Icon(icon, size: 16),
          label: Text(text),
        );
  Widget heading(String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        ?trailing,
      ],
    ),
  );
  Widget stack(List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
  Widget gap([double n = 16]) => SizedBox(height: n);
  Widget split(Widget main, Widget aside) => LayoutBuilder(
    builder: (context, c) => c.maxWidth < 850
        ? stack([main, gap(), aside])
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: main),
              const SizedBox(width: 18),
              SizedBox(width: 300, child: aside),
            ],
          ),
  );
  Widget tiles(List<Widget> children, {double minWidth = 240}) => LayoutBuilder(
    builder: (context, c) {
      final count = (c.maxWidth / (minWidth + 14)).floor().clamp(1, 4);
      return Wrap(
        spacing: 14,
        runSpacing: 14,
        children: children
            .map(
              (w) => SizedBox(
                width: (c.maxWidth - (count - 1) * 14) / count,
                child: w,
              ),
            )
            .toList(),
      );
    },
  );
  Widget info(String label, Object? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            '${value ?? '—'}',
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
  Widget field(
    String key,
    String label, {
    String initial = '',
    bool number = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      key: ValueKey('$section/$key'),
      initialValue: '${form[key] ?? initial}',
      keyboardType: number ? TextInputType.number : TextInputType.text,
      maxLines: lines,
      decoration: InputDecoration(labelText: label),
      onChanged: (s) => form[key] = number ? int.tryParse(s) ?? s : s,
    ),
  );
  Widget choices(
    String key,
    String label,
    List<String> values, {
    String? initial,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: stack([
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      gap(8),
      Wrap(
        spacing: 7,
        runSpacing: 7,
        children: values
            .map(
              (s) => ChoiceChip(
                label: Text(s),
                selected: (form[key] ?? initial ?? values.first) == s,
                onSelected: (_) => setState(() => form[key] = s),
              ),
            )
            .toList(),
      ),
    ]),
  );
  Widget toggle(
    String text,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
  }) => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(text, style: const TextStyle(fontSize: 12)),
    subtitle: subtitle == null
        ? null
        : Text(subtitle, style: const TextStyle(fontSize: 10)),
    value: value,
    onChanged: onChanged,
  );
  Widget tabBar(String key, List<String> labels) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(
          labels.length,
          (i) => Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(labels[i]),
              selected: (tabs[key] ?? 0) == i,
              onSelected: (_) {
                if (key == 'circuit' && (tabs[key] ?? 3) == 3 && i != 3) {
                  _pauseRulesIfRunning();
                }
                setState(() {
                  tabs[key] = i;
                  search = '';
                });
              },
            ),
          ),
        ),
      ),
    ),
  );
  Widget searchBox(String hint) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: ValueKey('search/$section/${tabs[section]}'),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 19),
        hintText: hint,
      ),
      onChanged: (s) => setState(() => search = s),
    ),
  );
  Future<void> _historyAction(bool redo) =>
      section == 'circuit' && (tabs['circuit'] ?? 3) == 3
      ? act('rulesEdit', {'method': redo ? 'redo' : 'undo', 'args': []})
      : act(redo ? 'redo' : 'undo', {'canvas': section});
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyK, control: true):
          _searchDialog,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _searchDialog,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
          _historyAction(false),
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () =>
          _historyAction(false),
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ): () =>
          _historyAction(true),
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        meta: true,
        shift: true,
      ): () =>
          _historyAction(true),
    },
    child: Focus(
      autofocus: true,
      child: _viewLayoutBuilder(
        builder: (context, c) =>
            widget.controller.hostStages.measure('workspace.layoutBuilder', () {
              final desktop = c.maxWidth >= 1000;
              return Scaffold(
                key: _scaffold,
                drawer: desktop ? null : Drawer(width: 280, child: _sidebar()),
                body: SafeArea(
                  child: Row(
                    children: [
                      if (desktop) SizedBox(width: 238, child: _sidebar()),
                      Expanded(
                        child: Column(
                          children: [
                            _topbar(desktop),
                            if (v.busy)
                              const LinearProgressIndicator(minHeight: 2),
                            Expanded(
                              child: SingleChildScrollView(
                                key: PageStorageKey(section),
                                padding: EdgeInsets.fromLTRB(
                                  desktop ? 30 : 18,
                                  desktop ? 28 : 22,
                                  desktop ? 30 : 18,
                                  36,
                                ),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 1390,
                                    ),
                                    child: stack([
                                      _pageHeading(),
                                      if (v.error.isNotEmpty)
                                        TerraNotice(
                                          v.error,
                                          warning: true,
                                          icon: Icons.error_outline,
                                        ),
                                      if (v.status.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 14,
                                          ),
                                          child: Row(
                                            children: [
                                              const Icon(
                                                Icons.info_outline,
                                                size: 15,
                                                color: TerraColors.muted,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  v.status,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      _page(),
                                    ]),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: desktop ? null : _bottomNav(),
              );
            }),
      ),
    ),
  );
  Widget _topbar(bool desktop) => Container(
    height: 66,
    decoration: const BoxDecoration(
      color: TerraColors.sidebar,
      border: Border(bottom: BorderSide(color: TerraColors.border)),
    ),
    padding: EdgeInsets.symmetric(horizontal: desktop ? 30 : 12),
    child: Row(
      children: [
        if (!desktop)
          IconButton(
            tooltip: '全部功能',
            onPressed: () => _scaffold.currentState?.openDrawer(),
            icon: const Icon(Icons.menu, size: 21),
          ),
        if (desktop) ...[
          const Text(
            '探索空间',
            style: TextStyle(fontSize: 12, color: TerraColors.muted),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.chevron_right,
              size: 16,
              color: TerraColors.muted,
            ),
          ),
        ],
        Text(
          selected.title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (desktop)
          SizedBox(
            width: 245,
            child: OutlinedButton(
              onPressed: _searchDialog,
              child: const Row(
                children: [
                  Icon(Icons.search, size: 17, color: TerraColors.muted),
                  SizedBox(width: 8),
                  Text(
                    '搜索功能、存档、物品',
                    style: TextStyle(color: TerraColors.muted, fontSize: 11),
                  ),
                  Spacer(),
                  Text(
                    '⌘ K',
                    style: TextStyle(color: TerraColors.muted, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
        if (!desktop)
          IconButton(
            tooltip: '搜索',
            onPressed: _searchDialog,
            icon: const Icon(Icons.search, size: 21),
          ),
        const SizedBox(width: 12),
        const TerraPill('本地工作空间'),
        if (desktop) ...[
          const SizedBox(width: 12),
          IconButton(
            tooltip: '设置',
            onPressed: () => go('settings'),
            icon: const Icon(Icons.settings_outlined, size: 20),
          ),
        ],
      ],
    ),
  );
  Widget _sidebar() => Container(
    decoration: const BoxDecoration(
      color: TerraColors.sidebar,
      border: Border(right: BorderSide(color: TerraColors.border)),
    ),
    child: Column(
      children: [
        Container(
          height: 94,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: TerraColors.border)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xffb5eac7), Color(0xff74b9a2)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.handyman_outlined,
                  color: Color(0xff15362a),
                  size: 25,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TerraForge',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.5,
                        ),
                      ),
                      Text(
                        'STUDIO FOR TERRARIA',
                        style: TextStyle(
                          fontSize: 8.5,
                          letterSpacing: 1.1,
                          color: TerraColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (var i = 0; i < _sections.length; i++) ...[
                if (i == 0 || i == 3 || i == 9)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(13, 16, 0, 9),
                    child: Text(
                      i == 0
                          ? '我的工作空间'
                          : i == 3
                          ? '创作与编辑'
                          : '资料与工具',
                      style: const TextStyle(
                        color: Color(0xff738f93),
                        fontSize: 10,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                _nav(_sections[i]),
              ],
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: TerraColors.border)),
          ),
          child: const Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: Color(0xff29443e),
                child: Icon(
                  Icons.shield_outlined,
                  size: 19,
                  color: TerraColors.mint,
                ),
              ),
              SizedBox(width: 11),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '你的创作空间',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '本地优先 · 原件保护',
                    style: TextStyle(fontSize: 10, color: TerraColors.muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _nav(_Section s) {
    final active = section == s.id;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: active ? const Color(0xff243e37) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => go(s.id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              border: active
                  ? const Border(
                      left: BorderSide(color: TerraColors.mint, width: 2),
                    )
                  : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  s.icon,
                  size: 19,
                  color: active ? TerraColors.mint : TerraColors.muted,
                ),
                const SizedBox(width: 12),
                Text(
                  s.title,
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? TerraColors.mint : const Color(0xff9cadb1),
                    fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
                if (s.id == 'fusion') ...[
                  const Spacer(),
                  const Text(
                    'BETA',
                    style: TextStyle(fontSize: 9, color: Color(0xff6fa995)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomNav() {
    const ids = ['home', 'world', 'pixel', 'saves', 'more'];
    final ix = ids.indexOf(section);
    return NavigationBar(
      height: 67,
      selectedIndex: ix < 0 ? 4 : ix,
      onDestinationSelected: (i) =>
          i == 4 ? _scaffold.currentState?.openDrawer() : go(ids[i]),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.space_dashboard_outlined),
          label: '工作台',
        ),
        NavigationDestination(icon: Icon(Icons.map_outlined), label: '世界'),
        NavigationDestination(icon: Icon(Icons.brush_outlined), label: '创作'),
        NavigationDestination(
          icon: Icon(Icons.folder_open_outlined),
          label: '存档',
        ),
        NavigationDestination(
          icon: Icon(Icons.grid_view_outlined),
          label: '更多',
        ),
      ],
    );
  }

  Widget _pageHeading() => Padding(
    padding: const EdgeInsets.only(bottom: 23),
    child: _viewLayoutBuilder(
      builder: (context, c) {
        final copy = stack([
          Text(
            selected.eyebrow,
            style: const TextStyle(
              color: TerraColors.mint,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.7,
            ),
          ),
          gap(9),
          Text(
            section == 'home' ? '把每一次冒险，变成你的作品' : selected.title,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          gap(8),
          Text(
            selected.description,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]);
        return c.maxWidth < 800
            ? stack([copy, gap(18), _actions()])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: copy),
                  const SizedBox(width: 20),
                  _actions(),
                ],
              );
      },
    ),
  );
  Widget _actions() {
    final List<Widget> actions = [];
    switch (section) {
      case 'home':
      case 'saves':
        actions.add(
          button(
            '导入存档',
            Icons.file_upload_outlined,
            _importDialog,
            primary: true,
          ),
        );
        actions.add(button('新建项目', Icons.add, _newDialog));
        break;
      case 'pixel':
        actions.add(
          button(
            '导入图片',
            Icons.image_outlined,
            () => act('import', {'kind': 'image'}),
          ),
        );
        actions.add(
          button(
            '导出 PNG',
            Icons.download_outlined,
            () => act('export', {'kind': 'pixelPng'}),
            primary: true,
          ),
        );
        break;
      case 'world':
        actions.add(
          button(
            '导入 WLD',
            Icons.file_upload_outlined,
            () => act('import', {'kind': 'world'}),
          ),
        );
        actions.add(
          button(
            '导出地图',
            Icons.image_outlined,
            v.world.isEmpty ? null : () => act('export', {'kind': 'mapPng'}),
            primary: true,
          ),
        );
        break;
      case 'player':
        actions.add(
          button(
            '导入 PLR',
            Icons.file_upload_outlined,
            () => act('import', {'kind': 'player'}),
          ),
        );
        actions.add(
          button(
            '导出副本',
            Icons.download_outlined,
            v.player.isEmpty ? null : () => act('export', {'kind': 'player'}),
            primary: true,
          ),
        );
        break;
      case 'fusion':
      case 'circuit':
        actions.add(
          button(
            '载入工程',
            Icons.file_upload_outlined,
            () => act('import', {'kind': 'project'}),
          ),
        );
        actions.add(
          button(
            '导出工程',
            Icons.download_outlined,
            () => act('export', {'kind': '${section}Project'}),
            primary: true,
          ),
        );
        break;
      case 'write':
        actions.add(
          button(
            '选择目标 WLD',
            Icons.file_upload_outlined,
            () => act('import', {'kind': 'world'}),
          ),
        );
        break;
      case 'mapping':
        actions.add(
          button(
            '导出方案',
            Icons.download_outlined,
            () => act('export', {'kind': 'mapping'}),
          ),
        );
        break;
      default:
        actions.add(const TerraPill('LOCAL FIRST'));
    }
    return Wrap(spacing: 9, runSpacing: 9, children: actions);
  }

  Widget _page() => switch (section) {
    'home' => _home(),
    'world' => _world(),
    'pixel' => _editor('pixel'),
    'player' => _player(),
    'circuit' => _editor('circuit'),
    'fusion' => _editor('fusion'),
    'generation' => _generation(),
    'write' => _write(),
    'saves' => _saves(),
    'codex' => _codex(),
    'mapping' => _mapping(),
    'settings' => _settings(),
    _ => const SizedBox(),
  };
  Widget _home() => stack([
    const TerraNotice('安全编辑：原件保持不变。修改先暂存，经过校验后再导出新副本。'),
    ClipRRect(
      borderRadius: BorderRadius.circular(17),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xff244239), Color(0xff17252a)],
          ),
          border: Border.all(color: const Color(0xff46645b)),
          borderRadius: BorderRadius.circular(17),
        ),
        child: _viewLayoutBuilder(
          builder: (context, c) {
            final text = Padding(
              padding: const EdgeInsets.all(28),
              child: stack([
                const Text(
                  'YOUR NEXT CREATION STARTS HERE',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: TerraColors.mint,
                    letterSpacing: 1.6,
                  ),
                ),
                gap(15),
                Text(
                  v.world.isEmpty
                      ? '让想象，在这里生长。'
                      : '继续探索你的\n「${v.world['name'] ?? '世界'}」',
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                    letterSpacing: -.7,
                  ),
                ),
                gap(11),
                Text(
                  v.world.isEmpty
                      ? '打开一份存档，或创造一幅像素画。\n属于你的下一个世界，从一个灵感开始。'
                      : '你的世界已载入工作空间。继续查看、编辑或导出。',
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.75,
                    color: Color(0xffc4d7ce),
                  ),
                ),
                gap(21),
                Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: [
                    button(
                      v.world.isEmpty ? '打开世界' : '继续编辑',
                      Icons.map_outlined,
                      () => v.world.isEmpty
                          ? act('import', {'kind': 'world'})
                          : go('world'),
                      primary: true,
                    ),
                    button('创作像素画', Icons.brush_outlined, () => go('pixel')),
                  ],
                ),
              ]),
            );
            final art = Stack(
              children: [
                const Positioned.fill(
                  child: CustomPaint(painter: LandscapePainter()),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xff244239).withValues(alpha: .5),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
                const Positioned(
                  right: 12,
                  bottom: 10,
                  child: Text(
                    '原创场景插画 · 非存档预览',
                    style: TextStyle(fontSize: 9, color: Color(0xffc4d7ce)),
                  ),
                ),
              ],
            );
            return c.maxWidth < 600
                ? stack([text, SizedBox(height: 150, child: art)])
                : IntrinsicHeight(
                    child: Row(
                      children: [
                        Expanded(flex: 11, child: text),
                        Expanded(flex: 10, child: art),
                      ],
                    ),
                  );
          },
        ),
      ),
    ),
    gap(),
    tiles([
      _stat(
        '本地文件',
        v.files.length,
        Icons.folder_open_outlined,
        TerraColors.mint,
        '本次工作空间',
      ),
      _stat(
        '世界档案',
        v.files.where((f) => f.kind == 'world' || f.kind == 'wld').length,
        Icons.map_outlined,
        TerraColors.mint,
        v.world.isEmpty ? '等待导入' : '已载入',
      ),
      _stat(
        '角色档案',
        v.files.where((f) => f.kind == 'player' || f.kind == 'plr').length,
        Icons.person_outline,
        TerraColors.blue,
        v.player.isEmpty ? '等待导入' : '已载入',
      ),
      _stat(
        '会话操作记录',
        v.stagedCount,
        Icons.layers_outlined,
        TerraColors.amber,
        '验证后导出副本',
      ),
    ], minWidth: 180),
    heading(
      '开始创作',
      trailing: TextButton(
        onPressed: _allTools,
        child: const Text('查看全部功能 →', style: TextStyle(fontSize: 11)),
      ),
    ),
    tiles(
      _sections
          .where(
            (s) => [
              'world',
              'pixel',
              'player',
              'circuit',
              'fusion',
              'generation',
            ].contains(s.id),
          )
          .map((s) => _module(s))
          .toList(),
      minWidth: 290,
    ),
    split(
      stack([
        heading(
          '最近打开',
          trailing: TextButton(
            onPressed: () => go('saves'),
            child: const Text('管理存档 →', style: TextStyle(fontSize: 11)),
          ),
        ),
        TerraPanel(
          child: v.files.isEmpty
              ? const TerraEmpty('还没有打开文件', '导入 WLD、PLR 或工程文件，开始你的创作。')
              : stack(v.files.take(5).map(_fileRow).toList()),
        ),
      ]),
      stack([
        heading('工作进度'),
        TerraPanel(
          child: stack([
            const Text(
              '安全编辑工作流',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            gap(12),
            info('文件导入', v.files.isEmpty ? '等待操作' : '${v.files.length} 个文件'),
            info('会话操作记录', '${v.stagedCount} 项'),
            info(
              '输出状态',
              v.result['validation'] ??
                  (v.result['validated'] == true ? '已回读校验' : '尚未执行校验'),
            ),
            gap(8),
            button('查看写入工作流', Icons.arrow_forward, () => go('write')),
          ]),
        ),
      ]),
    ),
  ]);
  Widget _stat(
    String label,
    int value,
    IconData icon,
    Color tint,
    String subtitle,
  ) => TerraPanel(
    padding: const EdgeInsets.all(17),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: tint.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: tint),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: stack([
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(
              value.toString().padLeft(2, '0'),
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
            ),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 9.5, color: TerraColors.muted),
            ),
          ]),
        ),
      ],
    ),
  );
  Widget _module(_Section s) => Material(
    color: TerraColors.card,
    borderRadius: BorderRadius.circular(13),
    child: InkWell(
      onTap: () => go(s.id),
      borderRadius: BorderRadius.circular(13),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          border: Border.all(color: TerraColors.border),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xff29443e),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(s.icon, color: TerraColors.mint, size: 22),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: stack([
                Text(
                  s.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                gap(4),
                Text(
                  s.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: TerraColors.muted,
                    height: 1.5,
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward, size: 16, color: Color(0xff6fa995)),
          ],
        ),
      ),
    ),
  );
  Widget _fileRow(TerraFile f) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xff263b39),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(
        f.kind == 'player' || f.kind == 'plr'
            ? Icons.person_outline
            : Icons.insert_drive_file_outlined,
        color: TerraColors.mint,
        size: 20,
      ),
    ),
    title: Text(
      f.name,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(
      f.detail.isEmpty ? f.kind : f.detail,
      style: const TextStyle(fontSize: 10, color: TerraColors.muted),
    ),
    trailing: const Icon(Icons.chevron_right, size: 17),
    onTap: () {
      act('openFile', {'id': f.id});
      if (f.kind == 'worldRules') tabs['mapping'] = 2;
      if (f.kind == 'markers') tabs['codex'] = 1;
      if (f.kind == 'achievements') tabs['codex'] = 3;
      if (f.kind == 'resources' || f.kind == 'catalog') tabs['codex'] = 0;
      go(
        f.kind == 'player' || f.kind == 'plr'
            ? 'player'
            : f.kind == 'world' || f.kind == 'wld'
            ? 'world'
            : _artifactSection(f.kind),
      );
    },
  );
  Widget _world() => stack([
    if (v.world['readOnly'] == true)
      const TerraNotice('此世界版本仅支持只读查看和原字节导出，编辑已受引擎保护。', warning: true),
    tabBar('world', ['地图与基本信息', '宝箱编辑', '怪物图鉴', '物品标记', '变更与处理', 'MAP 探索存档']),
    if (tabs['world'] == 5)
      SizedBox(
        height: 820,
        child: TerrariaMapPanel(
          session: v.map,
          raster: v.mapRaster,
          busy: v.busy,
          canGenerateWorldMap: v.canGenerateWorldMap,
          onAction: (action, args) => act(action, args),
        ),
      )
    else if (v.world.isEmpty)
      TerraPanel(
        child: TerraEmpty(
          '打开你的第一个世界',
          '选择 WLD 文件。只有完成真实解析后，世界信息才会显示。',
          icon: Icons.public,
          action: button(
            '选择 WLD 文件',
            Icons.file_upload_outlined,
            () => act('import', {'kind': 'world'}),
            primary: true,
          ),
        ),
      )
    else
      switch (tabs['world'] ?? 0) {
        0 => split(
          stack([
            _worldMap(),
            heading('图层与定位'),
            TerraPanel(
              child: stack([
                toggle(
                  '显示宝箱与自定义标记',
                  v.result['markersVisible'] == true,
                  (b) => act('markerVisibility', {'visible': b}),
                ),
                const Text('电线与液体：在地图上方按需读取当前视口，再选择图层。'),
                gap(8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    button('前往坐标', Icons.my_location, _coordinateDialog),
                    button('标记物品', Icons.menu_book_outlined, () => go('codex')),
                  ],
                ),
              ]),
            ),
          ]),
          _worldInspector(),
        ),
        1 => _chests(),
        2 => _bestiaryPanel(),
        3 => split(_worldMap(), TerraPanel(child: _markerTools())),
        _ => _changes(),
      },
  ]);
  Widget _markerTools() => stack([
    MapMarkersPanel(
      profile: v.markerProfile ?? MapMarkerProfile(),
      catalog: v.resources?.catalog,
      busy: v.busy,
      hasWorld: v.world.isNotEmpty,
      onAction: (action, args) => act(action, args),
    ),
    gap(10),
    button(
      '导出标记方案',
      Icons.download_outlined,
      () => act('export', {'kind': 'markers'}),
    ),
  ]);

  List<Offset> _chestMarkerPositions() {
    final selected = (v.result['markers'] as List?) ?? const [],
        chests = (v.world['chests'] as List?) ?? const [];
    return chests
        .whereType<Map>()
        .where(
          (c) =>
              selected.isEmpty ||
              (c['items'] as List? ?? const []).whereType<Map>().any(
                (i) => selected.contains(i['itemType']),
              ),
        )
        .map(
          (c) => Offset((c['x'] as num).toDouble(), (c['y'] as num).toDouble()),
        )
        .toList();
  }

  Widget _worldMap() => TerraPanel(
    padding: EdgeInsets.zero,
    child: stack([
      ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
        child: v.worldPreview != null
            ? WorldMapView(
                png: v.worldPreview!,
                overlay: v.worldOverlay,
                overlayBusy: v.busy,
                onLoadOverlay: (x, y, width, height) => act('worldOverlay', {
                  'x': x,
                  'y': y,
                  'width': width,
                  'height': height,
                }),
                worldWidth: (v.world['maxTilesX'] as num?)?.toInt() ?? 1,
                worldHeight: (v.world['maxTilesY'] as num?)?.toInt() ?? 1,
                location: v.result['location'] is Map
                    ? Offset(
                        ((v.result['location'] as Map)['x'] as num).toDouble(),
                        ((v.result['location'] as Map)['y'] as num).toDouble(),
                      )
                    : null,
                markers:
                    v.result['markersVisible'] == true &&
                        (v.markerProfile?.isEmpty ?? true)
                    ? _chestMarkerPositions()
                    : const [],
                onLocate: (x, y) => act('locate', {'x': x, 'y': y}),
              )
            : Container(
                color: const Color(0xff101e26),
                child: const TerraEmpty(
                  '地图预览尚不可用',
                  '需要成功解析世界地块后才能生成真实地图。',
                  icon: Icons.map_outlined,
                ),
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(17),
        child: Row(
          children: [
            Expanded(
              child: stack([
                Text(
                  '${v.world['name'] ?? '未打开世界'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${v.world['width'] ?? v.world['maxTilesX'] ?? '—'} × ${v.world['height'] ?? v.world['maxTilesY'] ?? '—'} · ${v.world['version'] ?? '未知版本'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
            const TerraPill('原件保护'),
          ],
        ),
      ),
    ]),
  );
  Widget _worldInspector() => TerraPanel(
    child: stack([
      Row(
        children: [
          const Expanded(
            child: Text('世界属性', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          TerraPill('${v.stagedCount} 条会话记录', color: TerraColors.amber),
        ],
      ),
      gap(),
      WorldPropertiesPanel(
        world: v.world,
        busy: v.busy,
        onEdit: (field, value) =>
            act('stageWorld', {'field': field, 'value': value}),
      ),
      const Divider(),
      info(
        '世界大小',
        '${v.world['width'] ?? v.world['maxTilesX'] ?? '—'} × ${v.world['height'] ?? v.world['maxTilesY'] ?? '—'}',
      ),
      const TerraNotice('修改经回读校验后进入内存版本。下方是会话操作日志，撤销不会删除日志；导出生成新文件。'),
      button(
        '查看会话操作记录',
        Icons.fact_check_outlined,
        () => setState(() => tabs['world'] = 4),
        primary: true,
      ),
    ]),
  );
  Widget _chests() => TerraPanel(
    child: ChestToolsPanel(
      chests: [
        for (final raw in v.world['chests'] as List? ?? const [])
          Map<String, Object?>.from(raw as Map),
      ],
      busy: v.busy,
      readOnly: v.world['readOnly'] == true,
      catalog: v.resources?.catalog,
      verifiedRules: v.result['chestRulesVerified'] == true,
      worldVersion: (v.world['version'] as num?)?.toInt() ?? 0,
      modifiedIndices: Set<int>.from(
        v.result['modifiedChests'] as List? ?? const [],
      ),
      onAction: (action, args) => act(action, args),
    ),
  );

  Widget _changes() => split(
    TerraPanel(
      child: stack([
        const Text('会话操作记录', style: TextStyle(fontWeight: FontWeight.w700)),
        gap(),
        const TerraNotice('暂存 → 验证 → 生成候选 → 回读校验 → 导出副本'),
        if (v.changes.isEmpty)
          const TerraEmpty('还没有暂存修改', '在世界属性或宝箱中编辑，修改会出现在这里。'),
        for (final c in v.changes)
          info(
            '${c['field'] ?? c['action'] ?? c['operation'] ?? '修改'}',
            c['value'] ?? c['description'] ?? c['fields'],
          ),
        gap(),
        button(
          '校验会话操作记录',
          Icons.fact_check_outlined,
          () => act('validate', {'source': 'world'}),
          primary: true,
        ),
        gap(10),
        button(
          '导出世界副本',
          Icons.download_outlined,
          () => act('export', {'kind': 'world'}),
        ),
      ]),
    ),
    TerraPanel(
      child: stack([
        const Text('处理与恢复', style: TextStyle(fontWeight: FontWeight.w700)),
        gap(),
        info('会话日志', v.stagedCount),
        info('当前世界', v.result['worldModified'] == true ? '已修改' : '未修改'),
        info(
          '验证状态',
          v.result['validation'] ??
              (v.result['validated'] == true ? '已回读校验' : '未执行'),
        ),
        gap(),
        button(
          '撤销修改',
          Icons.undo,
          v.result['worldCanUndo'] == true
              ? () => act('undo', {'canvas': 'world'})
              : null,
        ),
        gap(10),
        button('管理映射规则', Icons.tune, () => go('mapping')),
      ]),
    ),
  );
  Widget _editor(String kind) {
    final data = v.canvases[kind];
    final circuit = kind == 'circuit', fusion = kind == 'fusion';
    if (circuit && (tabs['circuit'] ?? 3) == 3) {
      return stack([
        tabBar('circuit', ['电路沙盒', '信号观察', '世界电路', '完整电路工坊']),
        AuthoritativeCircuitPanel(
          state: Map<String, Object?>.from(
            v.result['rulesCircuit'] as Map? ?? const {},
          ),
          resources: v.resources,
          onAction: (action, args) => act(action, args),
        ),
      ]);
    }
    if (circuit && (tabs['circuit'] ?? 0) == 2) {
      return stack([
        tabBar('circuit', ['电路沙盒', '信号观察', '世界电路', '完整电路工坊']),
        WorldCircuitPanel(
          hostStages: widget.controller.hostStages,
          state: Map<String, Object?>.from(
            v.result['worldCircuit'] as Map? ?? const {},
          ),
          dispatch: (a, b) async {
            await act(a, b);
            if (a == 'worldCircuitExtract' && v.error.isEmpty && mounted) {
              go('fusion');
            }
          },
        ),
      ]);
    }
    return stack([
      if (circuit) tabBar('circuit', ['电路沙盒', '信号观察', '世界电路', '完整电路工坊']),
      TerraPanel(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 5,
          runSpacing: 7,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final t in [
              if (fusion) ('select', '检查/平移', Icons.touch_app_outlined),
              ('brush', circuit ? '布线' : '画笔', Icons.edit_outlined),
              ('eraser', '橡皮', Icons.auto_fix_normal),
              if (!circuit) ('bucket', '填充', Icons.format_color_fill),
              if (circuit) ('trigger', '触发开关', Icons.touch_app_outlined),
              ('pick', '取色', Icons.colorize),
            ])
              ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(t.$3, size: 15),
                    const SizedBox(width: 6),
                    Text(t.$2),
                  ],
                ),
                selected: tool == t.$1,
                onSelected: (_) => setState(() => tool = t.$1),
              ),
            IconButton(
              tooltip: '撤销',
              onPressed: v.canUndo ? () => act('undo', {'canvas': kind}) : null,
              icon: const Icon(Icons.undo, size: 19),
            ),
            IconButton(
              tooltip: '重做',
              onPressed: v.canRedo ? () => act('redo', {'canvas': kind}) : null,
              icon: const Icon(Icons.redo, size: 19),
            ),
            button('尺寸', Icons.crop_free, () => _resizeDialog(kind)),
            if (circuit)
              button(
                v.circuitRunning ? '暂停' : '运行',
                v.circuitRunning ? Icons.pause : Icons.play_arrow,
                () => act('circuitToggle'),
                primary: true,
              ),
            if (circuit)
              button('单步', Icons.skip_next, () => act('circuitStep')),
            if (!circuit)
              button(
                '写入世界',
                Icons.output_outlined,
                () => go('write'),
                primary: true,
              ),
          ],
        ),
      ),
      gap(),
      split(
        stack([
          TerraPanel(
            padding: const EdgeInsets.all(16),
            child: stack([
              Row(
                children: [
                  Text(
                    circuit
                        ? 'CIRCUIT SANDBOX'
                        : fusion
                        ? 'LIVE FUSION CANVAS'
                        : 'LIVE PIXEL CANVAS',
                    style: const TextStyle(
                      fontSize: 9,
                      letterSpacing: 1.8,
                      color: TerraColors.muted,
                    ),
                  ),
                  const Spacer(),
                  TerraPill(
                    data == null ? '空画布' : '${data.width} × ${data.height}',
                    color: TerraColors.blue,
                  ),
                ],
              ),
              gap(18),
              if (data == null)
                TerraEmpty(
                  '创建一张属于你的画布',
                  fusion
                      ? '从空白网格开始组合材质与建筑。'
                      : circuit
                      ? '建立空白电路网格，绘制你的第一条线路。'
                      : '新建像素画布，或导入图片开始创作。',
                  icon: Icons.grid_on_outlined,
                  action: button(
                    '新建画布',
                    Icons.add,
                    () => _resizeDialog(kind),
                    primary: true,
                  ),
                )
              else if (fusion && v.region != null)
                SizedBox(
                  height: 520,
                  child: RegionTextureCanvas(
                    region: v.region!,
                    resources: v.resources,
                    selection: v.result['regionTile'] is Map
                        ? Offset(
                            ((v.result['regionTile'] as Map)['x'] as num)
                                .toDouble(),
                            ((v.result['regionTile'] as Map)['y'] as num)
                                .toDouble(),
                          )
                        : null,
                    drawMode: tool == 'brush' || tool == 'eraser',
                    onTap: (x, y) => act('regionSelect', {'x': x, 'y': y}),
                    onStrokeStart: () =>
                        act('strokeStart', {'canvas': 'fusion'}),
                    onStrokeEnd: () => act('strokeEnd', {'canvas': 'fusion'}),
                    onDraw: (x, y) => act('paint', {
                      'canvas': 'fusion',
                      'x': x,
                      'y': y,
                      'tool': tool,
                      'material': material,
                    }),
                  ),
                )
              else
                GridCanvas(
                  data: data,
                  grid: grid,
                  zoom: zoom,
                  circuitCells: circuit && v.result['circuitCells'] is List
                      ? (v.result['circuitCells'] as List)
                            .whereType<Map>()
                            .map((e) => Map<String, Object?>.from(e))
                            .toList()
                      : const [],
                  trace: circuit && v.result['circuitTrace'] is List
                      ? (v.result['circuitTrace'] as List)
                            .whereType<int>()
                            .toSet()
                      : const {},
                  onStart: () => act('strokeStart', {'canvas': kind}),
                  onEnd: () => act('strokeEnd', {'canvas': kind}),
                  onPoint: (x, y) {
                    if (circuit && tool == 'trigger') {
                      act('circuitTrigger', {'x': x, 'y': y});
                      return;
                    }
                    if (circuit && tool.startsWith('component:')) {
                      act('circuitPlace', {
                        'x': x,
                        'y': y,
                        'element': tool.substring(10),
                        'interval': 60,
                      });
                      return;
                    }
                    if (tool == 'pick') {
                      final i = y * data.width + x;
                      if (i < data.colors.length) {
                        setState(() => color = data.colors[i]);
                      }
                      return;
                    }
                    act('paint', {
                      'canvas': kind,
                      'x': x,
                      'y': y,
                      'color': color,
                      'tool': tool,
                      'material': material,
                      if (circuit)
                        'wireColor': [
                          0xffed796f,
                          0xff75acdf,
                          0xff7ecf97,
                          0xffead16c,
                        ].indexOf(color).clamp(0, 3),
                    });
                  },
                ),
              gap(16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '拖动绘制 · ${grid ? '网格已显示' : '网格已隐藏'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (circuit)
                    TerraPill(
                      'Tick ${v.circuitTick}',
                      color: TerraColors.amber,
                    ),
                  if (data != null)
                    Text(
                      '${data.width} × ${data.height} px',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ]),
          ),
          gap(),
          if (circuit)
            TerraNotice(
              '${v.circuitRunning ? '正在运行' : '已暂停'} · 独立组件沙盒，非完整世界电路仿真。开关、灯、计时器与逻辑门使用实际模拟器运行。',
              icon: Icons.bolt_outlined,
            ),
          if (circuit && (tabs['circuit'] ?? 0) == 1)
            TerraPanel(
              child: stack([
                const Text(
                  '实时信号轨迹',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                gap(12),
                info('模拟 Tick', v.circuitTick),
                info(
                  '本次传播节点',
                  v.result['circuitTrace'] is List
                      ? (v.result['circuitTrace'] as List).length
                      : 0,
                ),
                Text(
                  '${v.result['circuitTrace'] ?? '尚未触发信号'}',
                  style: const TextStyle(
                    color: TerraColors.muted,
                    fontSize: 11,
                  ),
                ),
              ]),
            ),
          if (circuit && (tabs['circuit'] ?? 0) == 1) gap(),
          if (circuit && v.result['circuitEditor'] is Map)
            CircuitEditTools(
              state: Map<String, Object?>.from(
                v.result['circuitEditor'] as Map,
              ),
              disabled: v.busy,
              onAction: (action, args) => act(action, args),
            ),
          tiles([
            _smallAction('映射方案', '配置颜色与材质对应', Icons.tune, () => go('mapping')),
            _smallAction(
              '保存工程',
              '保留画布中的编辑数据',
              Icons.save_outlined,
              () => act('export', {'kind': '${kind}Project'}),
            ),
          ], minWidth: 210),
        ]),
        stack([
          TerraPanel(
            child: stack([
              const Text(
                '调色与绘画',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              gap(17),
              Row(
                children: [
                  Container(
                    width: 35,
                    height: 35,
                    decoration: BoxDecoration(
                      color: Color(color),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '#${color.toRadixString(16).substring(2).toUpperCase()}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              gap(17),
              Wrap(
                spacing: 9,
                runSpacing: 9,
                children:
                    (circuit
                            ? [0xffed796f, 0xff75acdf, 0xff7ecf97, 0xffead16c]
                            : _palette)
                        .map(
                          (c) => Tooltip(
                            message: '#${c.toRadixString(16).substring(2)}',
                            child: InkWell(
                              onTap: () => setState(() => color = c),
                              borderRadius: BorderRadius.circular(7),
                              child: Container(
                                width: 29,
                                height: 29,
                                decoration: BoxDecoration(
                                  color: Color(c),
                                  borderRadius: BorderRadius.circular(7),
                                  border: Border.all(
                                    color: color == c
                                        ? Colors.white
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
              ),
              gap(12),
              if (circuit) ...[
                const Divider(),
                const Text(
                  '放置组件',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                gap(10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final component in const [
                      ('switchInput', '开关'),
                      ('lamp', '灯'),
                      ('timer', '计时器'),
                      ('andGate', 'AND'),
                      ('orGate', 'OR'),
                      ('xorGate', 'XOR'),
                    ])
                      ChoiceChip(
                        label: Text(component.$2),
                        selected: tool == 'component:${component.$1}',
                        onSelected: (_) =>
                            setState(() => tool = 'component:${component.$1}'),
                      ),
                  ],
                ),
                gap(12),
                const Text(
                  '选择组件后点击网格放置。使用“触发开关”工具激活，再单步或连续运行观察信号。',
                  style: TextStyle(
                    fontSize: 10,
                    color: TerraColors.muted,
                    height: 1.6,
                  ),
                ),
              ],
              toggle('显示像素网格', grid, (b) => setState(() => grid = b)),
              if (fusion) ...[
                const Divider(),
                const Text(
                  '建筑材质',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                gap(10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final m in const [
                      ('wood', '木块 · 30'),
                      ('stone', '石块 · 1'),
                      ('dirt', '泥土 · 0'),
                      ('wall', '石墙 · 1'),
                      ('air', '清除方块'),
                    ])
                      ChoiceChip(
                        label: Text(m.$2),
                        selected:
                            material == m.$1 && v.result['regionBrush'] == null,
                        onSelected: (_) async {
                          await act('regionBrushClear');
                          if (mounted) setState(() => material = m.$1);
                        },
                      ),
                  ],
                ),
                gap(14),
                const TerraNotice(
                  '空白画布使用普通材质；导入世界区域后可编辑完整图层。物件复制携带容器/实体数据，结构破坏和冲突由核心拒绝。',
                  warning: true,
                ),
                button('导入世界区域', Icons.crop, _fusionRegionDialog),
                if (v.region != null) ...[
                  const Divider(),
                  if (v.result['regionCompanionWarning'] != null)
                    TerraNotice(
                      '${v.result['regionCompanionWarning']}',
                      warning: true,
                    ),
                  RegionInspector(
                    tile: v.result['regionTile'] is Map
                        ? Map<String, int>.from(v.result['regionTile'] as Map)
                        : null,
                    onChanged: (patch) => act('regionEdit', {'patch': patch}),
                  ),
                  RegionBrushPanel(
                    brush: v.result['regionBrush'] is Map
                        ? RegionBrush.fromIntent(
                            Map<String, Object?>.from(
                              v.result['regionBrush'] as Map,
                            ),
                          )
                        : null,
                    catalog: v.resources?.catalog,
                    busy: v.busy || v.result['fusionPlacement'] != null,
                    readOnly: v.world['readOnly'] == true,
                    onAction: (action, args) async {
                      await act(action, args);
                      if (mounted) setState(() => tool = 'brush');
                    },
                  ),
                  FusionPlacementPanel(
                    catalog: v.resources?.catalog,
                    document: v.region,
                    x: (v.result['regionTile'] as Map?)?['x'] as int? ?? 0,
                    y: (v.result['regionTile'] as Map?)?['y'] as int? ?? 0,
                    worldVersion: v.world['version'] as int? ?? 0,
                    busy: v.busy || v.result['fusionPlacement'] != null,
                    readOnly: v.world['readOnly'] == true,
                    onAction: (action, args) => act(action, args),
                  ),
                  if (v.result['fusionPlacement'] is Map) ...[
                    Text(
                      '新物件 ${((v.result['fusionPlacement'] as Map)['width'])} × ${((v.result['fusionPlacement'] as Map)['height'])}，目标 ${((v.result['fusionPlacement'] as Map)['x'])}, ${((v.result['fusionPlacement'] as Map)['y'])}',
                    ),
                    if ((v.result['fusionPlacement'] as Map)['stale'] == true)
                      const Text('世界或选区已变化；请取消后重新放置。'),
                    button(
                      '确认插入新物件',
                      Icons.add_box_outlined,
                      v.busy ||
                              (v.result['fusionPlacement'] as Map)['stale'] ==
                                  true
                          ? null
                          : () => act('fusionInsert', {'confirmed': true}),
                    ),
                    button(
                      '取消待插入物件',
                      Icons.close,
                      v.busy ? null : () => act('fusionDiscardPlacement'),
                    ),
                  ],
                  button(
                    '应用编辑回原区域',
                    Icons.save_outlined,
                    () => _confirm(
                      '应用原区域编辑？',
                      '将替换选区各图层，核心保留并验证物件数据；原文件保持不变。',
                      () => act('write', {
                        'source': 'fusion',
                        'x': v.region!.sourceX,
                        'y': v.region!.sourceY,
                        'mode': 'replace',
                        'overwrite': true,
                      }),
                    ),
                  ),
                ],
              ],
              const Divider(),
              button(
                '自定义颜色',
                Icons.palette_outlined,
                () => _editValue(
                  '十六进制颜色',
                  '#${color.toRadixString(16).substring(2)}',
                  (s) {
                    final hex = s.replaceAll('#', '');
                    final parsed = int.tryParse(hex, radix: 16);
                    if (parsed != null) {
                      setState(() => color = 0xff000000 | parsed);
                    }
                  },
                ),
              ),
              gap(10),
              button(
                '清空画布',
                Icons.restart_alt,
                () => _confirm(
                  '清空当前画布？',
                  '此操作会清除当前画布内容。可用撤销恢复。',
                  () => act('clear', {'canvas': kind}),
                ),
              ),
            ]),
          ),
          gap(),
          TerraPanel(
            child: stack([
              const Text('作品管理', style: TextStyle(fontWeight: FontWeight.w700)),
              gap(15),
              button(
                '导出工程 JSON',
                Icons.data_object,
                () => act('export', {'kind': '${kind}Project'}),
              ),
              gap(10),
              if (kind == 'pixel')
                button(
                  '匹配真实资源颜色',
                  Icons.palette_outlined,
                  () => act('pixelMatch', {'flags': 8}),
                ),
              if (kind == 'pixel')
                button(
                  '导出 PNG',
                  Icons.image_outlined,
                  () => act('export', {'kind': 'pixelPng'}),
                  primary: true,
                ),
              gap(10),
              const Text(
                '工程与图片是创作文件。写入游戏存档前需单独验证兼容性。',
                style: TextStyle(
                  fontSize: 10,
                  color: TerraColors.muted,
                  height: 1.6,
                ),
              ),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _smallAction(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback callback,
  ) => InkWell(
    onTap: callback,
    borderRadius: BorderRadius.circular(12),
    child: TerraPanel(
      padding: const EdgeInsets.all(15),
      child: Row(
        children: [
          Icon(icon, size: 22, color: TerraColors.mint),
          const SizedBox(width: 12),
          Expanded(
            child: stack([
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ],
      ),
    ),
  );
  Widget _player() => stack([
    if ((v.player['version'] as num? ?? 0) > 326)
      const TerraNotice('此角色版本超出当前编辑范围；仅允许查看和原字节导出。', warning: true),
    if (v.player.isEmpty)
      TerraPanel(
        child: TerraEmpty(
          '角色实验室，等待一位探险者',
          '导入 PLR 读取角色信息，或新建引擎支持的角色档案。',
          icon: Icons.person_outline,
          action: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              button(
                '导入 PLR',
                Icons.file_upload_outlined,
                () => act('import', {'kind': 'player'}),
                primary: true,
              ),
              button(
                '新建角色',
                Icons.person_add_alt,
                () => _editValue(
                  '角色名称',
                  '新探险者',
                  (name) => act('newPlayer', {'name': name}),
                ),
              ),
            ],
          ),
        ),
      )
    else ...[
      TerraPanel(
        child: Row(
          children: [
            Container(
              width: 65,
              height: 76,
              decoration: BoxDecoration(
                color: const Color(0xff293d45),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.accessibility_new,
                size: 43,
                color: TerraColors.mint,
              ),
            ),
            const SizedBox(width: 19),
            Expanded(
              child: stack([
                Text(
                  '${v.player['name'] ?? '角色'}',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                gap(8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TerraPill(
                      '♥ ${v.player['health'] ?? v.player['life'] ?? '—'}',
                      color: TerraColors.red,
                    ),
                    TerraPill(
                      '✦ ${v.player['mana'] ?? '—'}',
                      color: TerraColors.blue,
                    ),
                    TerraPill('版本 ${v.player['version'] ?? '—'}'),
                  ],
                ),
              ]),
            ),
          ],
        ),
      ),
      gap(),
      button('预览转换到 v326', Icons.compare_arrows, () => _conversionDialog()),
      tabBar('player', [
        '背包与物品',
        '装备与外观',
        '角色属性',
        '增益 / 减益',
        '旅行能力',
        '物品研究',
        '完整编辑器',
      ]),
      if ((tabs['player'] ?? 0) == 6)
        PlayerToolsPanel(
          player: v.player,
          catalog:
              v.player['version'] == 326 &&
                  v.resources?.catalog.gameVersion == '1.4.5.8'
              ? v.resources?.catalog
              : null,
          dispatch: (action, args) => act(action, args),
          itemRules: (id) {
            if (v.player['version'] != 326 ||
                v.resources?.catalog.gameVersion != '1.4.5.8') {
              return null;
            }
            final row = v.resources?.catalog.byId('items', id);
            return row == null
                ? null
                : PlayerItemRules.fromMetadata(row.fields);
          },
          knownBuffIds: v.player['version'] == 326
              ? {
                  for (final row
                      in v.resources?.catalog.families['buffs'] ?? [])
                    if (row.numericId != null) row.numericId!,
                }
              : const {},
        )
      else if ((tabs['player'] ?? 0) == 0)
        _inventory()
      else if ((tabs['player'] ?? 0) == 2)
        split(
          TerraPanel(
            child: stack([
              const Text('角色属性', style: TextStyle(fontWeight: FontWeight.w700)),
              gap(20),
              for (final e in {
                'name': '角色名称',
                'health': '生命值',
                'mana': '魔力值',
                'difficulty': '难度 ID',
              }.entries)
                Row(
                  children: [
                    Expanded(child: info(e.value, v.player[e.key])),
                    IconButton(
                      tooltip: '编辑${e.value}',
                      onPressed: () => _editValue(
                        e.value,
                        '${v.player[e.key] ?? ''}',
                        (s) => act('stagePlayer', {
                          'field': e.key,
                          'value': _scalarValue(e.key, s, v.player[e.key]),
                        }),
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 17),
                    ),
                  ],
                ),
            ]),
          ),
          TerraPanel(
            child: stack([
              const Text('安全输出', style: TextStyle(fontWeight: FontWeight.w700)),
              gap(),
              const TerraNotice('保留原始角色，修改只写入新的副本。'),
              button(
                '导出角色副本',
                Icons.download,
                () => act('export', {'kind': 'player'}),
                primary: true,
              ),
            ]),
          ),
        )
      else
        _playerStructured(),
    ],
  ]);
  Future<void> _conversionDialog() async {
    await act('preparePlayerConversion', {'target': 326});
    if (!mounted || v.result['conversion'] is! Map) {
      return;
    }
    final preview = v.result['conversion'] as Map,
        changes = preview['changes'] as List,
        blocked = preview['blocked'] == true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('转换预览 · v${preview['target']}'),
        content: SizedBox(
          width: 600,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('原件保留。以下差异来自候选文件重新解码；确认后暂存，可撤销。'),
              if (blocked)
                Text(
                  '不能应用：${(preview['blockers'] as List).join('；')}',
                  style: const TextStyle(color: TerraColors.red),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: changes.length,
                  itemBuilder: (context, i) {
                    final c = changes[i] as Map;
                    return ListTile(
                      title: Text('${c['path']}'),
                      subtitle: Text('${c['before']} → ${c['after']}'),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: blocked ? null : () => Navigator.pop(ctx, true),
            child: const Text('确认这些变化并转换'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await act('applyPlayerConversion', {'confirmed': true});
    } else {
      await act('cancelPlayerConversion');
    }
  }

  Object _scalarValue(String field, String text, Object? original) {
    if (const ['name', 'worldName', 'seed'].contains(field)) return text;
    if (original is bool || field == 'crimson') {
      return text == 'true'
          ? true
          : text == 'false'
          ? false
          : text;
    }
    if (original is num ||
        const [
          'health',
          'mana',
          'difficulty',
          'gameMode',
          'spawnTileX',
          'spawnTileY',
        ].contains(field)) {
      return num.tryParse(text) ?? text;
    }
    return text;
  }

  Widget _playerStructured() {
    final group = tabs['player'] ?? 1;
    final fields = switch (group) {
      1 => const [
        'armor',
        'dyes',
        'miscEquips',
        'miscDyes',
        'piggyBank',
        'safe',
        'defendersForge',
        'voidVault',
        'loadouts',
        'hair',
        'hairDye',
        'skinVariant',
        'hairColor',
        'skinColor',
        'eyeColor',
        'shirtColor',
        'underShirtColor',
        'pantsColor',
        'shoeColor',
      ],
      3 => const ['buffs'],
      4 => const ['creativePowers', 'journey'],
      _ => const ['creativeItemSacrifices', 'research'],
    };
    final available = fields.where(v.player.containsKey).toList();
    return TerraPanel(
      child: stack([
        const TerraNotice(
          '高级结构化编辑：仅显示当前角色实际包含的字段。修改先校验结构与版本，再生成可导出的角色副本。',
          icon: Icons.data_object,
        ),
        if (available.isEmpty)
          const TerraEmpty('当前角色未包含这些字段', '不同版本与角色模式支持的字段有所不同。'),
        for (final field in available)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.data_object, color: TerraColors.mint),
            title: Text(
              field,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _jsonSummary(v.player[field]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: TerraColors.muted),
            ),
            trailing: TextButton(
              onPressed: () => _editStructured(
                field,
                v.player[field],
                (value) => act('stagePlayer', {'field': field, 'value': value}),
              ),
              child: const Text('编辑 JSON'),
            ),
          ),
      ]),
    );
  }

  String _jsonSummary(Object? value) {
    if (value is List) return '${value.length} 项 · ${jsonEncode(value)}';
    if (value is Map) return '${value.length} 个字段 · ${jsonEncode(value)}';
    return jsonEncode(value);
  }

  Widget _bestiaryPanel() {
    final raw = v.world['bestiary'];
    final supported = (v.world['version'] as num? ?? 0) >= 210;
    if (raw is! Map || !supported) {
      return const TerraPanel(child: TerraEmpty('当前世界没有可写图鉴', '请导入支持图鉴区段的世界。'));
    }
    return TerraPanel(
      child: stack([
        if (v.result['bestiaryRulesVerified'] != true)
          const TerraNotice('逐项和批量操作需要匹配版本的图鉴目录；其他受支持版本仍可使用下方结构化编辑。'),
        BestiaryToolsPanel(
          bestiary: Map<String, Object?>.from(raw),
          catalog: v.resources?.catalog,
          busy: v.busy,
          readOnly:
              v.world['readOnly'] == true ||
              v.result['bestiaryRulesVerified'] != true,
          onAction: (action, args) => act(action, args),
        ),
        ExpansionTile(
          key: const PageStorageKey('bestiary-advanced-records'),
          title: const Text('高级结构化编辑'),
          children: [
            for (final key in ['kills', 'sightings', 'chats'])
              ListTile(
                title: Text(key),
                trailing: TextButton(
                  onPressed: v.busy || v.world['readOnly'] == true
                      ? null
                      : () => _editStructured(
                          key,
                          raw[key],
                          (value) => act('stageBestiary', {
                            'patch': {key: value},
                          }),
                        ),
                  child: const Text('编辑记录'),
                ),
              ),
          ],
        ),
      ]),
    );
  }

  Future<void> _editStructured(
    String title,
    Object? value,
    ValueChanged<Object?> save,
  ) async {
    final input = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(value),
    );
    String? error;
    await _showDialog(
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text('编辑 $title'),
          content: SizedBox(
            width: 600,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '修改现有结构。保存时先解析 JSON，再交由引擎校验。原始文件不会被覆盖。',
                  style: TextStyle(fontSize: 12, color: TerraColors.muted),
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * .45,
                  ),
                  child: TextField(
                    controller: input,
                    minLines: 6,
                    maxLines: 18,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'JSON 数据',
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: TerraColors.red,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final decoded = jsonDecode(input.text);
                  if (value is List && decoded is! List ||
                      value is Map && decoded is! Map) {
                    throw const FormatException('请保留原来的数组或对象结构。');
                  }
                  Navigator.pop(ctx);
                  save(decoded);
                } catch (e) {
                  update(() => error = 'JSON 无效：$e');
                }
              },
              child: const Text('校验并暂存'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
  }

  Widget _inventory() {
    final inventory = (v.player['inventory'] as List?) ?? const [];
    return split(
      TerraPanel(
        child: stack([
          const Text(
            '背包 · 钱币 · 弹药',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          gap(),
          LayoutBuilder(
            builder: (context, c) {
              final n = c.maxWidth < 400 ? 5 : 10;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: n,
                  crossAxisSpacing: 7,
                  mainAxisSpacing: 7,
                ),
                itemCount: inventory.isEmpty ? 50 : inventory.length,
                itemBuilder: (context, i) {
                  final item = i < inventory.length ? inventory[i] : null;
                  final id = item is Map
                      ? item['itemType'] ?? item['id'] ?? item['itemId'] ?? 0
                      : 0;
                  return Material(
                    color: slot == i
                        ? const Color(0xff304a3e)
                        : const Color(0xff1b2932),
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      onTap: () => setState(() => slot = i),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: slot == i
                                ? TerraColors.mint
                                : TerraColors.border,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: id == 0
                              ? Text(
                                  '${i + 1}',
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: Color(0xff50646d),
                                  ),
                                )
                              : stack([
                                  const Spacer(),
                                  const Icon(
                                    Icons.category_outlined,
                                    color: TerraColors.amber,
                                    size: 19,
                                  ),
                                  Text(
                                    '#$id',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 9),
                                  ),
                                  const Spacer(),
                                ]),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
          gap(),
          const Text(
            '槽位显示实际物品 ID；未加载游戏贴图时使用通用图标。',
            style: TextStyle(fontSize: 10, color: TerraColors.muted),
          ),
        ]),
      ),
      TerraPanel(
        child: stack([
          Text(
            '编辑栏位 ${slot + 1}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          gap(),
          field('itemId', '物品 ID', initial: '0', number: true),
          field('quantity', '数量', initial: '1', number: true),
          field('prefix', '前缀 ID', initial: '0', number: true),
          button(
            '暂存物品修改',
            Icons.check,
            () => act('stageInventory', {
              'slot': slot,
              'itemId': form['itemId'] ?? 0,
              'quantity': form['quantity'] ?? 1,
              'prefix': form['prefix'] ?? 0,
            }),
            primary: true,
          ),
          gap(),
          const TerraNotice('更改会先暂存，导出前由引擎检查物品数量与版本限制。'),
        ]),
      ),
    );
  }

  Widget _generation() => v.cloud != null
      ? _cloudPanel()
      : split(
          TerraPanel(
            child: stack([
              const Text(
                '基础世界参数',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              gap(20),
              field('genName', '世界名称', initial: '我的新冒险'),
              field('seed', '世界种子（留空则随机）'),
              choices('size', '世界大小', ['小型', '中型', '大型'], initial: '中型'),
              choices('difficulty', '游戏难度', ['经典', '专家', '大师', '旅途']),
              choices('evil', '邪恶地形', ['随机', '腐化', '猩红']),
              const Divider(),
              const Text(
                '生成与服务状态',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              gap(12),
              const TerraNotice(
                '没有连接云端服务时不会伪造生成任务。当前支持范围、失败原因和输出类型由本地引擎明确返回。',
                warning: true,
                icon: Icons.cloud_off_outlined,
              ),
              button(
                '检查并开始生成',
                Icons.play_arrow,
                () => act('generate', {
                  'name': form['genName'] ?? '我的新冒险',
                  'seed': form['seed'] ?? '',
                  'size': form['size'] ?? '中型',
                  'difficulty': form['difficulty'] ?? '经典',
                  'evil': form['evil'] ?? '随机',
                }),
                primary: true,
              ),
            ]),
          ),
          stack([
            TerraPanel(
              child: stack([
                const Text(
                  '下一段冒险',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                gap(),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: const SizedBox(
                    height: 180,
                    child: CustomPaint(
                      painter: LandscapePainter(),
                      child: SizedBox.expand(),
                    ),
                  ),
                ),
                gap(10),
                const Text(
                  '原创场景插画 · 非生成结果',
                  style: TextStyle(fontSize: 9, color: TerraColors.muted),
                ),
                gap(),
                info('世界名称', form['genName'] ?? '我的新冒险'),
                info('生成状态', v.result['generationStatus'] ?? '未开始'),
              ]),
            ),
            gap(),
            TerraPanel(
              child: v.busy
                  ? const Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : TerraEmpty(
                      v.result['generationStatus'] == null ? '暂无生成任务' : '生成信息',
                      '${v.result['generationMessage'] ?? '填写参数后检查可用生成方式。'}',
                      icon: Icons.schedule,
                    ),
            ),
          ]),
        );
  Widget _write() => stack([
    tiles(
      List.generate(
        4,
        (i) => TerraPanel(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: const Color(0xff29443e),
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(color: TerraColors.mint, fontSize: 12),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: stack([
                  Text(
                    ['选择来源', '选择地图', '位置与选项', '检查与写入'][i],
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    ['像素 / 电路 / 建筑', '目标 WLD', '精确坐标', '输出新副本'][i],
                    style: const TextStyle(
                      fontSize: 9,
                      color: TerraColors.muted,
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
      minWidth: 170,
    ),
    gap(),
    split(
      stack([
        _worldMap(),
        gap(),
        const TerraNotice('写入前检查边界、版本与冲突。只有真实校验通过后才生成副本，绝不以流程动画代替文件处理。'),
        if (v.result['validation'] != null || v.result['validated'] == true)
          TerraPanel(
            child: stack([
              const Text('校验结果', style: TextStyle(fontWeight: FontWeight.w700)),
              gap(12),
              Text('${v.result['validation'] ?? '候选世界已回读校验'}'),
              if (v.result['output'] != null) info('输出', v.result['output']),
            ]),
          ),
      ]),
      TerraPanel(
        child: stack([
          const Text('写入配置', style: TextStyle(fontWeight: FontWeight.w700)),
          gap(18),
          choices('source', '源素材', [
            'pixel',
            'fusion',
            'circuit',
          ], initial: 'pixel'),
          if (v.region != null)
            choices('fusionWriteMode', '完整区域写入方式', [
              'overlay',
              'replace',
            ], initial: 'overlay'),
          info('目标世界', v.world['name'] ?? '未选择'),
          gap(12),
          field('writeX', '横坐标 X', initial: '0', number: true),
          field('writeY', '纵坐标 Y', initial: '0', number: true),
          toggle(
            '写入方块虚化',
            form['ghost'] == true,
            (b) => setState(() => form['ghost'] = b),
          ),
          toggle(
            '保留目标墙壁',
            form['keepWalls'] == true,
            (b) => setState(() => form['keepWalls'] = b),
          ),
          toggle(
            '跳过透明像素',
            form['skipAir'] != false,
            (b) => setState(() => form['skipAir'] = b),
          ),
          toggle(
            '覆盖普通方块/墙体',
            form['overwrite'] == true,
            (b) => setState(() => form['overwrite'] = b),
          ),
          const TerraNotice('完整区域使用原生流式核心；覆盖、清除和物件伴随数据分别校验。像素写入不允许破坏家具或实体。'),
          const Divider(),
          button(
            '预览并校验',
            Icons.fact_check_outlined,
            () => act('validate', _writeArgs()),
            primary: true,
          ),
          gap(10),
          button(
            '生成新副本',
            Icons.output_outlined,
            v.world.isEmpty
                ? null
                : () => _confirm(
                    '生成新的世界副本',
                    '将按当前坐标与选项处理来源画布。原始存档不会被覆盖。',
                    () => act('write', _writeArgs()),
                  ),
          ),
          gap(),
          const TerraNotice('原件不变 · 新副本输出', icon: Icons.shield_outlined),
        ]),
      ),
    ),
  ]);
  Map<String, Object?> _writeArgs() => {
    'source': form['source'] ?? 'pixel',
    'x': form['writeX'] ?? 0,
    'y': form['writeY'] ?? 0,
    'keepWalls': form['keepWalls'] == true,
    'skipAir': form['skipAir'] != false,
    'overwrite': form['overwrite'] == true,
    'mode': form['fusionWriteMode'] ?? 'overlay',
    'ghost': form['ghost'] == true,
  };
  Widget _saves() => stack([
    tabBar('saves', ['本地文件', '我的云端', '地图推荐', '角色推荐', '恢复与历史']),
    if ((tabs['saves'] ?? 0) == 0) ...[
      searchBox('按名称或文件类型搜索'),
      Wrap(
        spacing: 8,
        children: ['全部', 'world', 'player', 'project']
            .map(
              (s) => ChoiceChip(
                label: Text(
                  {'world': '世界', 'player': '角色', 'project': '工程'}[s] ?? s,
                ),
                selected: filter == s,
                onSelected: (_) => setState(() => filter = s),
              ),
            )
            .toList(),
      ),
      gap(),
      if (v.files.where(_fileMatches).isEmpty)
        TerraPanel(
          child: TerraEmpty(
            '这里还没有匹配的文件',
            '导入存档后，真实读取的文件会显示在这里。',
            action: button(
              '导入文件',
              Icons.file_upload_outlined,
              _importDialog,
              primary: true,
            ),
          ),
        )
      else
        tiles(
          v.files
              .where(_fileMatches)
              .map(
                (f) => TerraPanel(
                  child: stack([
                    Container(
                      height: 100,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xff20362f),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        (f.kind == 'player' || f.kind == 'plr')
                            ? Icons.person_outline
                            : Icons.description_outlined,
                        color: TerraColors.mint,
                        size: 37,
                      ),
                    ),
                    gap(15),
                    Text(
                      f.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    gap(5),
                    Text(
                      f.detail.isEmpty ? f.kind : f.detail,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    gap(15),
                    button('打开', Icons.folder_open, () {
                      act('openFile', {'id': f.id});
                      go(
                        (f.kind == 'player' || f.kind == 'plr')
                            ? 'player'
                            : (f.kind == 'world' || f.kind == 'wld')
                            ? 'world'
                            : _artifactSection(f.kind),
                      );
                    }, primary: true),
                  ]),
                ),
              )
              .toList(),
        ),
    ] else if (tabs['saves'] == 4)
      TerraPanel(
        child: VaultHistoryPanel(
          entries: (v.result['vaultEntries'] as List? ?? const [])
              .whereType<VaultEntry>()
              .toList(),
          onRestore: (id) => act('restoreFile', {'id': id}),
          onTrash: (id) => act('trashFile', {'id': id}),
        ),
      )
    else if (v.cloud != null)
      _cloudPanel(
        recommendationKind: tabs['saves'] == 2
            ? 'world'
            : tabs['saves'] == 3
            ? 'player'
            : 'all',
      )
    else
      TerraPanel(
        child: TerraEmpty(
          '云端服务尚未连接',
          '当前工作空间仅使用本地文件。云端存档与社区推荐需要真实服务连接后才能读取。',
          icon: Icons.cloud_off_outlined,
          action: button('查看设置', Icons.settings_outlined, () => go('settings')),
        ),
      ),
  ]);
  String _artifactSection(String kind) {
    if (kind == 'map') {
      tabs['world'] = 5;
      return 'world';
    }
    if (kind == 'rulesCircuit') {
      tabs['circuit'] = 3;
      return 'circuit';
    }
    if (kind == 'circuit') tabs['circuit'] = 0;
    return switch (kind) {
      'pixel' => 'pixel',
      'circuit' => 'circuit',
      'achievements' || 'catalog' || 'resources' || 'markers' => 'codex',
      'mapping' || 'worldRules' => 'mapping',
      _ => 'fusion',
    };
  }

  bool _fileMatches(TerraFile f) =>
      ('${f.name} ${f.kind}'.toLowerCase().contains(search.toLowerCase())) &&
      (filter == '全部' ||
          f.kind == filter ||
          (filter == 'world' && f.kind == 'wld') ||
          (filter == 'player' && f.kind == 'plr') ||
          (filter == 'project' &&
              !['world', 'player', 'wld', 'plr'].contains(f.kind)));
  Widget _codex() => stack([
    button(
      '导入本地资源目录 / 工程',
      Icons.file_open_outlined,
      () => act('import', {'kind': 'project'}),
    ),
    button(
      '导入完整 .abcpack 资源包',
      Icons.archive_outlined,
      () => act('import', {'kind': 'resources'}),
    ),
    tabBar('codex', ['资料目录', '地图标记', '怪物图鉴', '成就编辑', '线上资源']),
    searchBox('搜索名称、Item ID 或 Tile ID'),
    if ((tabs['codex'] ?? 0) == 0 && v.resources != null) ...[
      SizedBox(
        height: 580,
        child: CatalogBrowser(
          store: v.resources!,
          onSelected: (entry) {
            if (entry.family == 'items' && entry.numericId != null) {
              act('addMarker', {'itemId': entry.numericId});
            } else if (entry.family == 'tiles' &&
                int.tryParse(entry.id.split(':').first) != null) {
              act('markerToggle', {
                'kind': 'tile',
                'id': int.parse(entry.id.split(':').first),
              });
            } else {
              _explain(entry.name, _jsonSummary(entry.fields));
            }
          },
        ),
      ),
      const TerraNotice('物品选择可添加宝箱内容标记；目录与图标来自已验证的本地或线上资源包。'),
    ] else if ((tabs['codex'] ?? 0) == 0) ...[
      Wrap(
        spacing: 8,
        children: ['全部', '方块', '家具', '消耗品', '电路']
            .map(
              (s) => ChoiceChip(
                label: Text(s),
                selected: filter == s,
                onSelected: (_) => setState(() => filter = s),
              ),
            )
            .toList(),
      ),
      gap(),
      if (v.catalog.isEmpty)
        const TerraPanel(
          child: TerraEmpty(
            '资料索引尚未加载',
            '不会用少量示例冒充完整游戏目录。加载资源后可搜索物品。',
            icon: Icons.menu_book_outlined,
          ),
        )
      else
        tiles(
          v.catalog
              .where(
                (e) =>
                    '$e'.toLowerCase().contains(search.toLowerCase()) &&
                    (filter == '全部' || '${e['category']}' == filter),
              )
              .map(
                (e) => TerraPanel(
                  padding: const EdgeInsets.all(15),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.category_outlined,
                        color: TerraColors.amber,
                        size: 26,
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: stack([
                          Text(
                            '${e['name'] ?? e['id']}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'ID ${e['id']} · ${e['category'] ?? ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ]),
                      ),
                      IconButton(
                        tooltip: '添加地图标记',
                        onPressed: () => act('addMarker', {'itemId': e['id']}),
                        icon: const Icon(
                          Icons.add_location_alt_outlined,
                          size: 18,
                          color: TerraColors.mint,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
          minWidth: 230,
        ),
    ] else if (tabs['codex'] == 1)
      TerraPanel(child: _markerTools())
    else if (tabs['codex'] == 2)
      _bestiaryPanel()
    else if (tabs['codex'] == 4)
      SizedBox(
        height: 560,
        child: OnlineResourcesPanel(
          service: v.onlineResources,
          onActivate: (_, _) {
            act('activateOnlineResources');
          },
        ),
      ),
    if (tabs['codex'] == 3)
      TerraPanel(
        child: stack([
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              button(
                '导入 achievements.dat',
                Icons.file_upload_outlined,
                () => act('import', {'kind': 'achievements'}),
              ),
              button(
                '导出数据',
                Icons.download_outlined,
                () => act('export', {'kind': 'achievements'}),
                primary: true,
              ),
            ],
          ),
          gap(),
          _achievements(),
          const TerraNotice('只有文件引擎支持的成就格式才能被编辑和导出，未知字段必须保留。', warning: true),
        ]),
      ),
  ]);
  Widget _achievements() => AchievementToolsPanel(
    records: [
      for (final row in v.result['achievements'] as List? ?? const [])
        Map<String, Object?>.from(row as Map),
    ],
    catalog: v.resources?.catalog,
    busy: v.busy,
    onAction: (action, args) => act(action, args),
  );

  Widget _mappingTile(int i, Map<String, Object?> rule) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.compare_arrows, color: TerraColors.mint),
    title: Text(
      '${rule['source'] ?? rule['color']} → ${rule['target'] ?? rule['tileId']}',
    ),
    subtitle: Text(
      rule['type'] == 'terrain'
          ? '环境转换 · ${rule['layer'] == 'wall' ? '墙体' : '前景物块'}'
          : '像素颜色映射',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    trailing: IconButton(
      tooltip: '编辑规则',
      onPressed: () => _mappingDialog(index: i),
      icon: const Icon(Icons.edit_outlined, size: 17),
    ),
  );
  Future<void> _worldPresetDialog() async {
    try {
      final catalog = v.resources?.catalog;
      if (catalog == null) {
        await _explain('需要预设资源', '请导入包含已核验世界规则预设的本地资源包。四种核心预设仍可直接生成候选。');
        return;
      }
      final presets = WorldRulePresets.fromCatalog(
        catalog,
        expectedVersion: '1.4.5.8',
      ).presets;
      if (presets.isEmpty) {
        await _explain('此资源包没有原方案', '请导入包含世界规则预设目录的资源包。核心预设不包含可编辑规则展开。');
        return;
      }
      String query = '';
      await _showDialog(
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('复制原方案规则'),
            content: SizedBox(
              width: 520,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(labelText: '搜索名称或说明'),
                    onChanged: (value) =>
                        update(() => query = value.toLowerCase()),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final preset in presets.where(
                          (p) => '${p.name} ${p.description}'
                              .toLowerCase()
                              .contains(query),
                        ))
                          ListTile(
                            title: Text(preset.name),
                            subtitle: Text(
                              '${preset.description}\n${preset.rules.length} 条 · ${preset.sourceLabel}',
                            ),
                            onTap: () async {
                              Navigator.pop(context);
                              await act('worldPresetClone', {'id': preset.id});
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      await _explain('无法加载原方案', '$e');
    }
  }

  Widget _mapping() {
    if ((tabs['mapping'] ?? 0) == 2) {
      return stack([
        tabBar('mapping', ['像素颜色映射', '选区环境转换', '整图规则']),
        button('从原方案创建可编辑副本', Icons.copy_outlined, _worldPresetDialog),
        if (v.worldRuleSchemes != null)
          NamedSchemePanel(
            library: v.worldRuleSchemes!,
            busy: v.busy,
            onAction: (action, args) => act(action, args),
          ),
        TerraPanel(
          child: WorldRulesPanel(
            scheme: v.worldRuleScheme ?? WorldRuleScheme(name: '我的世界规则'),
            busy: v.busy,
            hasWorld: v.world.isNotEmpty,
            readOnly: v.world['readOnly'] == true,
            preview: v.result['worldRulesPreview'] as Map<String, Object?>?,
            onAction: (action, args) => act(action, args),
          ),
        ),
        if (v.worldRulePreviewPng != null) ...[
          gap(),
          const Text('已生成候选的地图预览（尚未应用）'),
          SizedBox(
            height: 320,
            child: Image.memory(v.worldRulePreviewPng!, fit: BoxFit.contain),
          ),
        ],
      ]);
    }

    final terrain = (tabs['mapping'] ?? 0) == 1;
    final rules = v.mapping;
    final indices = [
      for (var i = 0; i < rules.length; i++)
        if ((rules[i]['type'] == 'terrain') == terrain) i,
    ];
    final plan = v.result['terrainPlan'] as Map?;
    return stack([
      tabBar('mapping', ['像素颜色映射', '选区环境转换', '整图规则']),
      if (v.mappingSchemes != null)
        NamedSchemePanel(
          library: v.mappingSchemes!,
          busy: v.busy,
          onAction: (action, args) => act(action, args),
        ),
      split(
        TerraPanel(
          child: stack([
            Row(
              children: [
                Expanded(
                  child: Text(
                    (tabs['mapping'] ?? 0) == 0 ? '颜色映射表' : '环境转换规则',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                button('新增规则', Icons.add, _mappingDialog),
              ],
            ),
            gap(),
            if (indices.isEmpty)
              const TerraEmpty(
                '还没有自定义规则',
                '添加源颜色与目标物块，建立自己的映射方案。',
                icon: Icons.tune_outlined,
              ),
            if (indices.isNotEmpty)
              SizedBox(
                height: 420,
                child: ListView.builder(
                  itemCount: indices.length,
                  itemBuilder: (context, i) =>
                      _mappingTile(indices[i], rules[indices[i]]),
                ),
              ),
          ]),
        ),
        TerraPanel(
          child: stack([
            const Text('方案属性', style: TextStyle(fontWeight: FontWeight.w700)),
            gap(),
            field('mappingName', '方案名称', initial: '我的像素方案'),
            info('已配置规则', '${v.mapping.length} 条'),
            const Divider(),
            const TerraNotice('规则不直接改写存档。环境转换先预览、确认到融合选区，再通过写入流程校验目标世界。'),
            if (terrain) ...[
              gap(10),
              info(
                '当前融合选区',
                v.region == null
                    ? '未读取'
                    : '${v.region!.width} × ${v.region!.height}',
              ),
              button(
                '预览选区转换',
                Icons.preview_outlined,
                v.region == null || indices.isEmpty
                    ? null
                    : () => act('terrainPreview'),
              ),
              if (plan != null) ...[
                gap(10),
                info('将改变的地块', plan['changedCells']),
                info(
                  '前景 / 墙体变化',
                  '${plan['blockChanges']} / ${plan['wallChanges']}',
                ),
                if (plan['stale'] == true)
                  const TerraNotice('选区或规则已变化，请重新预览。', warning: true),
                button(
                  '确认应用到融合选区',
                  Icons.check,
                  plan['stale'] == true
                      ? null
                      : () => _confirm(
                          '应用环境转换？',
                          '将改变选区内 ${plan['changedCells']} 个地块，可一次撤销。世界文件暂不改变；家具和版本限制仍须在写入时校验。',
                          () => act('terrainApply', {'confirmed': true}),
                        ),
                  primary: true,
                ),
              ],
              gap(10),
              button('打开融合画布', Icons.layers_outlined, () => go('fusion')),
              gap(10),
            ],
            button(
              '保存方案',
              Icons.save_outlined,
              () => act('mappingSave', {
                'name': form['mappingName'] ?? '我的像素方案',
                'rules': v.mapping,
              }),
              primary: true,
            ),
            gap(10),
            button('返回像素工坊', Icons.brush_outlined, () => go('pixel')),
          ]),
        ),
      ),
    ]);
  }

  Widget _cloudPanel({
    String recommendationKind = 'all',
  }) => CloudWorkspacePanel(
    recommendationKind: recommendationKind,
    backend: v.cloud,
    onUpload: () async {
      await act('cloudPrepareUpload');
      if (!mounted || v.result['pendingCloudUpload'] is! Map) {
        return;
      }
      final upload = v.result['pendingCloudUpload'] as Map;
      await _confirm(
        '上传所选文件？',
        '将 ${upload['name']}（${upload['bytes']} 字节）发送到 ${v.result['cloudDestination']}，用于该账户的云端存档；世界存档会附带引擎生成的地图预览。',
        () => act('cloudUploadPrepared'),
      );
      await act('cloudDiscardUpload');
    },
    onDownload: (save) => act('cloudDownload', {'save': save}),
    onRecommendationDownload: (item) =>
        act('cloudRecommendationDownload', {'item': item}),
  );
  Widget _settings() => tiles([
    TerraPanel(child: _cloudPanel()),
    TerraPanel(
      child: button(
        '释放资源内存缓存',
        Icons.cleaning_services_outlined,
        () => act('clearResourceMemory'),
      ),
    ),
    if (const bool.fromEnvironment('TERRAFORGE_QA'))
      TerraPanel(
        child: stack([
          const TerraNotice('QA 测试构建：下列存档由项目生成，不是用户文件。', warning: true),
          button(
            '打开合成物件测试世界',
            Icons.science,
            () => act('openSynthetic', {'kind': 'objects'}),
          ),
          button(
            '打开合成电路测试世界',
            Icons.science,
            () => act('openSynthetic', {'kind': 'circuit'}),
          ),
        ]),
      ),
    TerraPanel(
      child: stack([
        const Row(
          children: [
            CircleAvatar(
              backgroundColor: Color(0xff29443e),
              child: Icon(Icons.person_outline, color: TerraColors.mint),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Text(
                '本地工作空间',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            TerraPill('离线可用'),
          ],
        ),
        gap(),
        const Text(
          '无需账户即可使用本地创作。账户面板显示当前云端连接状态。',
          style: TextStyle(color: TerraColors.muted, fontSize: 12, height: 1.7),
        ),
        const Divider(),
        const Text('存档与安全', style: TextStyle(fontWeight: FontWeight.w700)),
        gap(10),
        toggle(
          '输出前校验完整性',
          true,
          (_) => _explain('完整性校验', '安全导出始终执行引擎支持的验证，不能从界面跳过。'),
          subtitle: '安全要求 · 保持开启',
        ),
        toggle('显示编辑网格', grid, (b) {
          setState(() => grid = b);
          act('settings', {'key': 'grid', 'value': b});
        }),
        const TerraNotice('文件不会自动上传。所有文件写入都明确显示支持范围和结果。'),
      ]),
    ),
    TerraPanel(
      child: stack([
        const Text('资源与支持范围', style: TextStyle(fontWeight: FontWeight.w700)),
        gap(),
        info('界面', '原生 Flutter · 多端适配'),
        info('工作模式', '本地优先'),
        info('资源索引', '${v.catalog.length} 项已载入'),
        info(
          '云端服务',
          v.cloud?.connected == true
              ? '已连接'
              : v.cloud == null
              ? '未配置'
              : '待登录',
        ),
        const Divider(),
        _settingLink(
          '文件格式与支持范围',
          'WLD / PLR / MAP / 工程 JSON / PNG',
          Icons.description_outlined,
          () => _explain(
            '文件格式与支持范围',
            '世界与角色文件的读取、编辑和写入取决于引擎支持的版本。遇到未知或损坏格式会报错，不能只凭文件扩展名判断成功。像素 PNG 与工程 JSON 是独立创作格式。',
          ),
        ),
        _settingLink(
          '使用帮助',
          '安全编辑、绘画与工程导出',
          Icons.help_outline,
          () => _explain(
            '使用帮助',
            '1. 导入存档，等待解析完成。\n2. 修改世界或角色属性，或进入像素工坊创作。\n3. 查看暂存更改并校验。\n4. 导出新副本，保留原始文件。\n\n像素画：画笔、橡皮、填充、取色。Ctrl+Z 撤销，Ctrl+Shift+Z 重做。Ctrl / ⌘+K 搜索功能。',
          ),
        ),
        _settingLink(
          '关于 TerraForge',
          '原创界面 · 本地工作空间',
          Icons.handyman_outlined,
          () => _explain(
            'TerraForge · 泰拉工坊',
            '根据提供的 TerraForge 界面原型，以 Flutter 原生组件重新实现。插画为原创程序绘制。TerraForge 不是 Terraria 官方产品；游戏名称与素材的权利归各自所有者。',
          ),
        ),
      ]),
    ),
  ], minWidth: 400);
  Widget _settingLink(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onTap,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, size: 21, color: TerraColors.muted),
    title: Text(
      title,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(fontSize: 10, color: TerraColors.muted),
    ),
    trailing: const Icon(Icons.chevron_right, size: 17),
    onTap: onTap,
  );

  /// Await route removal, not only pop, before disposing editor controllers.
  Future<void> _showDialog({required WidgetBuilder builder}) async {
    final route = DialogRoute<void>(context: context, builder: builder);
    await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
  }

  Future<void> _importDialog() => _showDialog(
    builder: (ctx) => AlertDialog(
      title: const Text('导入到工作空间'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '选择文件类型，随后由系统文件选择器打开。原始文件保持不变。',
              style: TextStyle(color: TerraColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 18),
            for (final item in [
              ('world', '世界存档', 'WLD', Icons.public),
              ('player', '角色存档', 'PLR', Icons.person_outline),
              ('map', '探索存档', 'MAP', Icons.map_outlined),
              ('image', '图片素材', 'PNG / JPEG', Icons.image_outlined),
              ('project', '创作工程', 'JSON', Icons.layers_outlined),
              ('resources', '本地资源包', 'ABCPACK', Icons.archive_outlined),
              ('achievements', '成就文件', 'DAT', Icons.emoji_events_outlined),
            ])
              ListTile(
                leading: Icon(item.$4, color: TerraColors.mint),
                title: Text(item.$2, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  item.$3,
                  style: const TextStyle(
                    fontSize: 10,
                    color: TerraColors.muted,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () {
                  Navigator.pop(ctx);
                  act('import', {'kind': item.$1});
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ],
    ),
  );
  Future<void> _newDialog() => _showDialog(
    builder: (ctx) => AlertDialog(
      title: const Text('新建创作项目'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in ['pixel', 'fusion', 'circuit'])
              ListTile(
                leading: Icon(
                  _sections.firstWhere((s) => s.id == id).icon,
                  color: TerraColors.mint,
                ),
                title: Text(_sections.firstWhere((s) => s.id == id).title),
                trailing: const Icon(Icons.arrow_forward, size: 17),
                onTap: () {
                  Navigator.pop(ctx);
                  go(id);
                  _resizeDialog(id);
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ],
    ),
  );
  Future<void> _allTools() => _showDialog(
    builder: (ctx) => AlertDialog(
      title: const Text('全部功能'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _sections
                .map(
                  (s) => ListTile(
                    leading: Icon(s.icon, color: TerraColors.mint),
                    title: Text(s.title),
                    onTap: () {
                      Navigator.pop(ctx);
                      go(s.id);
                    },
                  ),
                )
                .toList(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  Future<void> _searchDialog() {
    String query = '';
    return _showDialog(
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '搜索功能或本地文件',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (s) => update(() => query = s),
          ),
          content: SizedBox(
            width: 500,
            height: 360,
            child: ListView(
              children: [
                for (final s in _sections.where(
                  (s) => '${s.title} ${s.description} ${s.id}'
                      .toLowerCase()
                      .contains(query.toLowerCase()),
                ))
                  ListTile(
                    leading: Icon(s.icon, color: TerraColors.mint, size: 20),
                    title: Text(s.title, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      s.eyebrow,
                      style: const TextStyle(
                        fontSize: 9,
                        color: TerraColors.muted,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      go(s.id);
                    },
                  ),
                for (final f in v.files.where(
                  (f) => f.name.toLowerCase().contains(query.toLowerCase()),
                ))
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(f.name),
                    onTap: () {
                      Navigator.pop(ctx);
                      act('openFile', {'id': f.id});
                      go(
                        (f.kind == 'player' || f.kind == 'plr')
                            ? 'player'
                            : 'world',
                      );
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editValue(
    String title,
    String initial,
    ValueChanged<String> save,
  ) async {
    final controller = TextEditingController(text: initial);
    await _showDialog(
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: title),
            onSubmitted: (s) {
              Navigator.pop(ctx);
              save(s);
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text;
              Navigator.pop(ctx);
              save(value);
            },
            child: const Text('保存更改'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _confirm(String title, String message, VoidCallback callback) =>
      _showDialog(
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 380,
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, height: 1.7),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                callback();
              },
              child: const Text('确认'),
            ),
          ],
        ),
      );
  Future<void> _explain(String title, String message) => _showDialog(
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 470,
        child: SingleChildScrollView(
          child: Text(
            message,
            style: const TextStyle(fontSize: 13, height: 1.9),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
  Future<void> _resizeDialog(String kind) async {
    final w = TextEditingController(
          text: '${v.canvases[kind]?.width ?? (kind == 'pixel' ? 34 : 40)}',
        ),
        h = TextEditingController(text: '${v.canvases[kind]?.height ?? 24}');
    String? error;
    await _showDialog(
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('新建 / 调整画布'),
          content: SizedBox(
            width: 350,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '尺寸单位为像素 / 方格。调整尺寸会建立新的画布历史；重要作品请先导出工程。',
                  style: TextStyle(fontSize: 12, color: TerraColors.muted),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: w,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '宽度'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: h,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '高度'),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      error!,
                      style: const TextStyle(
                        color: TerraColors.red,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final x = int.tryParse(w.text), y = int.tryParse(h.text);
                if (x == null ||
                    y == null ||
                    x < 1 ||
                    y < 1 ||
                    x > 512 ||
                    y > 512) {
                  update(() => error = '请输入 1–512 之间的整数。');
                  return;
                }
                Navigator.pop(ctx);
                act('resize', {'canvas': kind, 'width': x, 'height': y});
              },
              child: const Text('创建画布'),
            ),
          ],
        ),
      ),
    );
    w.dispose();
    h.dispose();
  }

  Future<void> _fusionRegionDialog() async {
    final inputs = [
      TextEditingController(text: '0'),
      TextEditingController(text: '0'),
      TextEditingController(text: '40'),
      TextEditingController(text: '24'),
    ];
    String? error;
    await _showDialog(
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('导入世界区域'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '从当前已打开的世界读取指定矩形。区域内容必须属于受支持的普通物块范围。',
                  style: TextStyle(fontSize: 12, color: TerraColors.muted),
                ),
                const SizedBox(height: 15),
                for (var i = 0; i < inputs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: inputs[i],
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: ['起点 X', '起点 Y', '区域宽度', '区域高度'][i],
                      ),
                    ),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: const TextStyle(
                      color: TerraColors.red,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final values = inputs.map((c) => int.tryParse(c.text)).toList();
                if (values.any((n) => n == null) ||
                    values[0]! < 0 ||
                    values[1]! < 0 ||
                    values[2]! < 1 ||
                    values[3]! < 1 ||
                    values[2]! > 512 ||
                    values[3]! > 512) {
                  update(() => error = '坐标须为非负整数，宽高须为 1–512。');
                  return;
                }
                Navigator.pop(ctx);
                act('fusionRegion', {
                  'x': values[0],
                  'y': values[1],
                  'width': values[2],
                  'height': values[3],
                });
              },
              child: const Text('读取区域'),
            ),
          ],
        ),
      ),
    );
    for (final input in inputs) {
      input.dispose();
    }
  }

  Future<void> _coordinateDialog() async {
    final x = TextEditingController(), y = TextEditingController();
    await _showDialog(
      builder: (ctx) => AlertDialog(
        title: const Text('前往世界坐标'),
        content: SizedBox(
          width: 330,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: x,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '横坐标 X'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: y,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '纵坐标 Y'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              act('locate', {
                'x': int.tryParse(x.text) ?? 0,
                'y': int.tryParse(y.text) ?? 0,
              });
            },
            child: const Text('定位'),
          ),
        ],
      ),
    );
    x.dispose();
    y.dispose();
  }

  Future<void> _mappingDialog({int? index}) async {
    final existing = index == null
        ? const <String, Object?>{}
        : v.mapping[index];
    final terrain = index == null
        ? (tabs['mapping'] ?? 0) == 1
        : existing['type'] == 'terrain';
    var layer = existing['layer'] == 'wall' ? 'wall' : 'block';
    final source = TextEditingController(
          text: '${existing['source'] ?? (terrain ? '0' : '#A6DBB6')}',
        ),
        target = TextEditingController(text: '${existing['target'] ?? '0'}');
    await _showDialog(
      builder: (ctx) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(index == null ? '新增映射规则' : '编辑映射规则'),
          content: SizedBox(
            width: 350,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (terrain)
                  DropdownButton<String>(
                    value: layer,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 'block', child: Text('前景物块')),
                      DropdownMenuItem(value: 'wall', child: Text('背景墙体')),
                    ],
                    onChanged: (value) {
                      if (value != null) update(() => layer = value);
                    },
                  ),
                TextField(
                  controller: source,
                  decoration: InputDecoration(
                    labelText: terrain ? '源 ID' : '源颜色 HEX',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: target,
                  decoration: InputDecoration(
                    labelText: terrain && layer == 'wall'
                        ? '目标墙体 ID（0 清除）'
                        : '目标物块 ID（0 为土块）',
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  terrain
                      ? '按原始地块同时匹配，不串联转换；同图层源 ID 不可重复。未知物块、家具及版本兼容性在写入时由引擎检查。'
                      : '规则将保存到当前方案。写入前需检查目标版本是否支持此物块。',
                  style: const TextStyle(
                    fontSize: 11,
                    color: TerraColors.muted,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (index != null)
              TextButton(
                onPressed: () {
                  final rules = [...v.mapping]..removeAt(index);
                  Navigator.pop(ctx);
                  act('mappingSave', {'rules': rules});
                },
                child: const Text('删除规则'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final rule = <String, Object?>{
                  ...existing,
                  'source': source.text.trim(),
                  'target': int.tryParse(target.text.trim()) ?? target.text,
                  'type': terrain ? 'terrain' : 'color',
                  if (terrain) 'layer': layer,
                };
                final rules = [...v.mapping];
                index == null ? rules.add(rule) : rules[index] = rule;
                Navigator.pop(ctx);
                act('mappingSave', {
                  'name': form['mappingName'] ?? '我的像素方案',
                  'rules': rules,
                });
              },
              child: const Text('保存规则'),
            ),
          ],
        ),
      ),
    );
    source.dispose();
    target.dispose();
  }
}
