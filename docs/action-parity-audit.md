# 用户操作级迁移审计

更新：2026-10-09 UTC。只读参考快照：`366ebc57751cadfb077f968f4d5069028b3bf9a6`。Flutter：本工作区当前源码，仍有并行修改；本表不代表已发布版本。

## 结论与判定口径

旧报告列出的 P1–P5 已补上大部分可达 UI、领域逻辑、Workspace 操作和真实核心路径，不能继续写成“只有入口/JSON/简单 ID 替换”。按下表原有的 **38 行动作**重新核对：**已实现 31，部分实现 1，缺失 0，外部阻塞 3，未验证 3**。这是操作覆盖数，不是按功能复杂度加权的完成百分比。

- **已实现**：该行狭义动作有可达 UI、应用操作和实际数据路径。已知版本、资源校验及安全预算仍适用，不表示所有历史版本或所有平台均等价。
- **部分实现**：已有可用动作，但该行列出的参考语义仍有明确本地差距；表内写明差距。
- **缺失**：未发现可达实现；不能因此推断底层核心缺能力。
- **外部阻塞**：完成该动作还需已核验的真实服务契约等外部条件。
- **未验证**：现有证据不能支持该范围的完成结论；不是自动新增开发需求。

本次按当前源码、可达 UI、测试文件和主任务已执行的证明重新核对。2026-10-09 最终本地串行全套为 **438 项通过、0 失败、0 跳过、terminal success**，使用从随附来源构建的原生库及已授权的本地资源/真实地图；已排除 suite-loading 记录。该轮覆盖电路默认页测试修正、恢复后的未保存标记和导航离开暂停回归。最终静态分析无问题，格式检查 185 个文件、零变更；全套之后只补了不改变行为的花括号格式。最终 JavaScript Web 发布构建成功（退出 0，36.6 秒），但 Flutter Wasm dry run 返回 247，不能声称当前 Flutter Wasm 编译通过。该 JavaScript Web 产物使用另行验证的 TerraWasm 引擎；缺少 Cupertino 字体的非致命告警仍在，Material 图标已生成。下列专项证明不再次累加到全套计数。

已确认的独立证据包括：两个真实地图在 Native、WASM、Flutter Workspace 共六个案例通过；全规则电路的 15 示例、1180 响应包和 12 次结构变化与固定参考一致；真实嵌入式 Native JS 的有界 154 案例回放与 15 示例运行；10 项 Web 生命周期测试；Fusion 32 个真实目录放置案例经 WASM 精确回读。最新 UI 尚未重跑完整浏览器交互验收，Android/iOS/macOS 的嵌入式运行时和真机操作未验证。详见[真实地图报告](real-world-validation.md)与[能力证据矩阵](feature-matrix.md)。

`R:` 为只读参考仓库相对路径，`F:` 为 Flutter 仓库相对路径。参考行号沿用该固定快照；Flutter 优先用文件和符号定位，避免并行编辑后行号失真。没有向本报告复制私有实现、资源表或个人样本。

## P1–P5 的实际进展与边界

### P1 宝箱编辑、整理、清空和最佳前缀

已接入 `ChestToolsPanel`：真实槽格及当前值、物品目录搜索、名称/数量/前缀编辑、显式清槽、整理、确认整箱清空、单槽/当前箱/全部箱最佳前缀，以及名称/占用排序、空箱/已修改筛选、内容名称搜索。Workspace 的 `_chest` 保留未传的原前缀，`_transformChests` 整组写回并显示重铸修改数量。空槽在真实核心输出中为 `null`；本次修复已允许从零值编辑空槽，并将 UI 名称/数量边界对齐领域的 20/9999，修复后的 8 项针对性回归已通过。

- 参考：`R:features/world-editor/pages/chest-page.vue:143,164,168,228,781,808,1073`；`R:features/world-editor/services/chests.js:143`；`R:shared/game/item-prefixes.mjs:82–124`。
- 实现：`F:lib/domain/chest_tools.dart`、`prefix_rules.dart`，`F:lib/ui/chest_tools_panel.dart`，`F:lib/application/workspace.dart::_chest/_transformChests`。
- 边界：自动重铸与扩充/替换物品要求匹配世界 v326/资源 1.4.5.8。缺规则时只允许保守编辑；整理无可信堆叠上限时只排序、不合并。整理使用明确的 ID/前缀顺序，并保留未知字段/收藏物品位置，不声称复制参考的原出现顺序整理算法。旧版本前缀评分有领域覆盖，不表示旧版本 UI 自动重铸已开放。
- 覆盖：`chest_tools_test.dart`、`prefix_rules_test.dart`、`prefix_real_catalog_test.dart`、`chest_tools_panel_test.dart`、`native_chest_workspace_test.dart` 分别涉及守恒/未知字段、评分与同分保留、真实目录、交互、原前缀保留/保存回读/精确撤销。

### P2 整图复合规则、核心模式与可编辑原方案

`WorldTileRule`/`WorldRuleScheme` 提供字段和高级材质编辑器、规则顺序/删除、数量限制、四种核心环境模式、命名保存/导入导出与最近方案恢复。命名世界/像素方案库支持创建、克隆、重命名、选择、默认项、确认删除和 vault 重启恢复。Workspace 先生成独立整图候选、检查身份/尺寸/版本并回读预览，再要求确认；世界或方案变化后拒绝过期候选，应用可撤销。

- 参考：`R:features/world-editor/pages/rule-page.vue:16–44,103–108,176–181,248–251,558–681`；`R:features/world-editor/pages/services/tile-rules.js:14–43,381–386`。
- 实现：`F:lib/domain/world_rules.dart`、`world_rule_presets.dart`、`named_scheme_library.dart`，`F:lib/ui/world_rules_panel.dart`、`named_scheme_panel.dart`，`F:lib/application/workspace.dart::_previewWorldRules/_applyWorldRules/_saveWorldRules` 及 `worldPresetClone`。
- 当前 Native/Web 均经 `RegionBackend.regionOperation` → `abc_region_operation` 调用 `batch_update_tiles`。Web 使用 `region_backend_web.dart`/`web/terra_region.js`，不受普通 `mutate` 白名单阻塞。
- **原方案可编辑另存已接通**：资源构建器导入固定来源和摘要绑定的 `world-rule-presets`；本地目录含 23 个真实原方案。`WorldRulePreset.editableCopy` 深复制完整规则并清除 `biomeMode`，UI 的 `worldPresetClone` 加入命名方案库，重复克隆独立命名，编辑副本不改变原方案。版本、来源摘要、规则字段和预算错误会拒绝导入。
- **语义边界**：23 个导入方案保留来源的字面规则；四种核心 `biome_mode` 仍是独立不透明模式。相关模式名称只是标签，未声明两条路径转换语义完全相同；没有把仅改名的核心引用伪装成展开规则。无可验证资源时该另存入口不可用。
- 覆盖：`world_rules_test.dart`、`world_rules_panel_test.dart`、`world_rule_preferences_test.dart`、`native_world_rules_test.dart`、`tool/test_web_world_rules.mjs`；方案库和导入另存另有 `named_scheme_*_test.dart`、`world_rule_presets_test.dart`、`world_rule_presets_private_test.dart`、`world_rule_presets_workspace_test.dart` 及资源构建器测试。候选可读取不等于所有环境、物件和历史版本均已逐格对照参考。

### P3 地图标记管理、样式与真实扫描

已实现物品/物块选择与再次点击取消、单项移除、确认清空、颜色/半径/线宽、合计 256 项预算、无世界时暂存、导入导出和重启恢复。Workspace 通过核心 `mark_tiles_and_chests_preview` 返回 PNG，并将结果接到世界地图；原 WLD 不变。因此旧报告“只有内存 append”和“尚无核心输出路径”均已失效，完成该预览不必强制增加 typed 坐标点集 API。

- 参考：`R:features/catalog/pages/item-page.vue:54–72,225–251,363`；`R:shared/game/entity-marker-catalog.js:3–38,59–73`。
- 实现：`F:lib/domain/map_markers.dart`、`F:lib/ui/map_markers_panel.dart`、`F:lib/application/workspace.dart::_setMarkers/_renderMarkers`。
- 新增：`MapMarkerSelector` 已保存/转交 `locate`、帧坐标和模数，并将规范 selector 纳入身份键；同 tile ID 不同帧可独立选择、设样式和删除，矿脉重复条件会被拒绝。面板支持高级帧条件和 `entity-markers` family 的命名条目。资源构建器通过 `--entity-markers` 接收显式提供、游戏版本匹配、带来源摘要的本地输入；真实 42 条实体目录包已构建，公共实现未嵌入该资源表。
- 核心帧筛选能力已经存在：私有核心 `src/terra_ops.c:190–214` 解析 `locate`/帧/模数，`src/terra_stream.c:465–478` 复用解析与扫描，现有 `abc_region_operation` 可原样转交请求。本次已复用这些能力接通 typed selector、偏好/目录/UI，无需新增 ABI 或重写核心。目录规则来自版本固定的本地资源；不从 RGB compound ID 猜测帧布局。
- 覆盖：`map_markers_test.dart`、`map_markers_panel_test.dart`、`map_marker_workspace_test.dart`、`native_map_marker_test.dart`、`tool/test_web_markers.mjs`。Native 测试验证同一 tile 55 的 frame X 0/18 分别产生精确紫红/青色像素，原 WLD 未改；独立 WASM 请求也验证两个帧筛选返回不同结果，并检查 PNG、原件不变、非法请求及恢复。最终缩放/移动/重复操作的浏览器体验仍需独立验收。

### P4 世界图鉴逐项操作

已由原先只有 JSON 的路径补成可搜索名称/ID、按解锁状态过滤、击杀整数编辑、遇见/交谈切换与确认一键解锁。`BestiaryTools` 按持久 NPC ID 合并目录变体，检查自身解锁规则，保留未知记录；一键解锁保留已有正击杀计数，不把未知条目强行解锁。Workspace 写回三个真实图鉴区段并走世界历史。

- 参考：`R:features/catalog/pages/bestiary-page.vue:36,107–126,474–503`。
- 实现：`F:lib/domain/bestiary_tools.dart`、`F:lib/ui/bestiary_tools_panel.dart`、`F:lib/application/workspace.dart::bestiaryEntry/bestiaryUnlockKnown/_replaceBestiary`。
- 边界：可达编辑要求 v326/1.4.5.8 匹配目录，击杀范围 0–999999999；不匹配版本/未知规则继续只读。“已解锁”表示已有进度，不等于全部掉落信息均显示。
- 覆盖：`bestiary_tools_test.dart`、`bestiary_tools_panel_test.dart`、`native_bestiary_workspace_test.dart`，包括目录别名/未知保留、三轨记录、取消与失败恢复、真实核心回读/撤销。

### P5 成就目录、数值进度与无输入文件新建

已接 `AchievementCatalog`/`AchievementToolsPanel`：名称/说明/分类搜索、逐条件整数或浮点进度、完成切换、确认完成已知交集，以及从有效目录新建文件。Workspace 对每次候选执行加密导出/独立重开校验，并保留原导入文件；不再只有布尔 UI，也不再只能 `open`。

- 参考：`R:features/achievements/pages/editor.vue:201–210,299`。
- 实现：`F:lib/domain/achievement_catalog.dart`、`achievements.dart::blank`，`F:lib/ui/achievement_tools_panel.dart`，`F:lib/application/workspace.dart::achievementNew/achievementCondition/achievementCompleteKnown/_acceptAchievements`。
- 边界：数值必须精确匹配成就 ID、条件 ID、类型及有效最大值；类型冲突/未知数值只读，未知 BSON 保留。新建包含当前完整有效目录的全部条件；不证明任意游戏版本目录都完整。旧文件没有的新版记录不会由“完成已知”偷偷添加。
- 覆盖：`achievement_catalog_test.dart`、`achievement_tools_panel_test.dart`、`achievement_workspace_test.dart` 及原 codec 测试，涉及混合条件、上下限、批量原子性、创建确认、390px 布局、导出重开和原件不变。成就格式由 Dart codec 处理，不应把 Workspace 的合成测试写成真实游戏内验收。

## 本轮其他已接通动作

### Fusion 原版目录放置、对象与连续画笔

`FusionPlacementCatalog` 从匹配 1.4.5.8 的导入目录读取精确占格、逐行高度、帧、变体和样式；`FusionPlacementPanel` 搜索/选择物品并预览占格，Workspace 暂存区域与附加对象、确认狭义插入、独立回读并记录成组历史。WLD 326 的 18 个附加记录物块家族（宝箱、牌子、11 类 tile entity）已有新建负载；展示框可陈列所选物品，名称、牌子文本、逻辑感应器状态按归属验证。连续八类画笔为 block、wall、paint、liquid、wire、shape、actuator、erase，支持组合线色、分层擦除、一次拖动合并撤销和实际图层保留。

- 实现：`fusion_placement.dart`、`region_brush.dart`、相应 UI、`Workspace` 的 `fusionPlace/fusionInsert` 与区域画笔路径。覆盖：`fusion_placement*_test.dart`、`native_fusion_placement*_test.dart`、`region_brush*_test.dart`、`tool/test_web_fusion_placement.mjs`。32 个 Dart 生成的真实目录放置案例经 WASM 精确 tile/COB1 回读；对象负载测试、占用/部分覆盖拒绝和精确撤销已通过。
- 完整对象复制、狭义新增和普通图层画笔有不同安全边界。新增保留目标未变图层并拒绝占用；普通画笔拒绝拆改未知或带帧家具主体。目录支持不等于任意家具/支撑/随机状态均已游戏内验证。
- TCW command 8 的八字 cell records 与 COB1 已完整提取；Native/WASM 字节一致、分页、不可变捕获和失败恢复有证明。导入 4173 条几何布局形成 18681 个精确单格帧记录；未核验支撑、歧义帧和不确定 alternate 不获得安全放置许可。详见 `WORLD_CIRCUIT_FRAGMENTS.md`。
- 实际原版 atlas 已通过真实地图区域 PNG 渲染，但两个选区仍有 48/89 个未知帧提示；普通邻接帧、油漆、液体、光照和动画并非游戏完整渲染。参见 `region-texture-preview.md`。

### 完整规则电路与两个独立旧路径

默认电路编辑器使用固定参考的 JavaScript domain/editor/computation，保留 `viewer-terralogic` 文档格式；不是将器件规则重新翻译成 Dart。`AuthoritativeCircuitPanel`、`CircuitRulesWorkspace`、Native QuickJS/JSC 适配和 Web worker 接通 2776 项 palette、15 示例、搜索/分组、元件属性/样式、放置、四线、选区填充/复制/剪切/粘贴/旋转/镜像、运行/暂停/步进和导入导出。实际规则校验属性与多格占用；复杂属性可显示 JSON，不声称所有属性都有专用视觉控件。

- 证据：`tool/test_circuit_rules.mjs` 比较固定原模块、Web bundle 与 Native 传输 shim，15 示例/1180 包/12 次结构变化一致。`native/circuit_rules_corpus_test.dart` 用真实嵌入式引擎/FFI 重放 154 个有界案例；该回放只含各示例前四命令及 reset，不能写成 Native 重放全部 1180 包。`native/circuit_rules_bundle_test.dart` 另运行全部 15 示例。10 项 `test/web/circuit_rules_lifecycle.cjs` 验证队列、限额、启动失败、取消、超时、释放和重置；领域/Workspace/UI 另有对应测试。
- **仍有明确局部差距**：完整编辑器可直接调用 `removeNetwork`，但当前面板及 facade 未接自动寻路和删除网络预览/确认。参考 routing 能力已在保留模块中，不代表 UI 已可达。独立的单格 `terraforge.circuit` 沙盒已有安全寻路、逐色网络预览/删除、撤销及旋转/镜像，不能以此代替包含 junction/pixel/多格器件的完整编辑器验收。
- 整图 WLD/TWLD 的 TCW 会话是第三条独立路径，保留触发/60 Hz 调度/保存/回读；它不是 `viewer-terralogic` 文件编辑器，也不由完整器件库测试自动获得所有游戏机制的验证。
- 最终全套已覆盖“恢复后未保存标记直到导出成功才清除”和“导航离开时幂等暂停”的生命周期回归；取消导出与忙碌中的暂停均有专门测试。Android/iOS/macOS 嵌入式 JS 运行与真机交互尚未验证。

## 用户动作矩阵

| 必要用户动作 | 状态 | 参考证据 | Flutter 证据与边界/具体欠缺 |
|---|---|---|---|
| 打开世界、读真实地图、定位与导出副本 | 已实现 | R:pages/index/index.vue；首页世界入口 | F:lib/ui/terra_app.dart 世界地图；test/native_workspace_integration_test.dart；只认此动作 |
| 世界线色/液体覆盖层 | 已实现 | R:features/fusion/pages/fusion-page.vue:57,68,80,450–457；参考也读取局部世界 | F:lib/domain/world_map_overlay.dart、ui/world_map_view.dart；test/native_world_overlay_test.dart；已加载视口上限 262144 格，不把无限全图驻留当新增迁移要求 |
| 安全已知世界属性表单 | 已实现 | R 首页世界编辑操作 | F:lib/ui/world_properties_panel.dart；test/native_world_properties_test.dart；只指已知安全字段 |
| 宝箱单槽写入与删除 | 已实现 | R:features/world-editor/pages/chest-page.vue:174–240 | F:lib/ui/chest_tools_panel.dart::editSlot、domain/chest_tools.dart::editSlot；空槽可填、当前值保留、目录选取和显式清槽；本次空槽修复针对性回归已通过 |
| 宝箱名称、前缀编辑 | 已实现 | R:features/world-editor/pages/chest-page.vue:143,228 | F:ChestToolsPanel.rename/editSlot；Workspace._chest；未传前缀保留，匹配版本规则决定可编辑范围 |
| 宝箱整理/确认清空 | 已实现 | R:features/world-editor/pages/chest-page.vue:781,808 | F:ChestTools.organize/clear；Workspace._transformChests；只认安全整理和清空动作，排序策略差异见 P1 |
| 单物品及全箱最佳前缀 | 已实现 | R:features/world-editor/pages/chest-page.vue:239,1073 | F:PrefixRules.bestPrefix、ChestTools.bestPrefixes、ChestToolsPanel；真实目录/版本守卫、同分保留和修改摘要 |
| 宝箱按占用/名称排序，空箱/修改筛选、内容名称搜索 | 已实现 | R:features/world-editor/pages/chest-page.vue:446,662 | F:ChestToolsPanel._list、Workspace._refreshChestChanges；名称来自导入目录 |
| 有界区域 block/wall ID 映射预览、确认、撤销 | 已实现 | R 世界规则 ID 替换的能力子集 | F:lib/domain/terrain_rule_plan.dart；test/native_terrain_workspace_test.dart |
| 整图规则、条件组合、多属性 patch、数量限制 | 已实现 | R:features/world-editor/pages/services/tile-rules.js:14–43,381–386 | F:WorldTileRule、WorldRulesPanel、Workspace._previewWorldRules/_applyWorldRules；Native/Web regionOperation 和真实合约 |
| 净化/腐化/猩红/神圣环境预设 | 已实现 | R:features/world-editor/pages/rule-page.vue:558,594,625,655 | F:WorldRuleScheme.builtinModes；核心 biome_mode；四模式候选可读测试不等于全环境逐格等价 |
| 世界规则方案新建、克隆、命名、选择与内置另存 | 已实现 | R:features/world-editor/pages/rule-page.vue:16–44,71 | F:NamedSchemeLibrary/NamedSchemePanel、WorldRulePresets、Workspace.worldPresetClone；23 个来源绑定原方案可深复制为独立可编辑方案并入库；四种核心 biome_mode 与导入字面规则语义分开记录 |
| 宝箱物品地图标记 | 已实现 | R:features/catalog/pages/item-page.vue:225–246 | F:MapMarkersPanel、Workspace._renderMarkers；真实宝箱扫描→PNG，不再只是固定圆点 |
| 实体物块标记与颜色/半径/线宽 | 已实现 | R:features/catalog/pages/item-page.vue:54–72；shared/game/entity-marker-catalog.js | F:MapMarkerSelector、MapMarkersPanel、MapMarkerProfile.toEngineRequest；同 ID 帧变体、定位/模数、样式/偏好和命名外部目录已接，Native/WASM 帧选择回归通过 |
| 持久标记删除、清空、再点取消 | 已实现 | R:features/catalog/pages/item-page.vue:225–251,363 | F:MapMarkerProfile.toggle/remove/clear；Workspace._setMarkers/initialize；偏好不改变世界 |
| 世界图鉴逐条计数/切换/一键解锁 | 已实现 | R:features/catalog/pages/bestiary-page.vue:36,107,474 | F:BestiaryToolsPanel、BestiaryTools、Workspace 图鉴操作；匹配目录与已知规则范围 |
| 导入成就、布尔项切换、无损导出 | 已实现 | R:features/achievements/pages/editor.vue:179,201,212 | F:AchievementFile、AchievementToolsPanel；已存在的未知布尔条件仍可安全编辑 |
| 成就计数进度、详情与已知项批量解锁 | 已实现 | R:features/achievements/pages/editor.vue:202–210 | F:AchievementCatalog.applyCondition/completeKnown、AchievementToolsPanel；精确 ID/类型/上限关联 |
| 无输入文件新建完整成就 | 已实现 | R:features/achievements/pages/editor.vue:299 | F:AchievementCatalog.createFile、AchievementFile.blank、Workspace.achievementNew；完整性限当前有效目录 |
| 角色新建/导入、背包装备、Buff、研究/旅行能力 | 已实现 | R:features/player-editor/pages/components/player-panel.vue:54,105 | F:lib/ui/player_tools_panel.dart、domain/player_tools.dart；只认已开放支持版本动作 |
| 角色背包整理、复制粘贴与数量校验 | 已实现 | R:features/player-editor/pages/components/player-panel.vue:54,105,375 | F:PlayerTools.copySlot/pasteSlot/replaceSlot、PlayerToolsPanel；35 项领域/组件测试及真实 Native PLR 粘贴/回读/撤销通过 |
| 角色最佳前缀推荐/批量重铸 | 已实现 | R:features/player-editor/pages/components/player-panel.vue:54,105,244–247 | F:PlayerTools.bestPrefixes、共享 PrefixRules、PlayerToolsPanel、Workspace.playerBestPrefixes；确认范围、收藏保留、匹配目录守卫及真实 PLR 回读/撤销 |
| 所有历史角色版本安全转换、外观完全一致 | 未验证 | R:features/player-editor/pages/components/player-panel.vue:365 明示转换风险 | F:lib/engine/player_schema.dart、domain/player_conversion.dart；支持档案有限，不能由少量版本回读推导所有历史版本 |
| 像素画导图、画笔/填充/橡皮/取色、尺寸、撤销、PNG/工程 | 已实现 | R:pages/pixel/pixel.vue:6,111–261 | F:lib/domain/canvas_document.dart、image_import.dart；terra_app.dart 像素工坊；test/canvas_document_test.dart |
| 命名像素映射方案复制、默认方案、重命名 | 已实现 | R:pages/mappingscheme/mappingscheme.vue:180–206 | F:NamedSchemeLibrary/NamedSchemePanel、Workspace._handleSchemeAction/_persistSchemeLibrary；创建/复制/重命名/选择/默认/确认删除及 vault 重启路径已接，20 项历史针对性测试通过；最终全套另行记录 |
| 像素写入世界、定位、候选回读 | 已实现 | R:features/world-write/pages/write-page.vue:1851 | F:lib/domain/world_stamp.dart、Workspace._stamp；test/native_region_workspace_test.dart |
| 参考写入页每个开关及所有映射组合 | 未验证 | R:features/world-write/pages/write-page.vue:1226,1932 preferWall/noPaint | F:WorldStamp 的 mode/覆盖保护已有；尚无逐开关与组合的等价证据，先对照验收，不预先发明新开关 |
| Fusion 全图层区域读取、完整对象复制与安全写回 | 已实现 | R:features/fusion/pages/fusion-page.vue:71,80 | F:RegionDocument、Workspace 区域操作；test/native_region_workspace_test.dart；完整复制不等于新物件放置 |
| Fusion 目录原版放置、多格家具新建、展示框陈列/样式 | 已实现 | R:features/fusion/pages/fusion-page.vue:38–49 | F:FusionPlacementCatalog/Plan/Panel、Workspace.fusionPlace/fusionInsert；匹配目录的占格/帧/变体与展示框物品，WLD326 的 18 个附加记录家族/11 类实体；完整对象、占用、版本和过期候选守卫 |
| Fusion 油漆/液体/线/坡形单格编辑与贴图 | 已实现 | R:features/fusion/pages/fusion-page.vue:52–61,276–277 | F:RegionBrush/RegionBrushPanel、RegionTextureCanvas、Workspace 区域画笔；八类连续工具、组合线色、分层擦除、分组历史与实际图层保留；静态贴图和未知帧边界见上文 |
| 电路运行、单步、触发、世界文件保存 | 已实现 | R:features/circuit/pages/circuit-page.vue；components/CircuitSandbox.vue | F:WorldCircuitPanel、世界 TCW 会话；test/native_world_circuit_workspace_test.dart；有限 sandbox 与真实世界 VM 分开判定 |
| 电路完整物品库、示例、属性与元件样式 | 已实现 | R:features/circuit/components/CircuitFiles.vue:26；CircuitSandbox.vue:117,176 | F:AuthoritativeCircuitPanel、CircuitRulesWorkspace、circuit_rules_backend.dart；固定参考规则的 2776 palette/15 示例、实际属性/样式与多格放置；Linux 嵌入式运行及 Web 合约有证据，目标平台未验证 |
| 电路自动寻路/删除网络预览、选区旋转/镜像 | 部分实现 | R:features/circuit/components/CircuitSandbox.vue:40,47,61,176 | F:完整编辑器已有复制/旋转/镜像与直接删网络，尚无可达自动寻路/删网络预览；CircuitEditSession/CircuitEditTools 仅在单格旧沙盒提供这些预览，不能代替完整器件路径 |
| 本地文件打开、导出、历史/回收站恢复 | 已实现 | R:pages/saves/saves.vue:57,67,291 | F:lib/domain/vault_history.dart、ui/vault_history_panel.dart；test/vault_history_test.dart；不新增不可恢复删除要求 |
| 云端上传/下载、推荐点赞/转存、账户资料 | 外部阻塞 | R:pages/saves/saves.vue:62–65,216–244；pages/user/user.vue:191 | F:lib/cloud/cloud_api.dart、cloud_backend.dart 与 mock 测试；缺真实认证/服务契约，点赞/转存仍须按契约接通，列表 API 不代表已实现 |
| 定制世界配置、提交、取消、重试及真实结果 | 外部阻塞 | R:features/world-generation/pages/generate.vue；pages/saves/saves.vue:65,99–108 | F:GenerationOptionsForm、cloud_api.dart 任务模型；缺真实服务执行及下载回读证据 |
| 资源在线更新、账户头像与完整帮助 | 外部阻塞 | R:pages/user/user.vue:135,191,270；pages/user/help.vue:47–65；infrastructure/api/helper-info.ts | F:terra_app.dart 已有本地指南和资源导入；参考完整帮助实际由 helperInfoApi.list() 返回，在线资源/头像/远程帮助均待真实服务与内容契约，不新增虚构的静态帮助扩写任务 |
| iOS/Android/macOS 真机操作与游戏回读 | 未验证 | 必须实际执行，平台模板不是结果 | F:docs/platform-builds.md；本地 Linux 核心/Web 合约不能代表平台安装、文件选择、生命周期或游戏内回读 |

## 有限的原范围剩余工作

原来五行“部分/缺失”中的四行已由可编辑原方案、Fusion 新建/连续工具和完整规则电路覆盖。当前仍有 **1 行部分实现、0 行缺失**：完整电路编辑器的自动寻路与网络删除预览/确认。狭义单格沙盒已经有这些动作，完整规则的 clipboard 变换也已接通；后续需把已有原规则接到完整编辑器的可达操作，再验证取消、过期预览、重复操作及复杂器件拓扑。

**3 组广泛验证缺口**仍保留：历史角色转换/外观、写入页逐开关与组合对照、目标平台及游戏回读。前两组先核对已有能力和测试夹具，只把实际发现的差距转为开发任务；不声称参考也未保证的任意旧版本安全转换。合计为矩阵中的 3 行“未验证”。最新完整浏览器验收与目标平台实际构建/运行也是交付证据缺口，不自动转为新的功能行。

**帮助归类**：参考 `pages/user/help.vue` 在加载时调用 `helperInfoApi.list()`，渲染服务返回的标题和富文本；只读源码没有一份静态“完整帮助”待迁移。现有本地指南已存在，参考远程帮助的等价接通属于真实服务/内容依赖，不列为额外本地写作任务。

## 真正的外部条件与验证层级

- **服务条件**：已核验的跨平台认证、会话/错误码、云存档/推荐/生成/在线资源/远程帮助契约及真实测试服务和内容。该条件只阻塞相关在线动作，不阻塞上列本地编辑工作；不需要向用户索取长期凭据。
- **环境条件**：Android/iOS/macOS 对应构建和真机/游戏环境。平台源码模板、Linux 动态库、Web 构建均不能替代实际结果；本报告不把签名/商店发布列入已授权本地迁移范围。
- **授权与分发状态**：2026-10-09 已获引擎源码、所需内嵌表、衍生 WASM 和保留 JavaScript 规则公开纳入 `Live-yum/abc` 的授权；该源代码授权阻塞已解除，保留来源/完整性记录且不重新许可。远端 main 的 bootstrap 已确认为 `3def6fa2544d4b7e51579d7091f014277f33bf85`；功能 PR 与该快照远端 CI 仍待完成。个人存档、私人验证产物、游戏图片/程序及凭据继续排除，未签名构建不等于已发布应用。

验收须分层记录：领域单测 → 可达 UI 的取消/重复/忙碌/切换/恢复 → Workspace 历史和原件保持 → 真实 Native/WASM 候选/保存/重开 → 实际浏览器和目标平台/游戏。尤其需要显式启用 Native 与外部目录夹具，区分通过、跳过、未运行；WASM 的 Node 合约不等于 Flutter 浏览器端到端交互。最终回归应覆盖最后一次修改，而不是沿用修改前的通过计数。

当前结论是“38 行狭义动作中 31 行本地已实现、1 行部分实现；另有 3 行真实服务阻塞与 3 行广泛未验证”。这一覆盖数不代表 viewer-app 全操作、全版本、全平台等价，也不把有界合约通过当作最终浏览器或游戏验收。
