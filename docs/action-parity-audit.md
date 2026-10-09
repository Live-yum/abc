# 用户操作级迁移审计

更新：2026-10-09 UTC。只读参考快照：`366ebc57751cadfb077f968f4d5069028b3bf9a6`。Flutter：本工作区当前源码，仍有并行修改；本表不代表已发布版本。

## 结论与判定口径

旧报告列出的 P1–P5 已补上大部分可达 UI、领域逻辑、Workspace 操作和真实核心路径，不能继续写成“只有入口/JSON/简单 ID 替换”。按下表原有的 **38 行动作**重新核对：**已实现 32，部分实现 2，缺失 0，外部阻塞 1，未验证 3**。这是操作覆盖数，不是按功能复杂度加权的完成百分比。

- **已实现**：该行狭义动作有可达 UI、应用操作和实际数据路径。已知版本、资源校验及安全预算仍适用，不表示所有历史版本或所有平台均等价。
- **部分实现**：已有可用动作，但该行列出的参考语义仍有明确本地差距；表内写明差距。
- **缺失**：未发现可达实现；不能因此推断底层核心缺能力。
- **外部阻塞**：本地对应传输/操作已有，实际结果还依赖受支持账户、实时服务数据或可用执行环境；该标签不覆盖未完成的客户端移植。
- **未验证**：现有证据不能支持该范围的完成结论；不是自动新增开发需求。

本次按当前源码、可达 UI、测试文件和主任务已执行的证明重新核对。2026-10-09 布线/网络预览快照的本地串行全套为 **465 项通过、0 失败、0 跳过、terminal success**，171.558 秒，使用从随附来源构建的原生库及已授权的本地资源/真实地图。包含完整 `test/` 和两项通过 Flutter 执行的真实 Native 集成 smoke；已排除 suite-loading 记录。40 项 actor/UI/导航专项属于该覆盖，不重复累加到总数。完整 244 案例真实 QuickJS/FFI 回放已通过；最终静态分析无问题，格式检查 186 个文件、零变更，随后仅对 Native 测试 harness 作了等价的 null-aware-element lint 修正。该快照 JavaScript Web 发布构建成功（退出 0，33.1 秒）；Flutter Wasm dry run 返回 247，不能声称 Flutter Wasm 编译通过。Cupertino 字体缺失仍有非致命告警，Material 图标已生成；Web 应用使用另行验证的 TerraWasm 引擎。

已确认的独立证据包括：两个真实地图在 Native、WASM、Flutter Workspace 共六个案例通过；全规则电路的 1364 次调用、15 示例、1180 响应包和 12 次结构变化与固定参考一致；真实 Linux QuickJS/FFI 的有界 244 案例回放与独立的 15 示例运行；10 项 Web 生命周期测试；Fusion 32 个真实目录放置案例经 WASM 精确回读。最新 UI 尚未重跑完整浏览器交互验收，Android/iOS/macOS 的嵌入式运行时和真机操作未验证。详见[真实地图报告](real-world-validation.md)与[能力证据矩阵](feature-matrix.md)。

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

默认电路编辑器使用固定参考的 JavaScript domain/editor/computation，保留 `viewer-terralogic` 文档格式；不是将器件规则重新翻译成 Dart。`AuthoritativeCircuitPanel`、`CircuitRulesWorkspace`、Native QuickJS/JSC 适配和 Web worker 接通 2776 项 palette、15 示例、搜索/分组、元件属性/样式、放置、四线、自动寻路/网络删除预览与确认、选区填充/复制/剪切/粘贴/旋转/镜像、运行/暂停/步进和导入导出。实际规则校验属性与多格占用；复杂属性可显示 JSON，不声称所有属性都有专用视觉控件。

- 证据：`tool/test_circuit_rules.mjs` 比较固定原模块、Web bundle 与 Native 传输 shim，1364 次调用、15 示例/1180 模拟包/12 次结构变化一致，结束时无残留 traversal handles 或 callback buffers。`native/circuit_rules_corpus_test.dart` 用真实 Linux QuickJS/FFI 在 44 秒内重放全部 244 个记录案例，包含新增预览/提交/取消/失效/预算/失败恢复；示例模拟只保留各示例前四命令及 reset，不能写成 Native 重放全部 1180 包。`native/circuit_rules_bundle_test.dart` 另运行全部 15 示例。10 项 `test/web/circuit_rules_lifecycle.cjs` 验证队列、限额、启动失败、取消、超时、释放和重置；40 项 actor/UI/导航专项覆盖可达交互。
- **完整编辑器预览已实现并验证**：面板通过 `rulesPreviewRoute/rulesPreviewNetwork/rulesCommitPreview/rulesCancelPreview` 调用 facade 的原 `CircuitEditor.route`/`traceNetwork`，不修改参考寻路/拓扑算法。预览显示逐色覆盖和数量，确认绑定文档 ID/代次/revision/token，一次提交形成一条 undo；取消、后续编辑、模拟、重置、导入、关闭使旧计划失效。最多 60000 格，60001 格拒绝。证明覆盖三种 junction 样式、pixel 方向、多格占用与支撑、未选择线色保留、防意外短接、不可达路径、重复/伪造/过期确认和精确 undo/redo。独立单格沙盒不作为此完整规则路径的替代证据；目标平台和实际浏览器交互仍分开验收。
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
| 电路自动寻路/删除网络预览、选区旋转/镜像 | 已实现 | R:features/circuit/components/CircuitSandbox.vue:40,47,61,176 | F:AuthoritativeCircuitPanel/CircuitRulesWorkspace/rules-facade；原规则寻路/逐色网络预览、覆盖层、token 确认/取消/原子 undo 与剪贴板变换可达；40 项 actor/UI/导航、完整 Node 与真实 QuickJS 的 244 案例证明通过；预览上限 60000 格 |
| 本地文件打开、导出、历史/回收站恢复 | 已实现 | R:pages/saves/saves.vue:57,67,291 | F:lib/domain/vault_history.dart、ui/vault_history_panel.dart；test/vault_history_test.dart；不新增不可恢复删除要求 |
| 云端上传/下载、推荐点赞/转存、账户资料 | 部分实现 | R:pages/saves/saves.vue:62–65,216–244；pages/user/user.vue:191 | F:CloudApi/HttpCloudApi/CloudBackend/CloudWorkspacePanel 有通用传输及 mock 覆盖；缺推荐 like/计数下载/转存、预览和参考私有存档直接下载适配。R API 已定义这些客户端契约；跨平台身份适配与真实账户/服务验证另待完成 |
| 定制世界配置、提交、取消、重试及真实结果 | 外部阻塞 | R:features/world-generation/pages/generate.vue；pages/saves/saves.vue:65,99–108 | F:GenerationOptionsForm/HttpCloudApi/CloudBackend 已实现 schema 表单、提交/轮询/取消/重试；R:infrastructure/api/world-generation.ts 已定义契约。受支持的跨平台真实会话、实时 options/schema 和任务/下载结果验证未取得；不是缺少全部协议 |
| 资源在线更新、账户头像与完整帮助 | 部分实现 | R:pages/user/user.vue:135,191,270；pages/user/help.vue:47–65；infrastructure/api/helper-info.ts | F:本地资源导入/指南、profile 通用接口和昵称 UI 已有；在线资源安装、头像控件与远程帮助客户端未接。R:resource-manager.mjs、auth.ts、helper-info.ts 已有契约/实现；实时批准资源/内容及账户验证是另一个外部条件 |
| iOS/Android/macOS 真机操作与游戏回读 | 未验证 | 必须实际执行，平台模板不是结果 | F:docs/platform-builds.md；本地 Linux 核心/Web 合约不能代表平台安装、文件选择、生命周期或游戏内回读 |

## 有限的原范围剩余工作

完整电路自动寻路与网络删除预览已通过可达 UI、控制器、原规则对照和真实 Linux QuickJS/FFI 证明，原五行“部分/缺失”的本地编辑功能均已覆盖。当前表内仍有 **2 行部分实现**，都是在线功能的本地接线缺口；不能用电路完善或本地测试通过代替这些客户端移植。
在线功能重新按源码核对后，不再把尚未移植的客户端操作统称为“外部阻塞”：推荐点赞/计数下载/转存、参考私有存档下载适配、在线资源安装、头像控件和远程帮助接线仍是本地工程工作。它们已有参考客户端契约；真实身份提供方、会话、服务内容及实际调用结果是独立的外部/验证条件。此处纠正的是状态分类，没有将这些功能记作已完成。

**3 组广泛验证缺口**仍保留：历史角色转换/外观、写入页逐开关与组合对照、目标平台及游戏回读。前两组先核对已有能力和测试夹具，只把实际发现的差距转为开发任务；不声称参考也未保证的任意旧版本安全转换。合计为矩阵中的 3 行“未验证”。最新完整浏览器验收与目标平台实际构建/运行也是交付证据缺口，不自动转为新的功能行。

**帮助归类**：参考 `pages/user/help.vue` 在加载时调用 `helperInfoApi.list()`，渲染服务返回的标题和富文本；只读源码没有一份静态“完整帮助”待迁移。现有本地指南已存在；远程帮助的客户端请求与内容呈现仍需本地接线，真实文章内容由服务提供。不应把客户端缺口说成协议不存在，也不新增静态帮助写作任务。

## 真正的外部条件与验证层级

- **已有参考契约与本地缺口**：`R:infrastructure/api/cloud-saves.ts`、`recommendations.ts`、`world-generation.ts`、`auth.ts`、`helper-info.ts` 以及 `infrastructure/assets/resource-manager.mjs` 已定义客户端操作。Flutter 通用 adapter 的列表/上传/票据下载/资料/任务传输和 mock 测试已存在，但不能直接等同于参考服务兼容。参考私有存档走授权二进制下载，推荐另走 ticket/complete/transfer；当前 Flutter 只有通用票据下载，推荐仅展示列表。点赞、计数下载、转存、资源在线安装、头像和帮助客户端仍需工程接线。
- **实际外部条件**：已读 `R:infrastructure/api/auth.ts` 提供微信小程序 loginCode/state 登录及 refresh；未有可验证的非微信跨平台身份交换方案。受支持会话、部署配置、实时生成 options/schema、批准的在线资源及帮助内容、真实任务/传输结果仍待确认。普通客户端移植不因这些条件而自动变成外部阻塞，也不需要向用户索取长期凭据。
- **环境条件**：Android/iOS/macOS 对应构建和真机/游戏环境。平台源码模板、Linux 动态库、Web 构建均不能替代实际结果；本报告不把签名/商店发布列入已授权本地迁移范围。
- **授权与分发状态**：2026-10-09 已获引擎源码、所需内嵌表、衍生 WASM 和保留 JavaScript 规则公开纳入 `Live-yum/abc` 的授权；该源代码授权阻塞已解除，保留来源/完整性记录且不重新许可。远端 main 的 bootstrap 已确认为 `3def6fa2544d4b7e51579d7091f014277f33bf85`；[Draft PR #1](https://github.com/Live-yum/abc/pull/1) 已创建且未合并。首个提交 `f966c574` 的 [CI](https://github.com/Live-yum/abc/actions/runs/37865496547) 已结束：Web/Linux jobs 与 macOS 应用构建通过，Android 工具链、Native runner 和 iOS archive graph 出现失败。修正及后续本地布线/预览变更还需发布并核对自身提交的 CI，不能沿用旧提交结果。个人存档、私人验证产物、游戏图片/程序及凭据继续排除，未签名构建不等于已发布应用。

验收须分层记录：领域单测 → 可达 UI 的取消/重复/忙碌/切换/恢复 → Workspace 历史和原件保持 → 真实 Native/WASM 候选/保存/重开 → 实际浏览器和目标平台/游戏。尤其需要显式启用 Native 与外部目录夹具，区分通过、跳过、未运行；WASM 的 Node 合约不等于 Flutter 浏览器端到端交互。最终回归应覆盖最后一次修改，而不是沿用修改前的通过计数。

当前结论是“38 行狭义动作中 32 行本地已实现、2 行部分实现；另有 1 行真实服务阻塞与 3 行广泛未验证”。这一覆盖数不代表 viewer-app 全操作、全版本、全平台等价，也不把有界合约通过当作最终浏览器或游戏验收。
