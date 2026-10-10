import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart'
    show ChangeNotifier, Listenable, compute;
import 'package:flutter/services.dart' show rootBundle;

import '../domain/image_import.dart';
import '../domain/circuit_display.dart';
import '../platform/world_circuit_files.dart';
import '../domain/terraria_map.dart';
import '../engine/world_map_backend.dart';
import '../engine/map_backend.dart';

import '../domain/canvas_document.dart';
import '../domain/circuit_document.dart';
import '../domain/circuit_edit_plan.dart';
import '../engine/circuit_backend.dart';
import '../engine/circuit_rules_backend.dart';
import 'circuit_rules_workspace.dart';
import '../engine/world_circuit_backend.dart';
import '../engine/world_circuit_session.dart';
import '../domain/achievements.dart';
import '../domain/achievement_catalog.dart';
import '../domain/bestiary_tools.dart';
import '../domain/map_markers.dart';
import '../domain/world_rules.dart';
import '../domain/world_rule_presets.dart';
import '../domain/named_scheme_library.dart';
import '../domain/save_record.dart';
import '../domain/chest_tools.dart';
import '../domain/prefix_rules.dart';
import '../domain/resource_catalog.dart';
import '../domain/fusion_document.dart';
import '../domain/fusion_placement.dart';
import '../domain/world_stamp.dart';
import '../domain/region_document.dart';
import '../domain/world_circuit_geometry.dart';
import '../domain/region_brush.dart';
import '../domain/world_map_overlay.dart';
import '../domain/terrain_rule_plan.dart';
import '../engine/region_backend.dart';
import '../cloud/cloud.dart';
import '../resources/online_resource_service.dart';
import '../domain/player_conversion.dart';
import '../domain/player_tools.dart';
import '../domain/vault_history.dart';
import '../engine/player_projection_backend.dart';
import '../engine/engine.dart';
import '../platform/files.dart';
import '../platform/vault.dart';
import '../platform/resource_store.dart';
import '../ui/terra_contract.dart';

class Workspace extends TerraController {
  final ChangeNotifier _workspaceChanges = ChangeNotifier();
  @override
  Listenable get workspaceChanges => _workspaceChanges;
  @override
  Listenable get worldCircuitChanges => this;
  CircuitRulesWorkspace? _rules;
  CircuitRulesWorkspace get _rulesWorkspace {
    if (_rules != null) return _rules!;
    final rules = CircuitRulesWorkspace(
      backend: engine is CircuitRulesBackend
          ? engine as CircuitRulesBackend
          : null,
      files: files,
      persist: _persistArtifact,
      canSchedule: () => !_busy,
    );
    rules.addListener(notifyListeners);
    return _rules = rules;
  }

  final TerraEngine engine;
  final FileGateway files;
  final WorldCircuitFileGateway worldCircuitFiles;
  final LocalVault? vault;
  final CircuitBackend? circuitBackend;
  final WorldCircuitBackend? worldCircuitBackend;
  final RegionBackend? regionBackend;
  final CloudBackend? cloud;
  final OnlineResourceService? onlineResources;
  final PlayerProjectionBackend? playerProjectionBackend;
  final MapBackend mapBackend;
  MapSessionInfo? _map;
  TerrariaMapRaster? _mapRaster;
  String _mapName = 'exploration.map';
  Uint8List? _conversionBytes;
  String? _conversionSourceHash;
  PlayerConversionPreview? _conversionReview;
  PickedFile? _pendingCloudUpload;
  CloudSession? _pendingCloudSession;
  AdvancedRegionDocument? _region;
  RegionBrush? _regionBrush;
  FusionPlacementPlan? _placement;
  AdvancedRegionDocument? _placementRegion;
  AdvancedRegionDocument? _placementFragment;
  int? _placementRevision, _placementWorldX, _placementWorldY;
  String? _placementWorldHash, _placementWorldId;
  int _regionX = 0, _regionY = 0;
  String? _regionCompanionWarning;
  WorldCircuitSession? _worldCircuit;
  Future<void>? _worldCircuitClosing;
  Future<void>? _worldCircuitExportDrained;
  final Map<String, WorldCircuitSource> _pendingCircuitSourceReleases = {};
  bool _circuitSourceCleanupFailed = false;
  bool _closingWorkspace = false, _disposed = false;
  WorldCircuitSource? _circuitSource;
  int _circuitImportGeneration = 0;
  bool _circuitImporting = false;
  bool _circuitCancelling = false;
  WorldCircuitProgress? _circuitLoadProgress;
  String? _circuitLoadError;
  WorldCircuitFragmentPage? _worldFragments;
  WorldCircuitGeometry? _worldGeometry;
  Map<String, Object?> _circuitWorldMetadata = {};
  Map<String, int> _circuitViewport = {};
  Map<String, int>? _pendingCircuitViewport;
  Uint8List _worldCircuitRecords = Uint8List(0);
  FusionDocument _fusion = FusionDocument(40, 24);
  CircuitDocument _circuit = CircuitDocument(width: 32, height: 20);
  CircuitEditSession? _circuitEdits;
  CircuitEditSession get _circuitEditor {
    final backend = circuitBackend;
    if (backend == null) throw const EngineException('当前平台未加载电路引擎。');
    if (_circuitEdits == null ||
        !identical(_circuitEdits!.document, _circuit)) {
      _circuitEdits = CircuitEditSession(_circuit, backend);
    }
    return _circuitEdits!;
  }

  CircuitSimulator? _simulation;
  Timer? _circuitTimer;
  CircuitSimulator get _sim {
    if (circuitBackend == null) {
      throw const EngineException('电路引擎未加载。');
    }
    return _simulation ??= CircuitSimulator(_circuit, circuitBackend!);
  }

  final Map<String, VaultEntry> _vaultEntries = {};
  Workspace({
    required this.engine,
    required this.files,
    WorldCircuitFileGateway? worldCircuitFiles,
    this.vault,
    this.circuitBackend,
    this.worldCircuitBackend,
    this.regionBackend,
    this.cloud,
    this.onlineResources,
    this.playerProjectionBackend,
    MapBackend? mapBackend,
  }) : mapBackend = mapBackend ?? createMapBackend(),
       worldCircuitFiles = worldCircuitFiles ?? createWorldCircuitFiles() {
    onlineResources?.addListener(_onlineResourcesChanged);
  }
  Future<void> initialize() async {
    await onlineResources?.initialize();
    if (onlineResources?.activeStore != null) _activateOnlineResources();
    if (vault == null) {
      notifyListeners();
      return;
    }
    _busy = true;
    _status = '正在恢复本地资料…';
    notifyListeners();
    try {
      for (final e in await vault!.list()) {
        _vaultEntries[e.id] = e;
      }
      final markerEntries =
          _vaultEntries.values.where(_isMarkerPreference).toList()
            ..sort((a, b) => b.id.compareTo(a.id));
      if (markerEntries.isNotEmpty) {
        final markerEntry = markerEntries.first;
        _markerSequence = int.tryParse(markerEntry.id.split('-').last) ?? 0;
        final bytes = await vault!.read(markerEntry.id);
        if (bytes.length > MapMarkerProfile.maxJsonBytes) {
          throw const FormatException('标记偏好超过大小上限。');
        }
        _markerProfile = MapMarkerProfile.decode(utf8.decode(bytes));
      }
      final schemes =
          _vaultEntries.values.where(_isWorldRulePreference).toList()
            ..sort((a, b) => b.id.compareTo(a.id));
      if (schemes.isNotEmpty) {
        _worldRuleSequence =
            int.tryParse(schemes.first.id.split('-').last) ?? 0;
        final bytes = await vault!.read(schemes.first.id);
        if (bytes.length > WorldRuleScheme.maxJsonBytes) {
          throw const FormatException('世界规则偏好超过大小上限。');
        }
        _worldRuleScheme = WorldRuleScheme.decode(utf8.decode(bytes));
      }
      for (final kind in NamedSchemeKind.values) {
        final entries =
            _vaultEntries.values
                .where(
                  (e) => e.id.startsWith('preferences-schemes-${kind.name}-'),
                )
                .toList()
              ..sort((a, b) => b.id.compareTo(a.id));
        if (entries.isEmpty) continue;
        final entry = entries.first;
        if (entry.size > NamedSchemeLibrary.maxJsonBytes) {
          throw const FormatException('方案库超过大小上限。');
        }
        _schemeSequences[kind] = int.tryParse(entry.id.split('-').last) ?? 0;
        var library = NamedSchemeLibrary.decode(
          utf8.decode(await vault!.read(entry.id)),
        );
        if (library.kind != kind) throw const FormatException('方案库类型不匹配。');
        if (library.defaultId != null) {
          library = library.select(library.defaultId!);
        }
        _setSchemeLibrary(library);
        _activateScheme(library);
      }
      final packs =
          _vaultEntries.values.where((e) => e.kind == 'resources').toList()
            ..sort((a, b) => b.modified.compareTo(a.modified));
      if (packs.isNotEmpty && _resources == null) {
        _resources = await compute(
          ResourceStore.importPack,
          await vault!.read(packs.first.id),
        );
      }
      _status = '本地存档已就绪。';
    } catch (e) {
      _error = '本地存档不可用：$e';
    } finally {
      _resourceOperationGuard = null;
      _circuitCancelling = false;
      _busy = false;
    }
    notifyListeners();
  }

  final Map<String, CanvasDocument> _canvases = {
    'pixel': CanvasDocument(34, 22),
    'fusion': CanvasDocument(40, 24),
    'circuit': CanvasDocument(32, 20),
  };
  final List<SaveRecord> _records = [];
  final List<Map<String, Object?>> _changes = [];
  final List<Map<String, Object?>> _mapping = [];
  NamedSchemeLibrary _mappingSchemes = NamedSchemeLibrary(
    kind: NamedSchemeKind.mapping,
  ).create(name: '默认映射');
  NamedSchemeLibrary _worldRuleSchemes = NamedSchemeLibrary(
    kind: NamedSchemeKind.worldRules,
  ).create(name: '我的世界规则');
  final Map<NamedSchemeKind, int> _schemeSequences = {};
  final List<Map<String, Object?>> _catalog = [];
  ResourceStore? _resourceStore;
  void Function()? _onlineResourceGuard;
  void Function()? _resourceOperationGuard;
  ResourceStore? get _resources {
    _onlineResourceGuard?.call();
    if (_busy) _resourceOperationGuard ??= _onlineResourceGuard;
    return _resourceStore;
  }

  set _resources(ResourceStore? store) {
    _onlineResourceGuard = null;
    _resourceStore = store;
  }

  void _activateOnlineResources() {
    final service = onlineResources, store = onlineResources?.activeStore;
    if (service == null || store == null) {
      throw const FormatException('没有可启用的已验证线上资源。');
    }
    service.assertActiveUsable();
    _resourceStore = store;
    _onlineResourceGuard = () {
      service.assertActiveUsable();
      if (!identical(service.activeStore, store)) {
        throw const FormatException('线上资源版本已变化，请重新启用。');
      }
    };
  }

  void _onlineResourcesChanged() {
    if (_onlineResourceGuard != null) {
      try {
        _onlineResourceGuard!();
      } catch (_) {
        _resources = null;
        _regionBrush = null;
        _clearFusionPlacement();
        _terrainPlan = null;
        _worldGeometry = null;
        _worldFragments = null;
        _status = '线上资源已停用，请检查资源审批状态或重新安装。';
      }
    }
    notifyListeners();
  }

  EngineDocument? _world, _player;
  SaveRecord? _activeWorld, _activePlayer;
  Uint8List? _preview, _basePreview;
  MapMarkerProfile _markerProfile = MapMarkerProfile();
  bool _markersVisible = false;
  static const _markerPreferenceId = 'preferences-markers';
  int _markerSequence = 0, _worldRuleSequence = 0;
  static const _worldRulePreferenceId = 'preferences-world-rules';
  WorldRuleScheme _worldRuleScheme = WorldRuleScheme(name: '我的世界规则');
  Uint8List? _worldRuleCandidate, _worldRulePreviewPng;
  String? _worldRuleSourceId,
      _worldRuleSourceHash,
      _worldRuleFingerprint,
      _worldRuleSourceName;
  bool _isWorldRulePreference(VaultEntry entry) =>
      entry.id.startsWith('$_worldRulePreferenceId-');
  bool _isInternalPreference(VaultEntry entry) =>
      _isMarkerPreference(entry) ||
      _isWorldRulePreference(entry) ||
      // Retain legacy internal records without restoring fixture-specific state.
      entry.id.startsWith('preferences-computer-provenance-') ||
      entry.id.startsWith('preferences-schemes-');

  bool _isMarkerPreference(VaultEntry entry) =>
      entry.id == _markerPreferenceId ||
      entry.id.startsWith('$_markerPreferenceId-');
  WorldMapOverlay? _worldOverlay;
  Map<String, Object?> _lastWorldMetadata = {};
  final Map<String, Map<String, String>> _chestBaselines = {};
  Set<int> _modifiedChests = {};
  TerrainRulePlan? _terrainPlan;
  AdvancedRegionDocument? _terrainPlanRegion;
  String? _terrainPlanRules;
  AchievementFile? _achievements;
  bool _busy = false;
  String _status = '选择存档，或从空白画布开始。', _error = '', _activeCanvas = 'pixel';
  Map<String, Object?> _result = {};
  @override
  Map<String, Object?> get worldCircuitView => {
    'open': _worldCircuit?.result != null,
    'streamingAvailable': worldCircuitBackend is WorldCircuitSourceBackend,
    'sourceName': _circuitSource?.name,
    'sourceBytes': _circuitSource?.length,
    'importing': _circuitImporting,
    'cancelling': _circuitCancelling,
    'streamed': _worldCircuit?.streamed ?? false,
    'displayRegion': _worldCircuit?.displayRegion == null ? null : {
      'name': _worldCircuit!.displayRegion!.name,
      'x': _worldCircuit!.displayRegion!.x,
      'y': _worldCircuit!.displayRegion!.y,
      'width': _worldCircuit!.displayRegion!.width,
      'height': _worldCircuit!.displayRegion!.height,
    },
    'displayFrame': _worldCircuit?.displayFrame,
    'displayPixelCount': _worldCircuit?.displayPixelCount ?? 0,
    'displayIdentity': _worldCircuit?.displayIdentity,
    'progress': _worldCircuit?.progress,
    'loadProgress': _circuitLoadProgress,
    'loadError': _circuitLoadError,
    'busy': _busy || (_worldCircuit?.busy ?? false),
    'running': _worldCircuit?.running ?? false,
    'optimizationEnabled': _worldCircuit?.optimizationEnabled ?? false,
    'optimizationSupported': _worldCircuit?.optimizationSupported ?? false,
    'wireHeadPixelRulesEnabled':
        _worldCircuit?.wireHeadPixelRulesEnabled ?? false,
    'dirty': _worldCircuit?.dirty ?? false,
    'error': _worldCircuit?.error?.toString() ?? _circuitLoadError,
    'width': _worldCircuit?.result?.width,
    'height': _worldCircuit?.result?.height,
    'ticks': _worldCircuit?.result?.ticks ?? 0,
    'devices': _worldCircuit?.result?.devices ?? 0,
    'networks': _worldCircuit?.result?.networks ?? 0,
    'wireCells': _worldCircuit?.result?.stats[10] ?? 0,
    'netPulses': _worldCircuit?.result?.netPulses ?? 0,
    'records': _worldCircuitRecords,
    'viewport': _circuitViewport,
    if (_worldFragments != null)
      'fragments': {
        'offset': _worldFragments!.offset,
        'total': _worldFragments!.total,
        'hasMore': _worldFragments!.hasMore,
        'items': [
          for (final f in _worldFragments!.fragments)
            {
              'id': f.id,
              'x': f.x,
              'y': f.y,
              'width': f.width,
              'height': f.height,
              'cells': f.cells,
              'wireCells': f.wireCells,
              'canStamp': f.canStamp,
              'complete': f.completeFootprint,
              'modded': f.isModded,
              'missingSupport': f.missingSupport,
            },
        ],
      },
  };

  @override
  TerraViewState get view => hostStages.measure(
    'workspace.view',
    () => TerraViewState(
      busy: _busy || (_rules?.state['busy'] == true),
      circuitRunning: _circuitTimer != null,
      circuitTick: _simulation?.tick ?? 0,
      status: _circuitSourceCleanupFailed
          ? '$_status 临时导出文件清理失败，已保留以便关闭、重置或下次导出时重试。'
          : _status,
      error: _error,
      world: _worldView,
      player: _playerView,
      worldPreview: _preview,
      worldOverlay: _worldOverlay,
      markerProfile: _markerProfile,
      worldRuleScheme: _worldRuleScheme,
      mappingSchemes: _mappingSchemes,
      worldRuleSchemes: _worldRuleSchemes,
      worldRulePreviewPng: _worldRulePreviewPng,
      resources: _resources,
      region: _region,
      cloud: cloud,
      onlineResources: onlineResources,
      map: _map,
      mapRaster: _mapRaster,
      canGenerateWorldMap: engine is WorldMapBackend && _world != null,
      files: [
        ..._records.map(
          (r) => TerraFile(
            id: r.id,
            name: r.name,
            kind: r.kind,
            detail: r.modified ? '有已验证的修改' : '原件已保留',
          ),
        ),
        ..._vaultEntries.values
            .where(
              (e) =>
                  !VaultHistory.isTrashed(e) &&
                  !_isInternalPreference(e) &&
                  !_records.any((r) => r.id == e.id),
            )
            .map(
              (e) => TerraFile(
                id: e.id,
                name: e.name,
                kind: e.kind,
                detail: '本地持久存档 · ${e.size} 字节',
              ),
            ),
      ],
      canvases: {
        ..._canvases.map(
          (k, v) => MapEntry(
            k,
            TerraCanvas(width: v.width, height: v.height, colors: v.pixels),
          ),
        ),
        'circuit': _circuitCanvas,
        'fusion': _fusionCanvas,
      },
      canUndo:
          (_region?.canUndo ?? false) ||
          _fusion.canUndo ||
          _circuit.canUndo ||
          (_canvases[_activeCanvas]?.canUndo ?? false) ||
          (_activeWorld?.canUndo ?? false) ||
          (_activePlayer?.canUndo ?? false),
      canRedo:
          (_region?.canRedo ?? false) ||
          _fusion.canRedo ||
          _circuit.canRedo ||
          (_canvases[_activeCanvas]?.canRedo ?? false) ||
          (_activeWorld?.canRedo ?? false) ||
          (_activePlayer?.canRedo ?? false),
      stagedCount: _changes.length,
      changes: List.unmodifiable(_changes),
      mapping: List.unmodifiable(_mapping),
      catalog: List.unmodifiable(_catalog),
      result: {
        'rulesCircuit':
            _rules?.state ?? const {'ready': false, 'busy': false, 'error': ''},
        ..._result,
        'terrainPlan': _terrainPlan == null
            ? null
            : {
                'changedCells': _terrainPlan!.changedCells,
                'blockChanges': _terrainPlan!.blockChanges,
                'wallChanges': _terrainPlan!.wallChanges,
                'matchedCounts': _terrainPlan!.matchedCounts,
                'stale':
                    !identical(_region, _terrainPlanRegion) ||
                    _region?.revision != _terrainPlan!.sourceRevision,
              },
        'worldRulesPreview': _worldRuleCandidate == null
            ? null
            : {
                'bytes': _worldRuleCandidate!.length,
                'sourceName': _worldRuleSourceName,
                'fingerprint': _worldRuleFingerprint,
                'stale':
                    _activeWorld?.id != _worldRuleSourceId ||
                    _activeWorld?.currentHash != _worldRuleSourceHash,
              },
        'markersVisible': _markersVisible,
        'markers': [
          for (final marker in _markerProfile.markers)
            if (marker.kind == 'item') marker.id,
        ],
        'chestRulesVerified': _verifiedChestCatalog != null,
        'bestiaryRulesVerified': _verifiedBestiaryCatalog != null,
        'modifiedChests': _modifiedChests.toList(growable: false),
        'worldCanUndo': _activeWorld?.canUndo ?? false,
        'worldCanRedo': _activeWorld?.canRedo ?? false,
        'worldModified': _activeWorld?.modified ?? false,
        'vaultEntries': _vaultEntries.values
            .where((e) => !_isInternalPreference(e))
            .toList(),
        'conversion': _conversionReview == null
            ? null
            : {
                'target': _conversionReview!.projected['version'],
                'blocked': _conversionReview!.gameplayCompatibilityBlocked,
                'blockers': _conversionReview!.blockers,
                'changes': _conversionReview!.changes
                    .map(
                      (c) => {
                        'path': c.path,
                        'before': c.before,
                        'after': c.after,
                        'removed': c.removed,
                      },
                    )
                    .toList(),
              },
        'pendingCloudUpload': _pendingCloudUpload == null
            ? null
            : {
                'name': _pendingCloudUpload!.name,
                'bytes': _pendingCloudUpload!.bytes.length,
              },
        'cloudDestination': cloud?.api is HttpCloudApi
            ? (cloud!.api as HttpCloudApi).config.baseUri.origin
            : '已配置云端服务',
        'regionTile': _region?.cellAt(_regionX, _regionY),
        'regionCompanionWarning': _regionCompanionWarning,
        'regionBrush': _regionBrush?.intent,
        if (_placement != null)
          'fusionPlacement': {
            'width': _placement!.width,
            'height': _placement!.height,
            'x': _placementWorldX,
            'y': _placementWorldY,
            'stale': !_placementIsCurrent,
          },
        'worldCircuit': worldCircuitView,
        'history': _vaultEntries.values
            .where((e) => !_isInternalPreference(e))
            .map(
              (e) => {
                'name': e.name,
                'type': e.kind,
                'modified': e.modified.toLocal().toIso8601String(),
                'bytes': e.size,
              },
            )
            .toList(),
        'circuitCells': _circuit.cells.entries
            .map(
              (e) => {
                ...e.value.toJson(e.key),
                'on': _simulation?.states[e.key] ?? e.value.initialOn,
              },
            )
            .toList(),
        'circuitTrace': _simulation?.trace.toList() ?? [],
        if (circuitBackend != null) 'circuitEditor': _circuitEditor.snapshot(),
        'circuitStates': _simulation?.states ?? {},
        'achievements':
            _achievements?.records
                .map(
                  (r) => {
                    'id': r.id,
                    'completed': r.completed,
                    'editable': r.editable,
                    'conditions': r.conditions
                        .map(
                          (c) => {
                            'id': c.id,
                            'kind': c.kind,
                            'value': c.value,
                            'completed': c.completed,
                            'editable': c.editable,
                          },
                        )
                        .toList(),
                  },
                )
                .toList() ??
            [],
      },
    ),
  );
  @override
  Future<void> dispatch(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_disposed) return;
    if (action == 'worldCircuitCancel') {
      _circuitImportGeneration++;
      _circuitCancelling = true;
      _status = '正在取消；等待引擎释放当前操作…';
      notifyListeners();
      await _worldCircuit?.cancelOperation();
      return;
    }
    if (action == 'worldCircuitPause') {
      await _pauseWorldCircuit();
      return;
    }
    if (action.startsWith('rules')) {
      if (_busy &&
          action != 'rulesClose' &&
          action != 'rulesToggleRun' &&
          action != 'rulesPause' &&
          action != 'rulesCancelPreview') {
        return;
      }
      _stopCircuit();
      _worldCircuit?.pause();
      await _rulesWorkspace.dispatch(action, args);
      return;
    }
    if (action == 'circuitCancelEdit') {
      _circuitEdits?.cancelPreview();
      _status = '电路预览已取消，原设计保持不变。';
      notifyListeners();
      return;
    }
    if (action == 'dismissError') {
      _error = '';
      notifyListeners();
      return;
    }
    if (_busy || (_rules?.state['busy'] == true)) {
      return;
    }
    _error = '';
    _resourceOperationGuard = _onlineResourceGuard;
    final fast = {'paint', 'strokeStart', 'strokeEnd', 'clear', 'resize'};
    if (!fast.contains(action)) {
      _busy = true;
      notifyListeners();
    }
    try {
      switch (action) {
        case 'importMap':
          final picked = await files.pick('map');
          if (picked == null) {
            _status = '已取消选择 MAP。';
            break;
          }
          await _openMapBytes(picked.name, picked.bytes);
          await _persistArtifact(picked.name, 'map', picked.bytes);
        case 'editMapRect':
          final map = _requireMap();
          _map = await mapBackend.editRect(
            _bounded(args, 'x', 0, map.width - 1),
            _bounded(args, 'y', 0, map.height - 1),
            _bounded(args, 'width', 1, map.width),
            _bounded(args, 'height', 1, map.height),
            light: args['light'] == null
                ? null
                : _bounded(args, 'light', 0, 255),
            color: args['color'] == null
                ? null
                : _bounded(args, 'color', 0, 31),
          );
          _mapRaster = await mapBackend.render();
          _status = 'MAP 探索数据已更新，可撤销或导出副本。';
        case 'undoMap':
          _requireMap();
          _map = await mapBackend.undo();
          _mapRaster = await mapBackend.render();
          _status = '已撤销 MAP 区域修改。';
        case 'redoMap':
          _requireMap();
          _map = await mapBackend.redo();
          _mapRaster = await mapBackend.render();
          _status = '已重做 MAP 区域修改。';
        case 'closeMap':
          await mapBackend.close();
          _map = null;
          _mapRaster = null;
          _status = 'MAP 会话已关闭，本地已保存副本保留。';
        case 'exportMap':
          _requireMap();
          final bytes = await mapBackend.exportVerified();
          final stem = _mapName.replaceFirst(
            RegExp(r'\.map(\.bak)?$', caseSensitive: false),
            '',
          );
          final name = '${stem}_terraforge.map';
          await _persistArtifact(name, 'map', bytes);
          _status = await files.save(name, bytes)
              ? 'MAP 副本已完整回读验证并交给系统保存。'
              : '已取消系统保存，MAP 编辑仍保留在当前会话。';
        case 'generateMapFromWorld':
          await _generateMapFromWorld();
        case 'terrainPreview':
          _previewTerrainRules();
        case 'terrainApply':
          _applyTerrainRules(args);
        case 'worldPresetClone':
          final catalog = _resources?.catalog;
          if (catalog == null) throw const EngineException('请先导入带世界预设的核验资源包。');
          final preset = WorldRulePresets.fromCatalog(
            catalog,
            expectedVersion: '1.4.5.8',
          ).byId(args['id'] as String);
          if (preset == null) throw const EngineException('预设不存在或来源未核验。');
          final name = _worldRuleSchemes.uniqueName(
            args['name'] as String? ?? '${preset.name} 副本',
          );
          final scheme = preset.editableCopy(name: name);
          final library = _worldRuleSchemes.create(
            name: name,
            payload: scheme.toJson(),
          );
          await _persistSchemeLibrary(library);
          _setSchemeLibrary(library);
          _activateScheme(library);
          _status = '已从已核验目录创建可编辑预设副本，世界尚未改变。';
        case 'worldRulesSave':
          await _saveWorldRules(WorldRuleScheme.fromJson(args['scheme']));
        case 'worldRulesPreview':
          await _previewWorldRules(WorldRuleScheme.fromJson(args['scheme']));
        case 'worldRulesApply':
          await _applyWorldRules(
            WorldRuleScheme.fromJson(args['scheme']),
            confirmed: args['confirmed'] == true,
          );
        case 'worldOverlay':
          await _readWorldOverlay(args);
        case 'worldCircuitChooseWorld':
          await _chooseCircuitSource();
        case 'worldCircuitImport':
          await _importCircuitSource();
        case 'worldCircuitReadDisplay':
          await _readCircuitDisplay(args);
        case 'worldCircuitRefreshDisplay':
          await _worldCircuit?.refreshDisplay();
        case 'worldCircuitOpen':
          await _openWorldCircuit();
        case 'worldCircuitFragments':
          final session = _worldCircuit;
          if (session == null) throw const EngineException('请先载入世界电路。');
          _worldFragments = await session.fragments(
            offset: _bounded(args, 'offset', 0, 2147483647, fallback: 0),
            count: 256,
            geometry: _worldGeometry?.records ?? const [],
          );
          _status = '已读取真实电路片段；选择片段可提取完整图层与伴随对象。';
        case 'worldCircuitLocateFragment':
          await _locateWorldCircuitFragment(args['id'] as int);
        case 'worldCircuitExtract':
          await _extractWorldCircuitFragment(args['id'] as int);
        case 'worldCircuitToggle':
          final session = _worldCircuit;
          if (session == null) {
            throw const EngineException('请先载入世界电路。');
          }
          if (session.running) {
            await _pauseWorldCircuit();
          } else {
            session.run();
          }
        case 'worldCircuitOptimization':
          final session = _worldCircuit;
          if (session == null) throw const EngineException('请先载入世界电路。');
          await session.setOptimization(args['enabled'] == true);
          _status = session.optimizationEnabled
              ? '电路优化已开启：设备去重与 WireHead 式像素规则。现有电路状态保留，后续运行结果可能不同。'
              : '电路优化已关闭：使用原版像素规则。现有电路状态保留，后续运行结果可能不同。';
        case 'worldCircuitStep':
          await _worldCircuitCommand(WorldCircuitCommand.ticks(1));
        case 'worldCircuitTrigger':
          await _worldCircuitCommand(
            WorldCircuitCommand.trigger(
              _bounded(args, 'x', 0, (_worldCircuit?.result?.width ?? 1) - 1),
              _bounded(args, 'y', 0, (_worldCircuit?.result?.height ?? 1) - 1),
              mask: _bounded(args, 'mask', 1, 15, fallback: 15),
              hitSwitch: args['direct'] != true,
            ),
          );
        case 'worldCircuitViewport':
          await _viewWorldCircuit(args);
        case 'worldCircuitReset':
          final session = _worldCircuit;
          if (session == null) {
            throw const EngineException('请先载入世界电路。');
          }
          final resetGeneration = _circuitImportGeneration;
          session.pause();
          await _releasePendingCircuitSources();
          if (resetGeneration != _circuitImportGeneration) {
            throw StateError('世界重置已取消，当前会话已暂停。');
          }
          try {
            await session.reset();
            if (resetGeneration != _circuitImportGeneration) {
              await _closeWorldCircuit();
              throw StateError('世界重置已取消，原始文件保留，可重新导入。');
            }
          } catch (_) {
            // A cancelled/failed replacement import has no usable session.
            // Finish its cleanup so the retained picker source can be retried.
            if (session.result == null) await _closeWorldCircuit();
            if (resetGeneration != _circuitImportGeneration) {
              _status = '已取消重置，原始世界保留，可重新导入。';
            }
            rethrow;
          }
          await _locateInitialCircuitViewport();
          _status = '已从原始 WLD 重新加载实际电路，优化默认关闭。';
        case 'worldCircuitSave':
          await _saveWorldCircuit();
        case 'worldCircuitClose':
          if ((_worldCircuit?.dirty ?? false) && args['discard'] != true) {
            throw const EngineException('关闭前请保存或明确舍弃电路修改。');
          }
          await _closeWorldCircuit();
        case 'fusionPlace':
          _stageFusionPlacement(args);
        case 'fusionInsert':
          await _insertFusionPlacement(confirmed: args['confirmed'] == true);
        case 'fusionDiscardPlacement':
          if (_placementRegion != null &&
              identical(_placementRegion, _region) &&
              _region!.revision == _placementRevision) {
            _region!.undo();
          }
          _clearFusionPlacement();
        case 'regionBrush':
          _region?.endStroke();
          _regionBrush = RegionBrush.fromIntent(args);
          _status = '图层画笔已选择；在融合区域拖动绘制，一笔可整体撤销。';
        case 'regionBrushClear':
          _region?.endStroke();
          _regionBrush = null;
        case 'regionSelect':
          _regionX = _bounded(args, 'x', 0, (_region?.width ?? 1) - 1);
          _regionY = _bounded(args, 'y', 0, (_region?.height ?? 1) - 1);
        case 'regionEdit':
          final region = _region;
          if (region == null) {
            throw const EngineException('请先读取世界选区。');
          }
          region.setCell(
            _regionX,
            _regionY,
            Map<String, int>.from(args['patch'] as Map),
          );
        case 'pixelMatch':
          await _matchPixelColors(args);
        case 'openSynthetic':
          if (!const bool.fromEnvironment('TERRAFORGE_QA')) {
            throw const EngineException('测试入口未启用。');
          }
          final name = args['kind'] == 'circuit'
              ? 'synthetic-circuit.wld'
              : 'synthetic-objects.wld';
          final data = await rootBundle.load('assets/qa/$name');
          await _openBytes(
            name,
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            'wld',
          );
        case 'cloudPrepareUpload':
          _pendingCloudUpload = null;
          _pendingCloudSession = null;
          final backend = cloud;
          if (backend?.connected != true) {
            throw const EngineException('云端尚未连接。');
          }
          final owner = backend!.session;
          final picked = await files.pick('save');
          if (picked != null) {
            if (!backend.connected || !identical(owner, backend.session)) {
              throw const CloudFailure('云端账户已变化，请重新选择文件。');
            }
            cloudFileName(picked.name);
            if (!RegExp(
              r'\.(wld|plr)(\.bak)?$',
              caseSensitive: false,
            ).hasMatch(picked.name)) {
              throw const CloudFailure('请选择 .wld 或 .plr 存档。');
            }
            final remoteName = picked.name.replaceFirst(
              RegExp(r'\.bak$', caseSensitive: false),
              '',
            );
            if (remoteName.length > 180) {
              throw const CloudFailure('云端文件名不能超过 180 个字符。');
            }
            _pendingCloudUpload = PickedFile(
              remoteName,
              Uint8List.fromList(picked.bytes),
            );
            _pendingCloudSession = owner;
          }
        case 'cloudDiscardUpload':
          _pendingCloudUpload = null;
          _pendingCloudSession = null;
        case 'cloudUploadPrepared':
          final pending = _pendingCloudUpload, backend = cloud;
          if (pending == null ||
              backend?.connected != true ||
              !identical(_pendingCloudSession, backend!.session)) {
            _pendingCloudUpload = null;
            _pendingCloudSession = null;
            throw const EngineException('没有待上传文件或原云端会话已变化。');
          }
          try {
            await backend.uploadFile(
              pending.bytes,
              pending.name,
              RegExp(
                    r'\.wld(\.bak)?$',
                    caseSensitive: false,
                  ).hasMatch(pending.name)
                  ? 'world'
                  : 'player',
              prepareWorldPreview: () =>
                  _renderCloudWorldPreview(pending.bytes),
            );
            _status = '云端已接收上传，请在列表核对文件。';
          } finally {
            _pendingCloudUpload = null;
            _pendingCloudSession = null;
          }
        case 'cloudDownload':
          final backend = cloud, save = args['save'] as CloudSave;
          if (backend?.connected != true) {
            throw const EngineException('云端尚未连接。');
          }
          final result = await backend!.downloadSave(save, _persistCloudFile);
          _status = await files.save(result.save.fileName, result.bytes)
              ? '文件已保存到本地存档库，导出副本已交给系统。'
              : '文件已保存到本地存档库；已取消额外导出。';
        case 'cloudRecommendationDownload':
          final backend = cloud, item = args['item'] as CloudRecommendation;
          if (backend?.connected != true) {
            throw const EngineException('云端尚未连接。');
          }
          final result = await backend!.downloadRecommendation(
            item,
            _persistCloudFile,
          );
          _status = result.receiptPending
              ? '推荐已保存到本地存档库，统计回执等待重试。'
              : '推荐已保存到本地存档库，可在存档中心打开或导出。';
        case 'preparePlayerConversion':
          await _preparePlayerConversion(_bounded(args, 'target', 38, 326));
        case 'applyPlayerConversion':
          await _applyPlayerConversion(args['confirmed'] == true);
        case 'cancelPlayerConversion':
          _conversionBytes = null;
          _conversionSourceHash = null;
          _conversionReview = null;
        case 'trashFile':
          await _moveVault(args['id'] as String, restore: false);
        case 'restoreFile':
          await _moveVault(args['id'] as String, restore: true);
        case 'activateOnlineResources':
          _activateOnlineResources();
          _status = '已启用经过校验的线上资源。';
        case 'clearResourceMemory':
          _resources = null;
          _status = '资源内存缓存已释放，本地资源包保留，可在存档中心重新打开。';
        case 'import':
          await _import(args['kind'] as String? ?? 'save');
        case 'export':
          await _export(args['kind'] as String? ?? 'world');
        case 'paint':
          if (args['canvas'] == 'fusion') {
            _paintFusion(args);
            break;
          }
          if (args['canvas'] == 'circuit') {
            _stopCircuit();
            final x = (args['x'] as num).toInt(),
                y = (args['y'] as num).toInt();
            if (args['tool'] == 'eraser') {
              _circuit.erase(x, y);
            } else {
              _circuit.paintWire(
                x,
                y,
                (args['wireColor'] as num?)?.toInt() ?? 0,
              );
            }
            _simulation = null;
            break;
          }
          final c = _canvas(args);
          final color = (args['color'] as num?)?.toInt() ?? 0xff9be7c1;
          c.paint(
            (args['x'] as num).toInt(),
            (args['y'] as num).toInt(),
            args['tool'] == 'eraser' || args['tool'] == 'erase' ? 0 : color,
            fill: args['tool'] == 'bucket' || args['tool'] == 'fill',
          );
        case 'strokeStart':
          if (args['canvas'] == 'fusion') {
            _region?.beginStroke();
            _fusion.beginStroke();
            break;
          }
          if (args['canvas'] == 'circuit') {
            _stopCircuit();
            _circuit.beginStroke();
          } else {
            _canvas(args).beginStroke();
          }
        case 'strokeEnd':
          if (args['canvas'] == 'fusion') {
            _region?.endStroke();
            _fusion.endStroke();
            break;
          }
          if (args['canvas'] == 'circuit') {
            _circuit.endStroke();
          } else {
            _canvas(args).endStroke();
          }
        case 'undo':
          await _undoRedo(args, false);
        case 'redo':
          await _undoRedo(args, true);
        case 'clear':
          if (args['canvas'] == 'fusion') {
            if (_region != null) {
              throw const EngineException('区域含完整图层/物件；请通过属性编辑清除需要的层，避免整片丢失实体。');
            }
            _fusion.clear();
            _status = '融合画布已清空，可撤销。';
            break;
          }
          if (args['canvas'] == 'circuit') {
            _stopCircuit();
            _circuit.clear();
            _simulation = null;
          } else {
            _canvas(args).clear();
          }
          _status = '画布已清空，可撤销。';
        case 'resize':
          if (args['canvas'] == 'fusion') {
            _region = null;
            _fusion = FusionDocument(
              _bounded(args, 'width', 1, 4096),
              _bounded(args, 'height', 1, 4096),
            );
            break;
          }
          if (args['canvas'] == 'circuit') {
            _stopCircuit();
            _circuit = CircuitDocument(
              width: (args['width'] as num).toInt(),
              height: (args['height'] as num).toInt(),
            );
            _simulation = null;
            break;
          }
          final c = _canvas(args);
          final w = (args['width'] as num).toInt(),
              h = (args['height'] as num).toInt();
          final next = CanvasDocument(w, h);
          final source = c.pixels, oldWidth = c.width, oldHeight = c.height;
          next.replace(
            w,
            h,
            List<int>.generate(w * h, (i) {
              final x = i % w, y = i ~/ w;
              return x < oldWidth && y < oldHeight
                  ? source[y * oldWidth + x]
                  : 0;
            }),
          );
          _canvases[_activeCanvas] = next;
          _status = '画布已调整为 $w × $h。';
        case 'stageWorld':
          await _edit(
            _world,
            _activeWorld,
            'header_patch',
            _mappedPatch(args, {'name': 'worldName', 'difficulty': 'gameMode'}),
          );
        case 'stagePlayer':
          await _edit(
            _player,
            _activePlayer,
            'player_patch',
            _mappedPatch(args, {'health': 'statLife', 'mana': 'statMana'}),
          );
        case 'playerSlotEdit':
          final group = args['group'] as String;
          final next = PlayerTools.replaceSlot(
            _playerView,
            group,
            args['index'] as int,
            Map<String, Object?>.from(args['slot'] as Map),
            loadout: args['loadout'] as int?,
            catalog: _verifiedPlayerCatalog,
          );
          final field = args['loadout'] == null ? group : 'loadouts';
          await _edit(_player, _activePlayer, 'player_patch', {
            field: next[field],
          });
        case 'playerBestPrefixes':
          if (args['confirmed'] != true) {
            throw const EngineException('请确认批量最佳前缀。');
          }
          final catalog = _verifiedPlayerCatalog;
          if (catalog == null) {
            throw const EngineException('请导入与角色版本匹配的物品和前缀目录。');
          }
          final result = PlayerTools.bestPrefixes(
            _playerView,
            groups: (args['groups'] as List).cast<String>(),
            rules: PrefixRules(catalog),
            loadout: args['loadout'] as int?,
          );
          if (result.changedItems == 0) {
            _status = '没有需要调整的已知物品前缀。';
          } else {
            await _edit(_player, _activePlayer, 'player_patch', {
              for (final group in result.changedGroups)
                group: result.player[group],
            });
            _status = '已调整 ${result.changedItems} 件物品前缀，可一次撤销。';
          }
        case 'achievementNew':
          if (args['confirmed'] != true) {
            throw const EngineException('请确认新建成就文件并替换当前编辑文档。');
          }
          await _acceptAchievements(
            _achievementCatalog(requireDefinitions: true).createFile(),
            '已按目录新建未解锁成就文件',
          );
        case 'achievementCondition':
          final doc = _achievements;
          if (doc == null) throw const EngineException('请先导入或新建成就文件。');
          final candidate = _achievementCatalog().applyCondition(
            doc,
            args['id'] as String,
            args['conditionId'] as String,
            value: args['value'] as num?,
            completed: args['completed'] as bool?,
          );
          await _acceptAchievements(candidate, '成就条件已更新');
        case 'achievementCompleteKnown':
          if (args['confirmed'] != true) {
            throw const EngineException('请先确认已知成就条件的批量完成。');
          }
          final doc = _achievements;
          if (doc == null) throw const EngineException('请先导入或新建成就文件。');
          final result = _achievementCatalog(requireDefinitions: true)
              .completeKnown(doc);
          await _acceptAchievements(
            result.file,
            '已更新 ${result.changed} 个条件，保留 ${result.skipped} 个未知或不匹配条件',
          );
        case 'achievementToggle':
          final doc = _achievements;
          if (doc == null) {
            throw const EngineException('请先导入 achievements.dat。');
          }
          final candidate = doc.clone()
            ..setCompleted(args['id'] as String, args['completed'] as bool);
          await _acceptAchievements(candidate, '成就状态已更新');
        case 'newPlayer':
          if (engine is! CreatablePlayerEngine) {
            throw const EngineException('当前引擎暂不支持新建角色。');
          }
          final doc = await (engine as CreatablePlayerEngine).createPlayer(
            args['name'] as String? ?? '探险者',
          );
          final bytes = await engine.save(doc);
          await engine.close(doc);
          await _openBytes('${args['name'] ?? '探险者'}.plr', bytes, 'plr');
        case 'openFile':
          final id = args['id'] as String;
          final matches = _records.where((r) => r.id == id);
          if (matches.isNotEmpty) {
            await _activate(matches.first);
          } else {
            final e = _vaultEntries[id];
            if (e == null || vault == null) {
              throw const EngineException('未找到本地记录。');
            }
            final bytes = await vault!.read(id);
            if (!{'wld', 'plr'}.contains(e.kind)) {
              if (e.kind == 'map') {
                await _openMapBytes(e.name, bytes);
                break;
              }
              if (e.kind == 'resources') {
                _resources = await compute(ResourceStore.importPack, bytes);
                _status = '已载入本地资源包。';
                break;
              }
              if (e.kind == 'achievements') {
                _achievements = AchievementFile.open(bytes);
              } else {
                final kind = await _loadProject(bytes);
                if (kind == 'markers') await _setMarkers(_markerProfile);
                if (kind == 'mapping') await _saveMappingScheme();
                if (kind == 'worldRules') {
                  await _saveWorldRules(_worldRuleScheme);
                }
              }
              _status = '已打开本地副本：${e.name}';
              break;
            }
            final r = SaveRecord(
              id: id,
              name: e.name,
              kind: e.kind,
              bytes: bytes,
            );
            await _activate(r);
            _records.add(r);
          }
        case 'validate':
          if ({'pixel', 'fusion', 'circuit'}.contains(args['source'])) {
            await _stamp(args, validateOnly: true);
            break;
          }
          final doc = _world;
          if (doc == null) {
            throw const EngineException('请先导入目标世界。');
          }
          final bytes = await engine.save(doc);
          await _validateRecord(_activeWorld!, bytes);
          _status = '候选世界已回读验证，原件未改动。';
          _result = {
            'validated': true,
            'validation': '候选文件回读通过',
            'bytes': bytes.length,
          };
        case 'mappingSave':
          final rules = args['rules'];
          if (rules is List) {
            final validated = _validRules(rules);
            _mapping
              ..clear()
              ..addAll(validated);
            _terrainPlan = null;
          } else if ({'pixel', 'fusion', 'circuit'}.contains(args['source'])) {
            _mapping.add(Map.of(args));
            _terrainPlan = null;
          } else {
            throw const FormatException('请填写映射规则。');
          }
          await _saveMappingScheme();
          _status = '映射已保存至当前方案，可导出 JSON。';
        case 'schemeCreate':
        case 'schemeClone':
        case 'schemeRename':
        case 'schemeSelect':
        case 'schemeSetDefault':
        case 'schemeDelete':
          await _handleSchemeAction(action, args);
        case 'locate':
          final x = _bounded(
                args,
                'x',
                0,
                ((_worldView['maxTilesX'] as num?)?.toInt() ?? 1) - 1,
              ),
              y = _bounded(
                args,
                'y',
                0,
                ((_worldView['maxTilesY'] as num?)?.toInt() ?? 1) - 1,
              );
          if (_world == null) {
            throw const EngineException('请先导入世界。');
          }
          _result = {
            ..._result,
            'location': {'x': x, 'y': y},
          };
          _status = '已选择坐标 X $x · Y $y。';
        case 'settings':
          _result = {..._result, '${args['key']}': args['value']};
          _status = '本次工作区设置已更新。';
        case 'generate':
          throw const EngineException('云端生成需要跨端账户和服务地址；当前未连接。参数不会被模拟提交。');
        case 'circuitSelect':
          _stopCircuit();
          _circuitEditor.selectRect(
            args['x'] as int,
            args['y'] as int,
            args['width'] as int,
            args['height'] as int,
          );
        case 'circuitCopy':
          _circuitEditor.copySelection();
        case 'circuitCut':
          _stopCircuit();
          _circuitEditor.cutSelection();
          _simulation = null;
        case 'circuitPaste':
          _stopCircuit();
          _circuitEditor.pasteClipboard(args['x'] as int, args['y'] as int);
          _simulation = null;
        case 'circuitRotate':
          _circuitEditor.transformClipboard(
            CircuitClipboardTransform.rotateClockwise,
          );
        case 'circuitMirror':
          _circuitEditor.transformClipboard(
            args['axis'] == 'vertical'
                ? CircuitClipboardTransform.mirrorVertical
                : CircuitClipboardTransform.mirrorHorizontal,
          );
        case 'circuitNetworkPreview':
          _stopCircuit();
          await _circuitEditor.previewNetwork(
            args['x'] as int,
            args['y'] as int,
            args['mask'] as int,
          );
        case 'circuitRoutePreview':
          _stopCircuit();
          await _circuitEditor.previewRoute(
            args['startX'] as int,
            args['startY'] as int,
            args['endX'] as int,
            args['endY'] as int,
            args['mask'] as int,
          );
        case 'circuitConfirmEdit':
          _stopCircuit();
          _circuitEditor.confirmPreview();
          _simulation = null;
        case 'circuitCancelEdit':
          _circuitEditor.cancelPreview();
        case 'circuitPlace':
          _stopCircuit();
          _circuit.placeElement(
            (args['x'] as num).toInt(),
            (args['y'] as num).toInt(),
            CircuitElement.values.byName(args['element'] as String),
            initialOn: args['initialOn'] == true,
            interval: _bounded(args, 'interval', 1, 36000, fallback: 60),
          );
          _simulation = null;
        case 'circuitTrigger':
          _stopCircuit();
          await _sim.trigger(
            (args['x'] as num).toInt(),
            (args['y'] as num).toInt(),
          );
        case 'circuitToggle':
          if (_circuitTimer != null) {
            _stopCircuit();
          } else {
            final sim = _sim;
            _circuitTimer = Timer.periodic(
              const Duration(microseconds: 16667),
              (_) async {
                if (sim.busy || _busy) {
                  return;
                }
                try {
                  await sim.step();
                  notifyListeners();
                } catch (e) {
                  _stopCircuit();
                  _error = '电路仿真停止：$e';
                  notifyListeners();
                }
              },
            );
          }
        case 'circuitStep':
          _stopCircuit();
          await _sim.step();
        case 'write':
          await _stamp(args);
        case 'fusionRegion':
          await _readFusion(args);
        case 'stageInventory':
          await _inventory(args);
        case 'chestOrganize':
          await _transformChests(args, 'organize');
        case 'chestClear':
          await _transformChests(args, 'clear');
        case 'chestBestPrefixes':
          await _transformChests(args, 'prefixes');
        case 'stageChest':
          await _chest(args);
        case 'bestiaryEntry':
          final catalog = _verifiedBestiaryCatalog;
          if (catalog == null) {
            throw const EngineException('逐项图鉴编辑需要与当前世界版本匹配的目录。');
          }
          final candidate = BestiaryTools.editEntry(
            _currentBestiary(),
            catalog: catalog,
            id: args['id'] as String,
            kind: args['kind'] as String,
            value: args['value'],
          );
          await _replaceBestiary(candidate);
        case 'bestiaryUnlockKnown':
          final catalog = _verifiedBestiaryCatalog;
          if (catalog == null) {
            throw const EngineException('批量解锁需要与当前世界版本匹配的图鉴目录。');
          }
          final candidate = BestiaryTools.unlockKnown(
            _currentBestiary(),
            catalog: catalog,
            confirmed: args['confirmed'] == true,
          );
          await _replaceBestiary(candidate);
        case 'stageBestiary':
          final patch = Map<String, Object?>.from(args['patch'] as Map);
          if (patch.keys.any(
            (k) => !{'kills', 'sightings', 'chats'}.contains(k),
          )) {
            throw const FormatException('图鉴字段无效。');
          }
          await _replaceBestiary({..._currentBestiary(), ...patch});
        case 'addMarker':
          final id = args['itemId'];
          if (id is! int) throw const FormatException('物品 ID 必须是整数。');
          await _setMarkers(_markerProfile.toggle('item', id));
        case 'markerToggle':
          if (args['kind'] is! String || args['id'] is! int) {
            throw const FormatException('标记类型或 ID 无效。');
          }
          await _setMarkers(
            _markerProfile.toggle(
              args['kind'] as String,
              args['id'] as int,
              selector: args['selector'] == null
                  ? null
                  : MapMarkerSelector.fromJson(args['selector']),
            ),
          );
        case 'markerStyle':
          await _setMarkers(
            _markerProfile.style(
              args['kind'] as String,
              args['id'] as int,
              color: args['color'] as String,
              radius: args['radius'] as int,
              lineWidth: args['lineWidth'] as int,
              selector: args['selector'] == null
                  ? null
                  : MapMarkerSelector.fromJson(args['selector']),
            ),
          );
        case 'markerRemove':
          await _setMarkers(
            _markerProfile.remove(
              args['kind'] as String,
              args['id'] as int,
              selector: args['selector'] == null
                  ? null
                  : MapMarkerSelector.fromJson(args['selector']),
            ),
          );
        case 'markerClear':
          if (args['confirmed'] != true) {
            throw const EngineException('请先确认清空标记方案。');
          }
          await _setMarkers(_markerProfile.clear());
        case 'markerRender':
          await _renderMarkers();
        case 'markerVisibility':
          if (args['visible'] == true) {
            await _renderMarkers();
          } else {
            _markersVisible = false;
            _preview = _basePreview;
          }
        default:
          throw EngineException('尚未实现的操作：$action');
      }
    } catch (e) {
      _error = e.toString().replaceFirst('FormatException: ', '');
    } finally {
      _resourceOperationGuard = null;
      _circuitCancelling = false;
      _busy = false;
      notifyListeners();
    }
  }

  TerraCanvas get _fusionCanvas {
    final region = _region;
    if (region != null) {
      final colors = List<int>.filled(region.width * region.height, 0);
      for (var i = 0; i < region.recordCount; i++) {
        final c = region.cellAtIndex(i);
        final id = c['block']!;
        colors[c['y']! * region.width + c['x']!] = c['active'] == 1
            ? 0xff000000 |
                  (((id * 73 + 80) & 255) << 16) |
                  (((id * 43 + 90) & 255) << 8) |
                  ((id * 29 + 110) & 255)
            : c['wall']! > 0
            ? 0xff344953
            : c['liquid']! > 0
            ? 0xff467cbb
            : 0;
      }
      return TerraCanvas(
        width: region.width,
        height: region.height,
        colors: colors,
      );
    }
    return TerraCanvas(
      width: _fusion.width,
      height: _fusion.height,
      colors: _fusion.cells.map((c) {
        if (c == null) {
          return 0;
        }
        if (c.block == -1) {
          return 0xff354854;
        }
        return switch (c.block) {
          0 => 0xff88684c,
          1 => 0xff88969a,
          2 => 0xff7aad7c,
          30 => 0xffad8b5e,
          _ => c.wall != null ? 0xff516878 : 0,
        };
      }).toList(),
    );
  }

  void _paintFusion(Map<String, Object?> args) {
    final region = _region;
    if (region != null) {
      if (_placement != null) throw const EngineException('请先确认或取消新物件的独立插入。');
      final x = _bounded(args, 'x', 0, region.width - 1),
          y = _bounded(args, 'y', 0, region.height - 1);
      _regionX = x;
      _regionY = y;
      if (_regionBrush != null) {
        if (args['tool'] == 'bucket') {
          throw const EngineException('图层画笔使用拖动绘制，不执行不明确的跨图层填充。');
        }
        final patch = _regionBrush!.patchFor(
          region.cellAt(x, y),
          catalog: _resources?.catalog,
        );
        if (patch != null) region.setCell(x, y, patch);
        return;
      }
      final brush = args['tool'] == 'eraser'
          ? RegionBrush.fromIntent({'kind': 'erase', 'layer': 'block'})
          : switch (args['material']) {
              'stone' => RegionBrush.block(1),
              'dirt' => RegionBrush.block(0),
              'wood' => RegionBrush.block(30),
              'wall' => RegionBrush.wall(1),
              'air' => RegionBrush.fromIntent({
                'kind': 'erase',
                'layer': 'block',
              }),
              _ => throw const FormatException('请选择支持的绘制材料。'),
            };
      if (args['tool'] == 'bucket') {
        throw const EngineException('完整区域请用选区属性编辑；批量填充需明确指定图层。');
      }
      final patch = brush.patchFor(
        region.cellAt(x, y),
        catalog: _resources?.catalog,
      );
      if (patch != null) region.setCell(x, y, patch);
      return;
    }
    final x = _bounded(args, 'x', 0, _fusion.width - 1),
        y = _bounded(args, 'y', 0, _fusion.height - 1);
    final StampCell? cell = args['tool'] == 'eraser'
        ? null
        : switch (args['material']) {
            'stone' => const StampCell(block: 1),
            'dirt' => const StampCell(block: 0),
            'wall' => const StampCell(wall: 1),
            'air' => const StampCell(block: -1),
            'wood' => const StampCell(block: 30),
            _ => throw const FormatException('当前融合画布仅支持木材、石块、土块、墙体及清除。'),
          };
    if (args['tool'] != 'bucket') {
      _fusion.paint(x, y, cell);
      return;
    }
    final pixels = _fusionCanvas.colors,
        old = pixels[y * _fusion.width + x],
        seen = <int>{y * _fusion.width + x},
        queue = <int>[y * _fusion.width + x];
    _fusion.beginStroke();
    for (var i = 0; i < queue.length; i++) {
      final at = queue[i], px = at % _fusion.width, py = at ~/ _fusion.width;
      _fusion.paint(px, py, cell);
      for (final n in [
        if (px > 0) at - 1,
        if (px + 1 < _fusion.width) at + 1,
        if (py > 0) at - _fusion.width,
        if (py + 1 < _fusion.height) at + _fusion.width,
      ]) {
        if (pixels[n] == old && seen.add(n)) {
          queue.add(n);
        }
      }
    }
    _fusion.endStroke();
  }

  void _previewTerrainRules() {
    final region = _region;
    if (region == null) {
      throw const EngineException('请先在融合画布读取完整世界选区。');
    }
    region.endStroke();
    final rules = _mapping.where((r) => r['type'] == 'terrain').toList();
    if (rules.isEmpty) {
      throw const EngineException('请先添加环境物块或墙体规则。');
    }
    _terrainPlan = TerrainRulePlan.prepare(region, rules);
    _terrainPlanRegion = region;
    _terrainPlanRules = jsonEncode(_mapping);
    _status = '已预览 ${_terrainPlan!.changedCells} 个地块的规则转换；画布和世界均未改变。';
  }

  void _applyTerrainRules(Map<String, Object?> args) {
    final plan = _terrainPlan, region = _region;
    if (plan == null ||
        region == null ||
        !identical(region, _terrainPlanRegion) ||
        region.revision != plan.sourceRevision ||
        jsonEncode(_mapping) != _terrainPlanRules) {
      throw const EngineException('选区或规则已改变，请重新预览转换。');
    }
    if (args['confirmed'] != true) {
      throw const EngineException('请先确认预览中的转换数量。');
    }
    region.endStroke();
    region.replaceRecords(plan.records);
    _terrainPlan = null;
    _status = '已应用 ${plan.changedCells} 个地块转换到融合画布，可一次撤销；尚未写入世界。';
  }

  Future<void> _readWorldOverlay(Map<String, Object?> args) async {
    if (_worldCircuit != null) {
      throw const EngineException('请先保存或关闭世界电路，再读取静态地图图层。');
    }
    final record = _activeWorld, backend = regionBackend;
    if (record == null || _world == null) {
      throw const EngineException('请先导入世界。');
    }
    if (backend == null) {
      throw const EngineException('当前平台未加载完整图层引擎。');
    }
    int integer(String key, int minimum, int maximum) {
      final value = args[key];
      if (value is! int || value < minimum || value > maximum) {
        throw FormatException('$key 必须为 $minimum–$maximum 之间的整数。');
      }
      return value;
    }

    final x = integer('x', 0, 32767),
        y = integer('y', 0, 32767),
        width = integer('width', 1, 16384),
        height = integer('height', 1, 16384);
    final worldWidth = (_worldView['maxTilesX'] as num?)?.toInt() ?? 0,
        worldHeight = (_worldView['maxTilesY'] as num?)?.toInt() ?? 0;
    if (width * height > 262144) {
      throw const EngineException('视口超过 262,144 个地块，请放大地图后读取。');
    }
    if (x + width > worldWidth || y + height > worldHeight) {
      throw const EngineException('视口超出当前世界边界。');
    }
    _worldOverlay = null;
    await _release('wld');
    late final WorldMapOverlay snapshot;
    try {
      final bytes = await backend.readRegion(
        record.current,
        x,
        y,
        width,
        height,
      );
      snapshot = WorldMapOverlay.fromRecords(
        x: x,
        y: y,
        width: width,
        height: height,
        records: bytes,
      );
    } finally {
      await _activate(record, refreshPreview: false);
    }
    _worldOverlay = snapshot;
    _status = '已读取当前世界 $width × $height 视口的真实电线与液体；未修改存档。';
  }

  Future<void> _readFusion(Map<String, Object?> args) async {
    if (_worldCircuit != null) {
      throw const EngineException('请先保存或关闭世界电路会话。');
    }
    final record = _activeWorld;
    if (record == null) {
      throw const EngineException('请先导入世界。');
    }
    final x = _bounded(args, 'x', 0, 32767),
        y = _bounded(args, 'y', 0, 32767),
        w = _bounded(args, 'width', 1, 512),
        h = _bounded(args, 'height', 1, 512);
    final backend = regionBackend;
    if (backend != null) {
      await _release('wld');
      try {
        final bytes = record.current,
            records = await backend.readRegion(bytes, x, y, w, h);
        Uint8List? objects;
        _regionCompanionWarning = null;
        try {
          objects = await backend.readRegionObjects(bytes, x, y, w, h);
        } catch (e) {
          _regionCompanionWarning = '选区物件伴随数据未就绪，禁止复制导出；可作保留原物件的原位编辑：$e';
        }
        _region = AdvancedRegionDocument(
          width: w,
          height: h,
          records: records,
          objects: objects == null || objects.isEmpty ? null : objects,
          sourceX: x,
          sourceY: y,
        );
        _regionX = 0;
        _regionY = 0;
      } finally {
        await _activate(record);
      }
      _status = '已读取 $w × $h 完整图层选区及 ${_region!.objectCount} 个对象伴随记录。';
      return;
    }
    final cells = await compute(_extractStamp, {
      'source': record.current,
      'x': x,
      'y': y,
      'width': w,
      'height': h,
    });
    _fusion.replace(w, h, cells);
    _status = '已读取 $w × $h 普通方块/墙体区域；复杂物件会被拒绝。';
  }

  Future<void> _matchPixelColors(Map<String, Object?> args) async {
    final backend = regionBackend, store = _resources;
    if (backend == null || store == null) {
      throw const EngineException('请先导入含稳定 RGB 表的完整资源包。');
    }
    final colors = _canvases['pixel']!.pixels
        .where((p) => (p >> 24) >= 16)
        .map((p) => p & 0xffffff)
        .toSet()
        .toList();
    if (colors.isEmpty) {
      throw const EngineException('画布没有可匹配的非透明像素。');
    }
    if (colors.length > 65535) {
      throw const EngineException('像素颜色超过 65,535，请减少颜色后重试。');
    }
    final candidates = store.catalog.stableColorCandidates();
    final selected = await backend.matchColors(
      Uint32List.fromList(colors),
      Uint32List.fromList(candidates.map((c) => c['rgb'] as int).toList()),
      Uint32List.fromList(candidates.map((c) => c['flags'] as int).toList()),
      flags: _bounded(args, 'flags', 0, 31, fallback: 8),
    );
    final rules = <Map<String, Object?>>[];
    for (var i = 0; i < colors.length; i++) {
      final index = selected[i];
      if (index >= candidates.length) {
        throw const EngineException('当前材质筛选没有颜色候选。');
      }
      final c = candidates[index];
      rules.add({
        'type': 'color',
        'source': '#${colors[i].toRadixString(16).padLeft(6, '0')}',
        'target': c['blockID'],
        'wall': c['wallID'],
        'blockPaint': c['blockPaint'],
        'wallPaint': c['wallPaint'],
        'mode': ((c['flags'] as int) & 2) != 0 ? 2 : 1,
        'version': c['version'],
      });
    }
    _resourceOperationGuard?.call();
    _mapping
      ..clear()
      ..addAll(rules);
    _terrainPlan = null;
    _status =
        '已通过原生匹配核心匹配 ${rules.length} 种颜色（资源 ${store.catalog.gameVersion}）。';
    await _saveMappingScheme();
  }

  bool get _placementIsCurrent =>
      _placement != null &&
      identical(_placementRegion, _region) &&
      _region?.revision == _placementRevision &&
      _activeWorld?.id == _placementWorldId &&
      _activeWorld?.currentHash == _placementWorldHash;

  void _clearFusionPlacement() {
    _placement = null;
    _placementRegion = null;
    _placementFragment = null;
    _placementRevision = null;
    _placementWorldHash = null;
    _placementWorldId = null;
    _placementWorldX = null;
    _placementWorldY = null;
  }

  void _stageFusionPlacement(Map<String, Object?> args) {
    if (_placement != null) throw const EngineException('请先确认或取消上一个物件的插入。');
    final region = _region,
        record = _activeWorld,
        catalog = _resources?.catalog;
    if (region == null || record == null || catalog == null) {
      throw const EngineException('请导入匹配资源，打开目标世界并读取融合选区。');
    }
    if (_worldCircuit != null || _worldView['readOnly'] == true) {
      throw const EngineException('当前世界不能进行物件放置。');
    }
    final brush = FusionPlacementCatalog(catalog).brush(
      args['itemId'] as int,
      variantIndex: args['variantIndex'] as int? ?? 0,
      display: args['display'] == true,
      name: args['name'] as String? ?? '',
      text: args['text'] as String? ?? '',
      logicOn: args['logicOn'] == true,
    );
    final plan = FusionPlacementPlan.preview(
      document: region,
      brush: brush,
      x: args['x'] as int,
      y: args['y'] as int,
      worldVersion: _worldView['version'] as int,
    );
    if (!plan.canPlace) throw EngineException(plan.blockers.join('\n'));
    final fragment = plan.fragment;
    plan.apply(region);
    _placement = plan;
    _placementRegion = region;
    _placementFragment = fragment;
    _placementRevision = region.revision;
    _placementWorldHash = record.currentHash;
    _placementWorldId = record.id;
    _placementWorldX = region.sourceX + plan.x;
    _placementWorldY = region.sourceY + plan.y;
    _status = '新物件已暂存到融合选区；确认独立插入后才会改变世界工作副本。';
  }

  Future<void> _insertFusionPlacement({required bool confirmed}) async {
    if (!confirmed) throw const EngineException('请先确认新物件插入。');
    if (!_placementIsCurrent) throw const EngineException('世界或选区已变化，请取消并重新放置。');
    if (_worldCircuit != null) throw const EngineException('请先保存或关闭世界电路会话。');
    final backend = regionBackend;
    if (backend == null) throw const EngineException('当前平台未加载区域写入引擎。');
    final record = _activeWorld!, fragment = _placementFragment!;
    await _release('wld');
    try {
      final targetRecords = await backend.readRegion(
        record.current,
        _placementWorldX!,
        _placementWorldY!,
        fragment.width,
        fragment.height,
      );
      final targetObjects = await backend.readRegionObjects(
        record.current,
        _placementWorldX!,
        _placementWorldY!,
        fragment.width,
        fragment.height,
      );
      final target = AdvancedRegionDocument(
        width: fragment.width,
        height: fragment.height,
        records: targetRecords,
        objects: targetObjects,
        sourceX: _placementWorldX!,
        sourceY: _placementWorldY!,
      );
      if (target.objectCount != 0 ||
          List.generate(
            target.recordCount,
            target.cellAtIndex,
          ).any((c) => c['active'] == 1)) {
        throw const EngineException('实际世界目标已有物块或对象，不能覆盖插入。请重新读取空白选区。');
      }
      final records = fragment.records,
          actual = ByteData.sublistView(targetRecords);
      final output = ByteData.sublistView(records);
      for (var i = 0; i < fragment.recordCount; i++) {
        final at = i * 32,
            flags = actual.getUint32(at + 8, Endian.little) >> 16;
        output.setUint32(
          at + 8,
          (output.getUint32(at + 8, Endian.little) & 65535) |
              (((flags & 82) | 1) << 16),
          Endian.little,
        );
        output.setUint32(
          at + 16,
          actual.getUint32(at + 16, Endian.little) & 0xff00ffff,
          Endian.little,
        );
        output.setUint32(
          at + 20,
          actual.getUint32(at + 20, Endian.little) & 0xff00ffff,
          Endian.little,
        );
      }
      final candidate = await backend.regionOperation(
        record.current,
        'stamp_tiles',
        fragment.stampRequest(_placementWorldX!, _placementWorldY!),
        records: records,
        objects: fragment.objects,
      );
      await _verify(candidate, 'wld');
      _resourceOperationGuard?.call();
      record.commit(candidate);
    } finally {
      await _activate(record);
    }
    _clearFusionPlacement();
    await _persist(record);
    _changes.add({
      'kind': 'wld',
      'operation': 'insert_object',
      'fields': 'fusion',
    });
    _status = '新物件已插入并回读验证，可撤销；请导出新的世界副本。';
  }

  Future<void> _coreStamp(
    Map<String, Object?> args,
    SaveRecord record, {
    required bool validateOnly,
  }) async {
    final backend = regionBackend!, kind = args['source'] as String? ?? 'pixel';
    if (kind == 'fusion' && _placement != null) {
      throw const EngineException('请先确认或取消新物件的独立插入，避免重复现有对象。');
    }
    final x = _bounded(args, 'x', 0, 32767), y = _bounded(args, 'y', 0, 32767);
    final version = _worldView['version'];
    final original = record.current;
    await _release('wld');
    Uint8List? output;
    try {
      if (kind == 'pixel') {
        final canvas = _canvases['pixel']!,
            byColor = <int, Map<String, Object?>>{};
        for (final r in _mapping.where(
          (r) => r['type'] == 'color' || r['type'] == null,
        )) {
          final c = int.tryParse(
            '${r['source']}'.replaceFirst('#', ''),
            radix: 16,
          );
          if (c != null) {
            byColor[c & 0xffffff] = r;
          }
        }
        final palette = <List<int>>[
              [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0],
            ],
            indices = Uint16List(canvas.width * canvas.height),
            cache = <int, int>{};
        for (var i = 0; i < indices.length; i++) {
          final color = canvas.pixels[i], rgb = color & 0xffffff;
          if ((color >> 24) < 16) {
            if (args['skipAir'] != false) {
              continue;
            }
            cache.putIfAbsent(-1, () {
              palette.add([0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0]);
              return palette.length - 1;
            });
            indices[i] = cache[-1]!;
            continue;
          }
          final index = cache.putIfAbsent(rgb, () {
            final r = byColor[rgb];
            if (r == null) {
              throw FormatException(
                '缺少颜色 #${rgb.toRadixString(16).padLeft(6, '0')} 的物块映射。',
              );
            }
            if (r['version'] != null &&
                (r['version'] != '1.4.5.8' || version != 326)) {
              throw const EngineException('自动稳定映射版本与世界不符；请使用同版本资源或显式自定义规则。');
            }
            final tile = _bounded(r, 'target', 0, 65535),
                wall = _bounded(r, 'wall', 0, 65535, fallback: 0),
                tp = _bounded(r, 'blockPaint', 0, 30, fallback: 0),
                wp = _bounded(r, 'wallPaint', 0, 30, fallback: 0);
            var mode = _bounded(r, 'mode', 0, 4, fallback: 1);
            if (args['keepWalls'] == true) {
              if (mode == 2) {
                mode = 3;
              } else if (mode == 4) {
                mode = 1;
              }
            }
            palette.add([
              (rgb >> 16) & 255,
              (rgb >> 8) & 255,
              rgb & 255,
              255,
              tile & 255,
              tile >> 8,
              wall & 255,
              wall >> 8,
              tp,
              wp,
              mode,
              args['ghost'] == true ? 1 : 0,
            ]);
            if (palette.length > 65536) {
              throw const EngineException('调色板超过 65,536 项。');
            }
            return palette.length - 1;
          });
          indices[i] = index;
        }
        if (indices.every((i) => palette[i][10] == 3)) {
          throw const EngineException('画布没有可写入内容。');
        }
        if (args['overwrite'] != true) {
          final target = ByteData.sublistView(
            await backend.readRegion(
              original,
              x,
              y,
              canvas.width,
              canvas.height,
            ),
          );
          for (var offset = 0; offset < target.lengthInBytes; offset += 32) {
            final xx = target.getUint32(offset, Endian.little),
                yy = target.getUint32(offset + 4, Endian.little),
                mode = palette[indices[yy * canvas.width + xx]][10];
            final active =
                    (target.getUint32(offset + 8, Endian.little) >> 16) & 1,
                wall = target.getUint32(offset + 16, Endian.little) & 65535;
            if (((mode == 0 || mode == 1 || mode == 4) && active == 1) ||
                ((mode == 2 || mode == 4) && wall != 0)) {
              throw const EngineException('像素目标层有内容；请开启覆盖或选择空白区域。');
            }
          }
        }
        output = await backend.writeIndexedPixels(
          original,
          x,
          y,
          canvas.width,
          canvas.height,
          Uint8List.fromList(palette.expand((r) => r).toList()),
          indices,
        );
      } else if (kind == 'fusion' && _region != null) {
        final region = _region!;
        if (args['mode'] == 'replace' && args['overwrite'] != true) {
          throw const EngineException('完整图层替换需明确开启覆盖。');
        }
        AdvancedRegionDocument? target;
        if (args['keepWalls'] == true || args['overwrite'] != true) {
          target = AdvancedRegionDocument(
            width: region.width,
            height: region.height,
            records: await backend.readRegion(
              original,
              x,
              y,
              region.width,
              region.height,
            ),
          );
        }
        if (args['overwrite'] != true) {
          for (var i = 0; i < region.recordCount; i++) {
            final c = region.cellAtIndex(i),
                t = target!.cellAt(c['x']!, c['y']!)!;
            if ((c['active'] == 1 && t['active'] == 1) ||
                (args['keepWalls'] != true &&
                    c['wall']! > 0 &&
                    t['wall']! > 0)) {
              throw const EngineException('粘贴目标已有方块/墙体，请开启覆盖或选择空白位置。');
            }
          }
        }
        var records = region.records;
        if (args['keepWalls'] == true) {
          final merged = AdvancedRegionDocument(
            width: region.width,
            height: region.height,
            records: records,
          );
          merged.beginStroke();
          for (var i = 0; i < merged.recordCount; i++) {
            final c = merged.cellAtIndex(i),
                t = target!.cellAt(c['x']!, c['y']!)!;
            merged.setCellAtIndex(i, {
              'wall': t['wall']!,
              'wallPaint': t['wallPaint']!,
              'invisibleWall': t['invisibleWall']!,
              'fullbrightWall': t['fullbrightWall']!,
            });
          }
          merged.endStroke();
          records = merged.records;
        }
        if (args['mode'] == 'replace') {
          output = await backend.replaceRegion(
            original,
            x,
            y,
            region.width,
            region.height,
            records,
          );
        } else {
          if (_regionCompanionWarning != null) {
            throw EngineException(_regionCompanionWarning!);
          }
          output = await backend.regionOperation(
            original,
            'stamp_tiles',
            region.stampRequest(x, y),
            records: records,
            objects: region.objects,
          );
        }
      } else if (kind == 'fusion') {
        final w = _fusion.width,
            h = _fusion.height,
            records = await backend.readRegion(original, x, y, w, h);
        final target = AdvancedRegionDocument(
          width: w,
          height: h,
          records: records,
        );
        target.beginStroke();
        for (var yy = 0; yy < h; yy++) {
          for (var xx = 0; xx < w; xx++) {
            final cell = _fusion.cells[yy * w + xx];
            if (cell == null) {
              continue;
            }
            final before = target.cellAt(xx, yy)!;
            if (args['overwrite'] != true &&
                ((cell.block != null &&
                        before['active'] == 1 &&
                        cell.block != before['block']) ||
                    (cell.wall != null &&
                        before['wall'] != 0 &&
                        cell.wall != before['wall']))) {
              throw const EngineException('目标有内容；请显式开启覆盖，或选择空白目标。');
            }
            target.setCell(xx, yy, {
              if (cell.block != null) ...{
                'active': cell.block! < 0 ? 0 : 1,
                'block': cell.block! < 0 ? 0 : cell.block!,
                'blockPaint': cell.blockPaint,
              },
              if (cell.wall != null && args['keepWalls'] != true) ...{
                'wall': cell.wall!,
                'wallPaint': cell.wallPaint,
              },
            });
          }
        }
        target.endStroke();
        output = await backend.replaceRegion(
          original,
          x,
          y,
          w,
          h,
          target.records,
        );
      } else {
        throw const EngineException('该来源尚未支持世界写入。');
      }
      await _verify(output, 'wld');
      if (!validateOnly) {
        _resourceOperationGuard?.call();
        record.commit(output);
      }
    } finally {
      await _activate(record);
    }
    _result = {
      ..._result,
      'validated': true,
      'validation': '原生区域/像素核心输出通过独立文件回读；原件保留。',
    };
    if (validateOnly) {
      _status = '校验通过，尚未应用写入。';
      return;
    }
    await _persist(record);
    _changes.add({'kind': 'wld', 'operation': 'core_$kind', 'fields': '$x,$y'});
    await _export('world');
  }

  Future<void> _stamp(
    Map<String, Object?> args, {
    bool validateOnly = false,
  }) async {
    if (_worldCircuit != null) {
      throw const EngineException('请先保存或关闭世界电路会话。');
    }
    final record = _activeWorld;
    if (record == null) {
      throw const EngineException('请先导入目标世界。');
    }
    final kind = args['source'] as String? ?? 'pixel';
    if (regionBackend != null && kind != 'circuit') {
      await _coreStamp(args, record, validateOnly: validateOnly);
      return;
    }
    if (kind == 'circuit') {
      throw const EngineException('电路工程写入 WLD 尚未通过完整物件校验，已阻止输出。');
    }
    final x = _bounded(args, 'x', 0, 32767), y = _bounded(args, 'y', 0, 32767);
    int width, height;
    List<StampCell?> cells;
    if (kind == 'fusion') {
      width = _fusion.width;
      height = _fusion.height;
      cells = _fusion.cells.toList();
    } else if (kind == 'pixel') {
      final canvas = _canvases['pixel']!;
      width = canvas.width;
      height = canvas.height;
      final palette = <int, int>{};
      for (final rule in _mapping.where(
        (m) => m['type'] == 'color' || m['type'] == null,
      )) {
        final text = '${rule['source']}'.replaceFirst('#', ''),
            color = int.tryParse(text, radix: 16),
            target = int.tryParse('${rule['target']}');
        if (color != null && target != null) {
          palette[color & 0xffffff] = target;
        }
      }
      cells = canvas.pixels.map((p) {
        if ((p >> 24) == 0) {
          return args['skipAir'] == false ? const StampCell(block: -1) : null;
        }
        final block = palette[p & 0xffffff];
        if (block == null) {
          throw FormatException(
            '颜色 #${(p & 0xffffff).toRadixString(16).padLeft(6, '0')} 尚未配置物块映射。',
          );
        }
        return StampCell(block: block);
      }).toList();
    } else {
      throw const FormatException('写入来源无效。');
    }
    if (args['keepWalls'] == true) {
      cells = cells
          .map(
            (c) => c == null
                ? null
                : StampCell(block: c.block, blockPaint: c.blockPaint),
          )
          .toList();
    }
    if (cells.every((c) => c == null || (c.block == null && c.wall == null))) {
      throw const FormatException('没有可写入的非透明内容。');
    }
    final output = await compute(_applyStamp, {
      'source': record.current,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'cells': cells,
      'overwrite': args['overwrite'] == true,
    });
    await _validateRecord(record, output);
    _result = {
      ..._result,
      'validated': true,
      'validation': '$width × $height 普通方块/墙体候选已通过边界、物件保护及文件引擎回读。',
    };
    if (validateOnly) {
      _status = '校验通过，尚未应用修改。';
      return;
    }
    _resourceOperationGuard?.call();
    record.commit(output);
    await _activate(record);
    await _persist(record);
    _changes.add({
      'kind': 'wld',
      'operation': 'safe_stamp',
      'fields': '$kind @ $x,$y',
    });
    await _export('world');
  }

  void _worldCircuitChanged() {
    final progress = _worldCircuit?.progress;
    if (_circuitImporting &&
        !_circuitCancelling &&
        progress != null &&
        const {
          'hash',
          'open',
          'decode',
          'compile',
          'ready',
          'command',
          'run',
        }.contains(progress.stage) &&
        progress.phase >= 0 &&
        progress.completed >= 0 &&
        progress.total >= 0 &&
        (progress.total == 0 || progress.completed <= progress.total)) {
      // Retain one reported sample, not the session or a history. Cleanup may
      // publish closed/error with zero active allocation before the open fails.
      _circuitLoadProgress = progress;
    }
    final records = _worldCircuit?.result?.records;
    if (_pendingCircuitViewport == null &&
        records != null && _worldCircuit?.result?.resultKind == 1) {
      _worldCircuitRecords = records;
    }
    _publishListeners(
      includeWorkspace: _worldCircuit?.isRuntimeFramePublication != true,
    );
  }

  void _clearCircuitLoadDiagnostics() {
    _circuitLoadProgress = null;
    _circuitLoadError = null;
  }

  Future<void> _chooseCircuitSource() async {
    if (_worldCircuit != null) throw const EngineException('请先关闭当前电路会话。');
    _clearCircuitLoadDiagnostics();
    final generation = ++_circuitImportGeneration;
    final source = await worldCircuitFiles.pick();
    if (generation != _circuitImportGeneration || source == null) return;
    _circuitSource = source;
    _status = '已选择 ${source.name}；导入时读取实际文件内容。';
  }

  Future<void> _importCircuitSource() async {
    if (_worldCircuit != null) throw const EngineException('请先关闭当前电路会话。');
    _clearCircuitLoadDiagnostics();
    final backend = worldCircuitBackend, source = _circuitSource;
    if (backend is! WorldCircuitSourceBackend || source == null) {
      throw const EngineException('请先选择 WLD；当前平台须支持分段读取。');
    }
    final generation = ++_circuitImportGeneration;
    _circuitImporting = true;
    _circuitCancelling = false;
    _circuitWorldMetadata = Map.of(_worldView);
    await _release('wld');
    final session = WorldCircuitSession.fromSource(
      backend,
      source,
      hostStages: hostStages,
    );
    _worldCircuit = session;
    session.addListener(_worldCircuitChanged);
    try {
      await session.open();
      if (generation != _circuitImportGeneration) return;
      await _locateInitialCircuitViewport();
      if (generation != _circuitImportGeneration) return;
      _status = '已解析完整 WLD 的实际接线与设备；可选择区域操作电路。';
    } catch (error) {
      if (generation == _circuitImportGeneration) {
        _circuitLoadError = error.toString().replaceFirst(
          'FormatException: ',
          '',
        );
        rethrow;
      }
    } finally {
      final cancelled = generation != _circuitImportGeneration;
      if (cancelled) _clearCircuitLoadDiagnostics();
      _circuitImporting = false;
      _circuitCancelling = false;
      if (cancelled || session.result == null || session.error != null) {
        if (identical(_worldCircuit, session)) await _closeWorldCircuit();
        if (cancelled) _status = '已取消导入并释放会话，可重新选择文件。';
      }
    }
  }

  Future<void> _openWorldCircuit() async {
    if (_worldCircuit != null) {
      return;
    }
    _clearCircuitLoadDiagnostics();
    final backend = worldCircuitBackend, record = _activeWorld;
    if (backend == null) {
      throw const EngineException('当前平台未加载世界电路引擎。');
    }
    if (record == null) {
      throw const EngineException('请先导入 WLD 世界。');
    }
    _circuitWorldMetadata = Map.of(_worldView);
    final catalog = _resources?.catalog;
    _worldGeometry =
        catalog?.gameVersion == '1.4.5.8' && _worldView['version'] == 326
        ? WorldCircuitGeometry.fromCatalog(catalog!, worldVersion: 326)
        : null;
    await _release('wld');
    final session = WorldCircuitSession(
      backend,
      record.current,
      hostStages: hostStages,
    );
    _worldCircuit = session;
    session.addListener(_worldCircuitChanged);
    try {
      await session.open();
      await _locateInitialCircuitViewport();
      _status = '真实世界电路已载入；原始 WLD 保持不变。';
    } catch (_) {
      await _closeWorldCircuit();
      rethrow;
    }
  }

  Future<void> _locateInitialCircuitViewport() async {
    final session = _worldCircuit, result = session?.result;
    if (session == null || result == null || result.width < 1 || result.height < 1) {
      throw const EngineException('世界电路没有有效尺寸。');
    }
    _worldFragments = null;
    _circuitViewport = {};
    _worldCircuitRecords = Uint8List(0);
    final stats = result.stats;
    final minX = stats[6], minY = stats[7], maxX = stats[8], maxY = stats[9];
    if (stats[10] > 0 && minX <= maxX && minY <= maxY &&
        maxX < result.width && maxY < result.height) {
      final width = maxX - minX + 1, height = maxY - minY + 1;
      if (width <= 256 && height <= 256) {
        await _viewCircuitBounds(minX, minY, width, height);
        return;
      }
      // The leftmost wired column must contain a real wire cell, even when
      // the bounding-box corner is empty (diagonal or U-shaped circuits).
      // Read one column only; never materialize the whole circuit rectangle.
      final generation = _circuitImportGeneration;
      final probe = {'x': minX, 'y': minY, 'width': 1, 'height': height};
      _pendingCircuitViewport = probe;
      var anchorY = minY;
      try {
        var found = false;
        for (var top = minY; top <= maxY && !found; top += 65536) {
          final remaining = maxY - top + 1;
          final count = remaining < 65536 ? remaining : 65536;
          final column = await session.command(
            WorldCircuitCommand.viewport(minX, top, 1, count),
          );
          if (generation != _circuitImportGeneration ||
              !identical(_worldCircuit, session)) return;
          final data = ByteData.sublistView(column.records);
          for (var offset = 0; offset + 16 <= column.records.length; offset += 16) {
            if ((data.getUint32(offset + 8, Endian.little) >> 24) != 0) {
              anchorY = data.getUint32(offset + 4, Endian.little);
              found = true;
              break;
            }
          }
        }
        if (!found) throw const EngineException('实际接线边界与记录不一致，请重新导入。');
      } finally {
        if (identical(_pendingCircuitViewport, probe)) _pendingCircuitViewport = null;
      }
      final viewHeight = height < 256 ? height : 256;
      final viewY = (anchorY - viewHeight ~/ 2)
          .clamp(minY, maxY - viewHeight + 1).toInt();
      await _viewCircuitBounds(minX, viewY, width, viewHeight);
      return;
    }
    // A supported world without wiring is still a valid imported WLD.
    final width = result.width < 48 ? result.width : 48;
    final height = result.height < 32 ? result.height : 32;
    await _viewCircuitBounds(stats[4] - width ~/ 2, stats[5] - height ~/ 2,
        width, height);
  }

  Future<void> _viewCircuitBounds(int x, int y, int width, int height) async {
    final result = _worldCircuit?.result;
    if (result == null) throw const EngineException('世界电路尚未就绪。');
    final w = width.clamp(1, result.width < 256 ? result.width : 256).toInt();
    final h = height.clamp(1, result.height < 256 ? result.height : 256).toInt();
    await _viewWorldCircuit({
      'x': x.clamp(0, result.width - w).toInt(),
      'y': y.clamp(0, result.height - h).toInt(),
      'width': w,
      'height': h,
    });
  }

  Future<void> _locateWorldCircuitFragment(int id) async {
    final fragments = _worldFragments?.fragments.where((f) => f.id == id);
    if (fragments == null || fragments.isEmpty) {
      throw const EngineException('片段不在当前列表，请重新读取。');
    }
    final fragment = fragments.first;
    await _viewCircuitBounds(fragment.x, fragment.y, fragment.width, fragment.height);
    _status = fragment.width > 256 || fragment.height > 256
        ? '片段 $id 大于单个视口，当前显示其左上区域；可移动视口查看其余接线。'
        : '已定位片段 $id 的实际电路区域。';
  }

  Future<void> _readCircuitDisplay(Map<String, Object?> args) async {
    final session = _worldCircuit, result = session?.result;
    if (session == null || result == null) {
      throw const EngineException('世界电路尚未就绪。');
    }
    final x = _bounded(args, 'x', 0, result.width - 1);
    final y = _bounded(args, 'y', 0, result.height - 1);
    final width = _bounded(args, 'width', 1, 256);
    final height = _bounded(args, 'height', 1, 256);
    await session.readDisplay(CircuitDisplayRegion('选区像素', x, y, width, height));
    _status = '已读取所选区域内的实际像素盒；运行时随电路状态刷新。';
  }

  Future<void> _pauseWorldCircuit() async {
    final session = _worldCircuit;
    if (session == null) return;
    session.pause();
    await session.refreshDisplay();
    if (identical(_worldCircuit, session) && _circuitViewport.isNotEmpty) {
      await _viewWorldCircuit(_circuitViewport);
    }
  }

  Future<void> _extractWorldCircuitFragment(int id) async {
    if (_placement != null) throw const EngineException('请先确认或取消融合画布中的待插入物件。');
    final session = _worldCircuit, page = _worldFragments;
    if (session == null || page == null) {
      throw const EngineException('请重新读取世界电路片段。');
    }
    final matches = page.fragments.where((f) => f.id == id);
    if (matches.isEmpty) throw const EngineException('片段不在当前列表，请刷新。');
    if (!matches.first.completeFootprint || matches.first.isModded) {
      throw const EngineException(
        '片段占格未完整核验或含不支持的格式，不能安全提取；请导入匹配的几何资源后重新打开会话。',
      );
    }
    final extraction = await session.extract(matches.first);
    final fragment = extraction.fragment;
    _region = AdvancedRegionDocument(
      width: fragment.width,
      height: fragment.height,
      sourceX: fragment.x,
      sourceY: fragment.y,
      records: extraction.records,
      objects: extraction.objects,
    );
    _regionX = 0;
    _regionY = 0;
    final safe =
        extraction.canStamp &&
        (_worldGeometry?.supportsVerifiedFor(extraction) ?? true);
    _regionCompanionWarning = safe ? null : '片段占格、支撑或附加对象未完整核验，仅可查看；不能直接粘贴。';
    _status = '已提取到融合画布。写入前先保存或关闭世界电路会话，再选择空白目标粘贴。';
  }

  Future<void> _worldCircuitCommand(WorldCircuitCommand command) async {
    final session = _worldCircuit;
    if (session == null) {
      throw const EngineException('请先载入世界电路。');
    }
    session.pause();
    await session.command(command);
    _worldFragments = null;
    if (_circuitViewport.isNotEmpty) {
      await _viewWorldCircuit(_circuitViewport);
    }
    await session.refreshDisplay();
  }

  Future<void> _viewWorldCircuit(Map<String, Object?> args) async {
    final session = _worldCircuit, result = session?.result;
    if (session == null || result == null) {
      throw const EngineException('世界电路尚未就绪。');
    }
    final x = _bounded(args, 'x', 0, result.width - 1),
        y = _bounded(args, 'y', 0, result.height - 1),
        w = _bounded(args, 'width', 1, 256),
        h = _bounded(args, 'height', 1, 256);
    if (x + w > result.width || y + h > result.height) {
      throw const FormatException('电路视口越过世界边界。');
    }
    final generation = _circuitImportGeneration;
    final requested = {'x': x, 'y': y, 'width': w, 'height': h};
    _pendingCircuitViewport = requested;
    try {
      final reply = await session.command(WorldCircuitCommand.viewport(x, y, w, h));
      if (generation == _circuitImportGeneration &&
          identical(_worldCircuit, session)) {
        // Publish the rectangle and its records together. Intermediate busy,
        // progress or runtime events keep the previous completed viewport.
        _circuitViewport = requested;
        _worldCircuitRecords = reply.records;
      }
    } finally {
      if (identical(_pendingCircuitViewport, requested)) {
        _pendingCircuitViewport = null;
      }
    }
    notifyListeners();
  }

  Future<void> _closeWorldCircuit({bool reopen = true}) =>
      _worldCircuitClosing ??= _finishCloseWorldCircuit(reopen: reopen)
          .whenComplete(() => _worldCircuitClosing = null);

  Future<void> _finishCloseWorldCircuit({required bool reopen}) async {
    final session = _worldCircuit;
    session?.pause();
    // An output may still be consumed by the system save dialog. Do not close
    // its lease, or discard our last retry owner, until that export settles.
    await _worldCircuitExportDrained;
    await _releasePendingCircuitSources();
    if (session == null) {
      return;
    }
    session.removeListener(_worldCircuitChanged);
    await session.close();
    session.dispose();
    _worldCircuit = null;
    _worldFragments = null;
    _worldGeometry = null;
    _worldCircuitRecords = Uint8List(0);
    _circuitViewport = {};
    _pendingCircuitViewport = null;
    _circuitWorldMetadata = {};
    if (reopen && !_closingWorkspace && _activeWorld != null) {
      await _activate(_activeWorld!);
    }
  }

  Future<void> _saveWorldCircuit() async {
    final session = _worldCircuit, record = _activeWorld;
    if (session == null) throw const EngineException('请先载入世界电路。');
    if (session.streamed) {
      final saving = _saveStreamedWorldCircuit(session);
      final drained = saving.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      _worldCircuitExportDrained = drained;
      try {
        await saving;
      } finally {
        if (identical(_worldCircuitExportDrained, drained)) {
          _worldCircuitExportDrained = null;
        }
      }
      return;
    }
    if (record == null) throw const EngineException('请先载入世界电路。');
    session.pause();
    final result = await session.command(WorldCircuitCommand.save());
    final bytes = result.world;
    if (bytes == null || bytes.isEmpty) {
      throw const EngineException('世界电路未产生有效候选文件。');
    }
    await _closeWorldCircuit(reopen: false);
    try {
      await _verify(bytes, 'wld');
      _resourceOperationGuard?.call();
      record.commit(bytes);
    } finally {
      await _activate(record);
    }
    await _persist(record);
    _changes.add({
      'kind': 'wld',
      'operation': 'world_circuit',
      'fields': '真实电路状态已回读验证',
    });
    await _export('world');
  }

  Future<void> _releasePendingCircuitSources() async {
    if (_pendingCircuitSourceReleases.isEmpty) return;
    final backend = worldCircuitBackend as WorldCircuitSourceBackend;
    Object? failure;
    for (final entry in _pendingCircuitSourceReleases.entries.toList()) {
      try {
        await backend.releaseWorldCircuitSource(entry.value);
        _pendingCircuitSourceReleases.remove(entry.key);
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) {
      _circuitSourceCleanupFailed = true;
      throw EngineException('临时导出文件清理失败，已保留待清理项；关闭、重置或下次导出时会重试：$failure');
    }
    _circuitSourceCleanupFailed = false;
  }

  Future<void> _saveStreamedWorldCircuit(WorldCircuitSession session) async {
    session.pause();
    // Resolve older failed releases before allocating another large output.
    await _releasePendingCircuitSources();
    final result = await session.command(WorldCircuitCommand.save());
    final output = result.worldSource;
    var failed = false;
    try {
      if (output == null) throw const EngineException('引擎未返回可导出的世界文件。');
      final stem = session.source!.name.replaceFirst(
        RegExp(r'\.wld$', caseSensitive: false),
        '',
      );
      final saved = await worldCircuitFiles.save(
        output,
        name: '${stem}_circuit.wld',
        protectedSources: [session.source!],
      );
      _status = saved ? '已导出模拟世界 WLD 副本。' : '已取消 WLD 导出，模拟状态仍保留。';
      if (saved) session.markSaved();
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      final token = output?.token;
      if (token != null) {
        // Only completed output descriptors enter this collection; picker
        // inputs remain protected and are never candidates for release.
        _pendingCircuitSourceReleases[token] = output!;
        try {
          await _releasePendingCircuitSources();
        } catch (_) {
          // Keep the export error authoritative when cleanup also fails.
          if (!failed) rethrow;
        }
      }
    }
  }

  void _stopCircuit() {
    _circuitTimer?.cancel();
    _circuitTimer = null;
  }

  TerraCanvas get _circuitCanvas {
    const colors = [0xffe78078, 0xff80aef0, 0xff8ed5a4, 0xffe8c572];
    final pixels = List<int>.filled(_circuit.width * _circuit.height, 0);
    for (final e in _circuit.cells.entries) {
      if (e.value.wires != 0) {
        pixels[e.key] =
            colors[List.generate(
              4,
              (i) => i,
            ).firstWhere((i) => (e.value.wires & (1 << i)) != 0)];
      } else if (e.value.element != CircuitElement.none) {
        pixels[e.key] = 0xffa7bbb8;
      }
    }
    final edits = _circuitEdits;
    if (edits != null && identical(edits.document, _circuit)) {
      final preview = edits.preview;
      if (preview != null && preview.revision == _circuit.revision) {
        for (final at in preview.wireMasks.keys) {
          pixels[at] = preview.kind == CircuitEditKind.removeNetwork
              ? 0xfff36b81
              : 0xff57e5ba;
        }
      }
    }
    return TerraCanvas(
      width: _circuit.width,
      height: _circuit.height,
      colors: pixels,
    );
  }

  Future<void> close() async {
    _closingWorkspace = true;
    _circuitImportGeneration++;
    await mapBackend.close();
    _map = null;
    _mapRaster = null;
    _stopCircuit();
    await _rules?.close();
    await _closeWorldCircuit(reopen: false);
    await _release('wld');
    await _release('plr');
    _closingWorkspace = false;
  }

  @override
  void notifyListeners() => _publishListeners(includeWorkspace: true);

  void _publishListeners({required bool includeWorkspace}) {
    if (_disposed) return;
    hostStages.measure('workspace.publishListeners', () {
      super.notifyListeners();
      if (includeWorkspace && !_disposed) _workspaceChanges.notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    onlineResources?.removeListener(_onlineResourcesChanged);
    unawaited(mapBackend.dispose());
    _map = null;
    _mapRaster = null;
    _stopCircuit();
    _rules?.removeListener(notifyListeners);
    _rules?.dispose();
    _workspaceChanges.dispose();
    super.dispose();
  }

  Map<String, Object?> get _worldView {
    if (_world == null) {
      if (_activeWorld == null) return {};
      return _circuitWorldMetadata.isNotEmpty
          ? _circuitWorldMetadata
          : (_busy ? _lastWorldMetadata : const <String, Object?>{});
    }
    final raw = _world!.metadata,
        header = Map<String, dynamic>.from(raw['header'] as Map? ?? raw);
    return {
      ...raw,
      ...header,
      'name': header['worldName'] ?? header['name'],
      'version': (raw['format'] as Map?)?['version'],
      'readOnly': (raw['format'] as Map?)?['readOnly'] ?? false,
    };
  }

  Map<String, Object?> get _playerView {
    if (_player == null) {
      return {};
    }
    final p = _player!.metadata;
    return {...p, 'health': p['statLife'], 'mana': p['statMana']};
  }

  Map<String, dynamic> _mappedPatch(
    Map<String, Object?> a,
    Map<String, String> aliases,
  ) {
    final patch = _patch(a);
    return patch.map((k, v) => MapEntry(aliases[k] ?? k, v));
  }

  int _bounded(
    Map<String, Object?> args,
    String key,
    int min,
    int max, {
    int? fallback,
  }) {
    final value = args[key];
    final n = value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
    if (n == null || n < min || n > max) {
      throw FormatException('$key 必须在 $min–$max 之间。');
    }
    return n;
  }

  Future<void> _inventory(Map<String, Object?> a) async {
    if (_player == null) {
      throw const EngineException('请先导入角色。');
    }
    final group = a['group'] as String? ?? 'inventory';
    if (!{
      'inventory',
      'armor',
      'dyes',
      'miscEquips',
      'miscDyes',
      'piggyBank',
      'safe',
      'defendersForge',
      'voidVault',
    }.contains(group)) {
      throw const FormatException('不支持的角色物品栏。');
    }
    final original = _player!.metadata[group];
    if (original is! List) {
      throw const EngineException('当前角色版本没有此物品栏。');
    }
    final slot = _bounded(a, 'slot', 0, original.length - 1),
        id = _bounded(a, 'itemId', 0, 65535);
    final quantity = _bounded(
          a,
          'quantity',
          id == 0 ? 0 : 1,
          9999,
          fallback: id == 0 ? 0 : 1,
        ),
        prefix = _bounded(a, 'prefix', 0, 255, fallback: 0);
    final items = original
        .map((e) => e == null ? null : Map<String, dynamic>.from(e as Map))
        .toList();
    items[slot] = {
      ...?items[slot],
      'itemType': id,
      'stack': id == 0 ? 0 : quantity,
      'prefix': id == 0 ? 0 : prefix,
    };
    await _edit(_player, _activePlayer, 'player_patch', {group: items});
  }

  void _discardWorldRuleCandidate() {
    _worldRuleCandidate = null;
    _worldRulePreviewPng = null;
    _worldRuleSourceId = null;
    _worldRuleSourceHash = null;
    _worldRuleFingerprint = null;
    _worldRuleSourceName = null;
  }

  void _setSchemeLibrary(NamedSchemeLibrary library) {
    if (library.kind == NamedSchemeKind.mapping) {
      _mappingSchemes = library;
    } else {
      _worldRuleSchemes = library;
    }
  }

  void _activateScheme(NamedSchemeLibrary library) {
    final selected = library.selected;
    if (library.kind == NamedSchemeKind.mapping) {
      _mapping
        ..clear()
        ..addAll(_validRules(selected?.payload['rules'] ?? []));
      _terrainPlan = null;
    } else {
      _worldRuleScheme = selected == null
          ? WorldRuleScheme(name: '我的世界规则')
          : WorldRuleScheme.fromJson(selected.payload);
      _discardWorldRuleCandidate();
    }
  }

  Future<void> _persistSchemeLibrary(NamedSchemeLibrary library) async {
    if (vault == null) return;
    final bytes = Uint8List.fromList(utf8.encode(library.encode()));
    final now = DateTime.now().microsecondsSinceEpoch;
    final previous = _schemeSequences[library.kind] ?? 0;
    final sequence = now > previous ? now : previous + 1;
    _schemeSequences[library.kind] = sequence;
    final entry = VaultEntry(
      id: 'preferences-schemes-${library.kind.name}-${sequence.toString().padLeft(20, '0')}',
      name: '方案库',
      kind: 'scheme-preferences',
      sha256: sha256.convert(bytes).toString(),
      size: bytes.length,
      modified: DateTime.now(),
    );
    await vault!.put(entry, bytes);
    _vaultEntries[entry.id] = entry;
  }

  Future<void> _saveMappingScheme() async {
    final payload = {
      'format': 'terraforge.mapping',
      'version': 1,
      'rules': _mapping,
    };
    _mappingSchemes = _mappingSchemes.selected == null
        ? _mappingSchemes.create(name: '我的映射', payload: payload)
        : _mappingSchemes.updateSelected(payload);
    await _persistSchemeLibrary(_mappingSchemes);
  }

  Future<void> _handleSchemeAction(
    String action,
    Map<String, Object?> args,
  ) async {
    final kind = NamedSchemeKind.values.firstWhere(
      (v) => v.name == args['kind'],
    );
    var library = kind == NamedSchemeKind.mapping
        ? _mappingSchemes
        : _worldRuleSchemes;
    library = switch (action) {
      'schemeCreate' => library.create(name: args['name'] as String),
      'schemeClone' => library.clone(
        args['id'] as String,
        name: args['name'] as String?,
      ),
      'schemeRename' => library.rename(
        args['id'] as String,
        args['name'] as String,
      ),
      'schemeSelect' => library.select(args['id'] as String),
      'schemeSetDefault' => library.setDefault(args['id'] as String),
      'schemeDelete' => library.delete(
        args['id'] as String,
        confirmed: args['confirmed'] == true,
      ),
      _ => throw const FormatException('未知方案操作。'),
    };
    await _persistSchemeLibrary(library);
    _setSchemeLibrary(library);
    _activateScheme(library);
    _status = '方案库已更新，世界文件尚未改变。';
  }

  Future<void> _saveWorldRules(WorldRuleScheme scheme) async {
    scheme.validate();
    _worldRuleSchemes = _worldRuleSchemes.selected == null
        ? _worldRuleSchemes.create(name: scheme.name, payload: scheme.toJson())
        : _worldRuleSchemes.updateSelected(scheme.toJson(), name: scheme.name);
    await _persistSchemeLibrary(_worldRuleSchemes);
    _worldRuleScheme = scheme;
    _discardWorldRuleCandidate();
    final bytes = Uint8List.fromList(utf8.encode(scheme.encode()));
    await _persistArtifact(
      '${scheme.name}.world-rules.json',
      'worldRules',
      bytes,
    );
    if (vault != null) {
      final now = DateTime.now().microsecondsSinceEpoch;
      _worldRuleSequence = now > _worldRuleSequence
          ? now
          : _worldRuleSequence + 1;
      final entry = VaultEntry(
        id: '$_worldRulePreferenceId-${_worldRuleSequence.toString().padLeft(20, '0')}',
        name: '世界规则偏好',
        kind: 'world-rules-preferences',
        sha256: sha256.convert(bytes).toString(),
        size: bytes.length,
        modified: DateTime.now(),
      );
      await vault!.put(entry, bytes);
      _vaultEntries[entry.id] = entry;
    }
    _status = '世界规则方案已保存；尚未改变世界。';
  }

  Future<void> _previewWorldRules(WorldRuleScheme scheme) async {
    final request = scheme.toEngineRequest(),
        record = _activeWorld,
        backend = regionBackend;
    if (_worldCircuit != null) throw const EngineException('请先保存或关闭世界电路会话。');
    if (record == null || _world == null) {
      throw const EngineException('请先导入目标世界。');
    }
    if (_worldView['readOnly'] == true) {
      throw const EngineException('当前世界版本只读。');
    }
    if (backend == null) throw const EngineException('当前平台未加载世界规则引擎。');
    _discardWorldRuleCandidate();
    final source = record.current, sourceHash = record.currentHash;
    final before = Map<String, Object?>.from(_worldView);
    await _release('wld');
    Uint8List? candidate, preview;
    EngineDocument? document;
    try {
      candidate = await backend.regionOperation(
        source,
        'batch_update_tiles',
        Map<String, dynamic>.from(request),
      );
      document = await engine.open(candidate, kind: 'wld');
      final metadata = await engine.inspect(document);
      final header = metadata['header'] as Map? ?? metadata;
      for (final key in ['worldId', 'worldName', 'maxTilesX', 'maxTilesY']) {
        if (header[key] !=
            (key == 'worldName'
                ? before['worldName'] ?? before['name']
                : before[key])) {
          throw const EngineException('规则候选改变了世界标识或尺寸，已拒绝。');
        }
      }
      if ((metadata['format'] as Map?)?['version'] != before['version']) {
        throw const EngineException('规则候选改变了存档版本。');
      }
      preview = await engine.preview(document);
    } finally {
      if (document != null) await engine.close(document);
      await _activate(record, refreshPreview: false);
    }
    _worldRuleScheme = scheme;
    _worldRuleCandidate = Uint8List.fromList(candidate);
    _worldRulePreviewPng = preview;
    _worldRuleSourceId = record.id;
    _worldRuleSourceHash = sourceHash;
    _worldRuleFingerprint = scheme.fingerprint;
    _worldRuleSourceName = record.name;
    _status = '整图规则候选已生成并回读验证；原件和当前世界尚未改变。';
  }

  Future<void> _applyWorldRules(
    WorldRuleScheme scheme, {
    required bool confirmed,
  }) async {
    scheme.validate(requireRules: true);
    if (!confirmed) throw const EngineException('请先确认整图规则候选。');
    final record = _activeWorld, bytes = _worldRuleCandidate;
    if (_worldCircuit != null) throw const EngineException('请先保存或关闭世界电路会话。');
    if (record == null ||
        bytes == null ||
        record.id != _worldRuleSourceId ||
        record.currentHash != _worldRuleSourceHash ||
        scheme.fingerprint != _worldRuleFingerprint) {
      throw const EngineException('世界或方案已变化，请重新生成候选。');
    }
    await _release('wld');
    EngineDocument? document;
    try {
      document = await engine.open(bytes, kind: 'wld');
      document.metadata.addAll(await engine.inspect(document));
      _resourceOperationGuard?.call();
      record.commit(bytes);
      await _setDocument(document, record);
      document = null;
    } catch (_) {
      if (document != null) await engine.close(document);
      await _activate(record);
      rethrow;
    }
    _discardWorldRuleCandidate();
    await _persist(record);
    _changes.add({
      'kind': 'wld',
      'operation': 'world_rules',
      'fields': scheme.name,
    });
    _status = '整图规则候选已应用到工作副本，可撤销；请导出新世界文件。';
  }

  Future<void> _setMarkers(MapMarkerProfile profile) async {
    _markerProfile = profile;
    _markersVisible = false;
    _preview = _basePreview;
    _status = '已更新 ${profile.length} 项标记；方案不会修改世界，点击刷新地图后显示。';
    final local = vault;
    if (local == null) return;
    final bytes = Uint8List.fromList(utf8.encode(profile.encode()));
    await _persistArtifact('map-markers.json', 'markers', bytes);
    final now = DateTime.now().microsecondsSinceEpoch;
    _markerSequence = now > _markerSequence ? now : _markerSequence + 1;
    final entry = VaultEntry(
      id: '$_markerPreferenceId-${_markerSequence.toString().padLeft(20, '0')}',
      name: '标记偏好',
      kind: 'marker-preferences',
      sha256: sha256.convert(bytes).toString(),
      size: bytes.length,
      modified: DateTime.now(),
    );
    try {
      await local.put(entry, bytes);
      _vaultEntries[entry.id] = entry;
    } catch (error) {
      _error = '标记已在内存中更新，但偏好保存失败：$error。请导出标记方案。';
    }
  }

  Future<void> _renderMarkers() async {
    if (_worldCircuit != null) throw const EngineException('请先关闭或保存世界电路会话。');
    final record = _activeWorld, backend = regionBackend;
    if (record == null || _world == null) {
      throw const EngineException('请先导入世界。');
    }
    if (_markerProfile.isEmpty) {
      _preview = _basePreview;
      _markersVisible = true;
      _status = '显示当前世界的宝箱位置。';
      return;
    }
    if (backend == null) throw const EngineException('当前平台未加载真实标记扫描引擎。');
    final width = (_worldView['maxTilesX'] as num?)?.toInt() ?? 0,
        height = (_worldView['maxTilesY'] as num?)?.toInt() ?? 0;
    final renderedWidth = width < 1920 ? width : 1920;
    if (width <= 0 ||
        height <= 0 ||
        width > 32767 ||
        height > 32767 ||
        renderedWidth * ((height * renderedWidth + width - 1) ~/ width) >
            8000000) {
      throw const EngineException('地图预览尺寸超出安全预算。');
    }
    final request = _markerProfile.toEngineRequest(maxWidth: 1920);
    await _release('wld');
    late final Uint8List png;
    try {
      png = await backend.regionOperation(
        record.current,
        'mark_tiles_and_chests_preview',
        Map<String, dynamic>.from(request),
      );
      if (png.length < 24 ||
          png.length > 64 * 1024 * 1024 ||
          png[0] != 137 ||
          png[1] != 80 ||
          png[2] != 78 ||
          png[3] != 71) {
        throw const EngineException('标记扫描没有返回有效 PNG。');
      }
      final header = ByteData.sublistView(png);
      final pw = header.getUint32(16, Endian.big),
          ph = header.getUint32(20, Endian.big);
      if (pw < 1 || ph < 1 || pw * ph > 8000000) {
        throw const EngineException('标记预览超过像素预算。');
      }
    } finally {
      await _activate(record, refreshPreview: false);
    }
    _preview = png;
    _markersVisible = true;
    _status = '已按 ${_markerProfile.length} 项条件扫描真实宝箱和物块并生成地图标记；世界文件未改变。';
  }

  AchievementCatalog _achievementCatalog({bool requireDefinitions = false}) {
    final source =
        _resources?.catalog ??
        ResourceCatalog(
          gameVersion: 'unknown',
          provenance: const {},
          families: const {},
        );
    final catalog = AchievementCatalog.fromResourceCatalog(source);
    if (requireDefinitions && catalog.definitions.isEmpty) {
      throw const EngineException('请先导入包含有效成就目录的资源包。');
    }
    return catalog;
  }

  Future<void> _acceptAchievements(
    AchievementFile candidate,
    String description,
  ) async {
    final bytes = candidate.exportBytes();
    AchievementFile.open(
      bytes,
    ); // Independent encrypted/BSON readback before publication.
    _achievements = candidate;
    _status = '$description，已回读校验，可导出独立副本。';
    try {
      await _persistArtifact(
        'achievements_terraforge.dat',
        'achievements',
        bytes,
      );
    } catch (e) {
      _error = '成就已在内存中更新，但本地保存失败：$e。请立即导出副本。';
    }
  }

  Map<String, Object?> _currentBestiary() {
    if (_world == null || (_worldView['version'] as num? ?? 0) < 210) {
      throw const EngineException('当前世界格式没有可写图鉴区段。');
    }
    final value = _world!.metadata['bestiary'];
    if (value is! Map) throw const EngineException('世界图鉴尚未读取。');
    return Map<String, Object?>.from(value);
  }

  Future<void> _replaceBestiary(Map<String, Object?> candidate) async {
    final current = _currentBestiary();
    final payload = <String, Object?>{
      for (final key in ['kills', 'sightings', 'chats']) key: candidate[key],
    };
    if (payload.values.any((value) => value is! List)) {
      throw const FormatException('图鉴须保留击杀、遇见和交谈三个区段。');
    }
    final before = {for (final key in payload.keys) key: current[key]};
    if (jsonEncode(payload) == jsonEncode(before)) {
      _status = '图鉴没有变化。';
      return;
    }
    await _edit(_world, _activeWorld, 'replace_bestiary', payload);
  }

  ResourceCatalog? get _verifiedChestCatalog {
    final catalog = _resources?.catalog;
    return _worldView['version'] == 326 && catalog?.gameVersion == '1.4.5.8'
        ? catalog
        : null;
  }

  ResourceCatalog? get _verifiedPlayerCatalog {
    final catalog = _resources?.catalog;
    return _playerView['version'] == 326 && catalog?.gameVersion == '1.4.5.8'
        ? catalog
        : null;
  }

  ResourceCatalog? get _verifiedBestiaryCatalog {
    final catalog = _resources?.catalog;
    return _worldView['version'] == 326 &&
            catalog?.gameVersion == '1.4.5.8' &&
            (catalog?.families['bestiary']?.isNotEmpty ?? false)
        ? catalog
        : null;
  }

  List<Map<String, Object?>> _currentChests() {
    if (_world == null) throw const EngineException('请先导入世界。');
    final raw = _world!.metadata['chests'];
    if (raw is! List || raw.isEmpty) {
      throw const EngineException('当前世界没有可编辑宝箱。');
    }
    return raw.map((e) => Map<String, Object?>.from(e as Map)).toList();
  }

  void _refreshChestChanges(EngineDocument doc, SaveRecord record) {
    final chests = doc.metadata['chests'];
    if (chests is! List) {
      _modifiedChests = {};
      return;
    }
    final current = <String, String>{};
    final keys = <String>[];
    for (var i = 0; i < chests.length; i++) {
      final chest = chests[i] as Map;
      final key = '${chest['x']},${chest['y']}';
      keys.add(key);
      current[key] = sha256.convert(utf8.encode(jsonEncode(chest))).toString();
    }
    final original = _chestBaselines.putIfAbsent(
      record.id,
      () => Map.of(current),
    );
    _modifiedChests = {
      for (var i = 0; i < keys.length; i++)
        if (current[keys[i]] != original[keys[i]]) i,
    };
  }

  Future<void> _chest(Map<String, Object?> a) async {
    final chests = _currentChests();
    final index = _bounded(a, 'index', 0, chests.length - 1);
    var chest = chests[index];
    if (a.containsKey('name')) {
      if (a['name'] is! String) throw const FormatException('宝箱名称必须是文本。');
      chest = ChestTools.rename(chest, a['name'] as String);
    }
    if (a.containsKey('slot')) {
      final items = chest['items'] as List;
      final slot = _bounded(a, 'slot', 0, items.length - 1),
          id = _bounded(a, 'itemId', 0, 65535);
      final original = items[slot] is Map ? items[slot] as Map : const {};
      chest = ChestTools.editSlot(
        chest,
        slot,
        itemId: id,
        quantity: _bounded(
          a,
          'quantity',
          id == 0 ? 0 : 1,
          9999,
          fallback: id == 0 ? 0 : null,
        ),
        prefix: _bounded(
          a,
          'prefix',
          0,
          255,
          fallback: (original['prefix'] as num?)?.toInt() ?? 0,
        ),
        catalog: _verifiedChestCatalog,
      );
    }
    if (jsonEncode(chest) == jsonEncode(chests[index])) {
      _status = '宝箱没有变化，未生成新候选。';
      return;
    }
    chests[index] = chest;
    await _edit(_world, _activeWorld, 'replace_chests', {'chests': chests});
  }

  Future<void> _transformChests(
    Map<String, Object?> args,
    String operation,
  ) async {
    final original = _currentChests();
    var chests = List<Map<String, Object?>>.of(original);
    final index = args.containsKey('index')
        ? _bounded(args, 'index', 0, chests.length - 1)
        : null;
    if ((operation == 'clear' || operation == 'prefixes') &&
        args['confirmed'] != true) {
      throw const EngineException('请先确认此宝箱批量操作。');
    }
    var note = '';
    if (operation == 'prefixes') {
      final catalog = _verifiedChestCatalog;
      if (catalog == null) {
        throw const EngineException('最佳前缀需要与当前世界版本匹配的已验证物品和前缀目录。');
      }
      final result = ChestTools.bestPrefixes(
        index == null ? chests : [chests[index]],
        rules: PrefixRules(catalog),
        version: _worldView['version'] as int,
      );
      if (index == null) {
        chests = result.chests;
      } else {
        chests[index] = result.chests.single;
      }
      note = '${result.changedChests} 个宝箱、${result.changedItems} 件物品更新前缀';
    } else {
      if (index == null) throw const FormatException('请选择一个宝箱。');
      chests[index] = operation == 'clear'
          ? ChestTools.clear(chests[index])
          : ChestTools.organize(chests[index], catalog: _verifiedChestCatalog);
      note = operation == 'clear' ? '所选宝箱内容已清空' : '所选宝箱已按物品 ID 整理；仅匹配目录允许合并堆叠';
    }
    if (jsonEncode(chests) == jsonEncode(original)) {
      _status = '宝箱内容没有变化，未生成新候选。';
      return;
    }
    await _edit(_world, _activeWorld, 'replace_chests', {'chests': chests});
    _status = '$note，候选已回读验证，可撤销或导出副本。';
  }

  Map<String, dynamic> _patch(Map<String, Object?> a) => a['patch'] is Map
      ? Map<String, dynamic>.from(a['patch'] as Map)
      : {a['field'] as String: a['value']};
  CanvasDocument _canvas(Map<String, Object?> args) {
    _activeCanvas = args['canvas'] as String? ?? 'pixel';
    return _canvases[_activeCanvas]!;
  }

  MapSessionInfo _requireMap() {
    final map = _map;
    if (map == null || map.isClosed) {
      throw const EngineException('请先打开 MAP 探索存档。');
    }
    return map;
  }

  Future<void> _openMapBytes(String name, Uint8List bytes) async {
    if (!RegExp(r'\.map(\.bak)?$', caseSensitive: false).hasMatch(name)) {
      throw const FormatException('请选择 .map 探索存档。');
    }
    final candidate = await mapBackend.open(bytes);
    await _adoptMap(name, candidate);
    _status = '已解析真实 MAP：${candidate.width} × ${candidate.height}，原始字节保留。';
  }

  Future<void> _adoptMap(String name, MapSessionInfo candidate) async {
    _map = candidate;
    _mapName = name;
    _mapRaster = null;
    _mapRaster = await mapBackend.render();
  }

  Future<void> _generateMapFromWorld() async {
    final world = _world, backend = engine;
    if (world == null || backend is! WorldMapBackend) {
      throw const EngineException('请先打开支持生成 MAP 的世界。');
    }
    final before = sha256.convert(await engine.save(world)).toString();
    final markers = _markerProfile.isEmpty
        ? null
        : (_markerProfile.toEngineRequest()..remove('max_w'));
    final bytes = await (backend as WorldMapBackend).generateWorldMap(
      world,
      markers: markers,
    );
    if (before != sha256.convert(await engine.save(world)).toString()) {
      throw const EngineException('生成 MAP 后世界状态校验失败，未采用输出。');
    }
    final name =
        '${(_activeWorld?.name ?? 'world.wld').replaceFirst(RegExp(r'\.wld(\.bak)?$', caseSensitive: false), '')}_full.map';
    final metadata = _worldView;
    final candidate = await mapBackend.open(
      bytes,
      expectedWorld: {
        if (metadata['worldId'] != null) 'worldId': metadata['worldId'],
        if (metadata['maxTilesX'] != null) 'width': metadata['maxTilesX'],
        if (metadata['maxTilesY'] != null) 'height': metadata['maxTilesY'],
        if (metadata['name'] != null) 'worldName': metadata['name'],
      },
    );
    await _adoptMap(name, candidate);
    await _persistArtifact(name, 'map', bytes);
    _status = '已从世界生成全亮 MAP，世界字节未改变。这是生成的探索图，不是角色的原始探索进度。';
  }

  Future<void> _import(String kind) async {
    final picked = await files.pick(kind);
    if (picked == null) {
      _status = '已取消选择文件。';
      return;
    }
    final name = picked.name.toLowerCase();
    if (kind == 'map' || RegExp(r'\.map(\.bak)?$').hasMatch(name)) {
      await _openMapBytes(picked.name, picked.bytes);
      await _persistArtifact(picked.name, 'map', picked.bytes);
      return;
    }
    if (kind == 'resources' || name.endsWith('.abcpack')) {
      _resources = await compute(ResourceStore.importPack, picked.bytes);
      await _persistArtifact(picked.name, 'resources', picked.bytes);
      _status =
          '已载入 Terraria ${_resources!.catalog.gameVersion} 本地资源：${_resources!.catalog.length} 条记录。';
      return;
    }
    if (kind == 'achievements' || RegExp(r'\.dat(\.bak)?$').hasMatch(name)) {
      _achievements = AchievementFile.open(picked.bytes);
      await _persistArtifact(picked.name, 'achievements', picked.bytes);
      _status = '已解析成就文件；未知字段保留。';
      return;
    }
    if (kind == 'image') {
      final pixels = await compute(importPixelImage, picked.bytes);
      _canvases['pixel']!.replace(34, 22, pixels);
      _status = '图片已导入 34 × 22 像素画布。';
      return;
    }
    if (name.endsWith('.json')) {
      final kind = await _loadProject(picked.bytes);
      if (kind == 'markers') await _setMarkers(_markerProfile);
      if (kind == 'mapping') await _saveMappingScheme();
      if (kind == 'worldRules') await _saveWorldRules(_worldRuleScheme);
      await _persistArtifact(picked.name, kind, picked.bytes);
      _status = '工程/目录已载入。';
      return;
    }
    final format = RegExp(r'\.(wld|plr)(\.bak)?$').firstMatch(name)?.group(1);
    if (format == null) {
      throw const FormatException('当前入口支持 .wld / .plr；成就请使用 .dat 文件入口。');
    }
    if ((kind == 'world' && format != 'wld') ||
        (kind == 'player' && format != 'plr')) {
      throw const FormatException('所选存档类型与当前导入入口不符。');
    }
    await _openBytes(picked.name, picked.bytes, format);
  }

  Future<String> _loadProject(Uint8List bytes) async {
    if (bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('工程超过 32 MiB。');
    }
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (data.length == 2 &&
        data.containsKey('version') &&
        data.containsKey('markers')) {
      _markerProfile = MapMarkerProfile.decode(utf8.decode(bytes));
      _markersVisible = false;
      _preview = _basePreview;
      return 'markers';
    }
    switch (data['format']) {
      case 'viewer-terralogic':
        await _rulesWorkspace.loadDocument(
          bytes,
          name: '完整电路.terralogic.json',
          persistInput: false,
        );
        return 'rulesCircuit';
      case WorldRuleScheme.format:
        _worldRuleScheme = WorldRuleScheme.decode(utf8.decode(bytes));
        _discardWorldRuleCandidate();
        return 'worldRules';
      case 'terraforge.circuit':
        _stopCircuit();
        _circuit = CircuitDocument.fromJson(data);
        _simulation = null;
        return 'circuit';
      case 'abc-region':
        _region = AdvancedRegionDocument.decode(utf8.decode(bytes));
        _regionCompanionWarning = null;
        _regionX = 0;
        _regionY = 0;
        return 'fusion';
      case 'terraforge.fusion':
        _region = null;
        _fusion = FusionDocument.fromJson(data);
        return 'fusion';
      case 'terraforge.canvas':
        final canvas = CanvasDocument.fromJson(data);
        _canvases['pixel'] = canvas;
        return 'pixel';
      case 'terraforge.mapping':
        if (data['version'] != 1) {
          throw const FormatException('映射版本不支持。');
        }
        final rules = _validRules(data['rules']);
        _mapping
          ..clear()
          ..addAll(rules);
        _terrainPlan = null;
        return 'mapping';
      case 'terraforge.catalog':
        final entries = data['entries'];
        if (data['version'] != 1 ||
            entries is! List ||
            entries.length > 20000) {
          throw const FormatException('资源目录须为版本 1，最多 20,000 项。');
        }
        final parsed = <Map<String, Object?>>[];
        for (final item in entries) {
          if (item is! Map ||
              item['id'] is! int ||
              item['id'] < 0 ||
              item['id'] > 1000000 ||
              item['name'] is! String ||
              (item['name'] as String).length > 200) {
            throw const FormatException('目录 ID/名称无效。');
          }
          parsed.add({
            'id': item['id'],
            'name': item['name'],
            'category': '${item['category'] ?? '其他'}',
          });
        }
        _catalog
          ..clear()
          ..addAll(parsed);
        return 'catalog';
      default:
        throw const FormatException('不支持的工程/资源格式。');
    }
  }

  List<Map<String, Object?>> _validRules(Object? raw) {
    if (raw is! List || raw.length > 65535) {
      throw const FormatException('映射规则必须为数组，最多 65,535 条。');
    }
    return raw.map((item) {
      if (item is! Map) {
        throw const FormatException('映射规则无效。');
      }
      final type = '${item['type'] ?? 'color'}',
          source = '${item['source']}',
          target = int.tryParse('${item['target']}');
      if (!{'color', 'terrain'}.contains(type) ||
          target == null ||
          target < 0 ||
          target > 65535 ||
          (type == 'color' &&
              !RegExp(r'^#?[a-fA-F0-9]{6}$').hasMatch(source)) ||
          (type == 'terrain' &&
              (int.tryParse(source) == null ||
                  int.parse(source) < 0 ||
                  int.parse(source) > 65535))) {
        throw const FormatException('颜色使用 #RRGGBB；环境源/目标使用有效物块 ID。');
      }
      final layer = item['layer'] ?? 'block';
      if (type == 'terrain' && !{'block', 'wall'}.contains(layer)) {
        throw const FormatException('环境规则图层必须是 block 或 wall。');
      }
      return <String, Object?>{
        'type': type,
        if (type == 'terrain') 'layer': layer,
        'source': source,
        'target': target,
        for (final key in [
          'wall',
          'blockPaint',
          'wallPaint',
          'mode',
          'version',
        ])
          if (item.containsKey(key)) key: item[key],
      };
    }).toList();
  }

  /// Generate the required world thumbnail in the real engine. The selected
  /// upload is an immutable snapshot; the user's active WLD is restored even
  /// when parsing or preview rendering fails.
  Future<Uint8List> _renderCloudWorldPreview(Uint8List bytes) async {
    if (_worldCircuit != null) {
      throw const EngineException('请先保存或关闭世界电路会话，再上传世界存档。');
    }
    final previous = _activeWorld;
    await _release('wld');
    EngineDocument? candidate;
    try {
      candidate = await engine.open(bytes, kind: 'wld');
      candidate.metadata.addAll(await engine.inspect(candidate));
      final preview = await engine.preview(candidate);
      if (preview == null || preview.isEmpty) {
        throw const EngineException('世界预览生成失败，未上传存档。');
      }
      return Uint8List.fromList(preview);
    } finally {
      if (candidate != null) await engine.close(candidate);
      if (previous != null) await _activate(previous);
    }
  }

  /// Cloud adoption succeeds only after both bytes and metadata are durable.
  /// The regular artifact path permits memory-only work; counted cloud downloads
  /// deliberately use this strict path so storage failures never send receipts.
  Future<void> _persistCloudFile(
    CloudSave save,
    Uint8List bytes,
    void Function() assertCurrent,
  ) async {
    final local = vault;
    if (local == null) throw const CloudFailure('本地存档库不可用，未确认下载完成。');
    assertCurrent();
    final kind = switch (save.kind) {
      'world' => 'wld',
      'player' => 'plr',
      _ => throw const CloudFailure('不支持的云端存档类型。'),
    };
    if (bytes.length != save.fileSize || bytes.isEmpty) {
      throw const CloudFailure('下载文件大小校验失败。');
    }
    final hash = sha256.convert(bytes).toString();
    final entry = VaultEntry(
      id: '$kind-$hash',
      name: cloudFileName(save.fileName),
      kind: kind,
      sha256: hash,
      size: bytes.length,
      modified: DateTime.now(),
    );
    validateVaultBytes(entry, bytes);
    final existing = (await local.list())
        .where((v) => v.id == entry.id)
        .firstOrNull;
    assertCurrent();
    if (existing == null) await local.put(entry, bytes);
    assertCurrent();
    final committed = (await local.list())
        .where((v) => v.id == entry.id)
        .firstOrNull;
    if (committed == null ||
        committed.kind != kind ||
        committed.sha256 != hash ||
        committed.size != bytes.length) {
      throw const CloudFailure('本地存档元数据未通过回读验证，未确认下载完成。');
    }
    validateVaultBytes(committed, await local.read(entry.id));
    assertCurrent();
    _vaultEntries[entry.id] = committed;
  }

  Future<void> _persistArtifact(
    String name,
    String kind,
    Uint8List bytes,
  ) async {
    if (vault == null) {
      return;
    }
    final hash = sha256.convert(bytes).toString(), id = '$kind-$hash';
    final entry = VaultEntry(
      id: id,
      name: name,
      kind: kind,
      sha256: hash,
      size: bytes.length,
      modified: DateTime.now(),
    );
    try {
      if (_vaultEntries.containsKey(id)) {
        await vault!.read(id);
        return;
      }
      await vault!.put(entry, bytes);
      _vaultEntries[id] = entry;
    } catch (e) {
      _error = '工程仍在内存，但本地副本保存失败：$e。请导出文件。';
    }
  }

  Future<void> _openBytes(String name, Uint8List bytes, String kind) async {
    if (kind == 'wld' && _worldCircuit != null) {
      throw const EngineException('请先保存或关闭当前世界电路会话。');
    }
    final previous = kind == 'wld' ? _activeWorld : _activePlayer;
    await _release(kind);
    EngineDocument? doc;
    try {
      doc = await engine.open(bytes, kind: kind);
      doc.metadata.addAll(await engine.inspect(doc));
      final record = SaveRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        kind: kind,
        bytes: bytes,
      );
      _records.add(record);
      await _setDocument(doc, record);
      await _persist(record, original: true);
      _status = '已解析 $name，原件已保留。';
    } catch (_) {
      if (doc != null) {
        await engine.close(doc);
      }
      if (previous != null) {
        await _activate(previous);
      }
      rethrow;
    }
  }

  Future<void> _release(String kind) async {
    final old = kind == 'wld' ? _world : _player;
    if (kind == 'wld') {
      _worldOverlay = null;
      _world = null;
    } else {
      _player = null;
    }
    if (old != null) {
      await engine.close(old);
    }
  }

  Future<void> _setDocument(
    EngineDocument doc,
    SaveRecord record, {
    bool refreshPreview = true,
  }) async {
    if (doc.kind == 'wld') {
      _world = doc;
      _activeWorld = record;
      _lastWorldMetadata = _worldView;
      if (refreshPreview) _refreshChestChanges(doc, record);
      if (!refreshPreview) return;
      _markersVisible = false;
      try {
        _basePreview = await engine.preview(doc);
        _preview = _basePreview;
      } catch (e) {
        _preview = null;
        _basePreview = null;
        _error = '文件已打开，但地图预览失败：$e';
      }
    } else {
      _player = doc;
      _activePlayer = record;
    }
  }

  Future<void> _activate(SaveRecord r, {bool refreshPreview = true}) async {
    if (r.kind == 'wld' && _worldCircuit != null) {
      throw const EngineException('请先保存或关闭当前世界电路会话。');
    }
    final previous = r.kind == 'wld' ? _world : _player;
    final previousRecord = r.kind == 'wld' ? _activeWorld : _activePlayer;
    final backup = previous == null ? null : await engine.save(previous);
    await _release(r.kind);
    EngineDocument? doc;
    try {
      doc = await engine.open(r.current, kind: r.kind);
      doc.metadata.addAll(await engine.inspect(doc));
      await _setDocument(doc, r, refreshPreview: refreshPreview);
    } catch (_) {
      if (doc != null) {
        await engine.close(doc);
      }
      if (backup != null && previousRecord != null) {
        final restored = await engine.open(backup, kind: r.kind);
        restored.metadata.addAll(await engine.inspect(restored));
        await _setDocument(restored, previousRecord);
      }
      rethrow;
    }
  }

  Future<void> _verify(Uint8List bytes, String kind) async {
    final candidate = await engine.open(bytes, kind: kind);
    try {
      await engine.inspect(candidate);
    } finally {
      await engine.close(candidate);
    }
  }

  Future<void> _validateRecord(SaveRecord record, Uint8List bytes) async {
    await _release(record.kind);
    try {
      await _verify(bytes, record.kind);
    } finally {
      await _activate(record);
    }
  }

  Future<void> _edit(
    EngineDocument? doc,
    SaveRecord? record,
    String operation,
    Map<String, dynamic> args,
  ) async {
    if (doc == null || record == null) {
      throw const EngineException('请先导入存档。');
    }
    // The engine owns one WLD slot. Close it before each isolated transaction.
    await _release(record.kind);
    EngineDocument? candidate;
    try {
      candidate = await engine.open(record.current, kind: record.kind);
      await engine.mutate(
        candidate,
        operation,
        operation == 'header_patch' ? {'patch': args} : args,
      );
      final bytes = await engine.save(candidate);
      await engine.close(candidate);
      candidate = null;
      await _verify(bytes, record.kind);
      _resourceOperationGuard?.call();
      record.commit(bytes);
    } finally {
      if (candidate != null) {
        await engine.close(candidate);
      }
      await _activate(record);
    }
    await _persist(record);
    _changes.add({
      'kind': record.kind,
      'operation': operation,
      'fields': args.keys.join(', '),
    });
    _status = '修改已暂存并通过回读校验；导出时生成新副本。';
  }

  Future<void> _persist(SaveRecord record, {bool original = false}) async {
    if (vault == null) {
      return;
    }
    final bytes = original ? record.original : record.current,
        hash = sha256
            .convert(original ? record.original : record.current)
            .toString();
    final id = original ? record.id : '${record.id}-v-${hash.substring(0, 12)}';
    final entry = VaultEntry(
      id: id,
      name: original ? record.name : record.exportName,
      kind: record.kind,
      sha256: hash,
      size: bytes.length,
      modified: DateTime.now(),
    );
    try {
      final existing = _vaultEntries[id];
      if (existing != null &&
          existing.sha256 == hash &&
          existing.size == bytes.length) {
        await vault!.read(id);
        return;
      }
      await vault!.put(entry, bytes);
      _vaultEntries[id] = entry;
    } catch (e) {
      _error = '文件已在内存中打开，但未保存到本地：$e。请立即导出备份。';
    }
  }

  Future<void> _undoRedo(Map<String, Object?> args, bool redo) async {
    final kind = args['canvas'] as String?;
    if (kind == 'fusion') {
      if (_region != null) {
        redo ? _region!.redo() : _region!.undo();
        return;
      }
      redo ? _fusion.redo() : _fusion.undo();
    } else if (kind == 'circuit') {
      _stopCircuit();
      redo ? _circuit.redo() : _circuit.undo();
      _simulation = null;
    } else if (kind == 'world' || kind == 'player') {
      final r = kind == 'world' ? _activeWorld : _activePlayer;
      if (r == null) {
        return;
      }
      if (!(redo ? r.canRedo : r.canUndo)) {
        _status = redo ? '当前存档没有可重做的修改。' : '当前存档没有可撤销的修改。';
        return;
      }
      await r.navigateHistory(forward: redo, verify: () => _activate(r));
      await _persist(r);
      _status = redo ? '已重做并通过回读校验。' : '已撤销并通过回读校验；会话操作日志保留。';
    } else {
      final c = _canvas(args);
      redo ? c.redo() : c.undo();
    }
  }

  Future<void> _moveVault(String id, {required bool restore}) async {
    final local = vault, entry = _vaultEntries[id];
    if (local == null || entry == null) {
      throw const EngineException('没有可操作的本地版本。');
    }
    if (!restore && _worldCircuit != null && _activeWorld?.id == id) {
      throw const EngineException('请先保存或关闭世界电路。');
    }
    try {
      final history = VaultHistory(local);
      restore ? await history.restore(entry) : await history.trash(entry);
    } finally {
      final current = await local.list();
      _vaultEntries
        ..clear()
        ..addEntries(current.map((e) => MapEntry(e.id, e)));
      if (!_vaultEntries.containsKey(id)) {
        if (_activeWorld?.id == id) {
          await _release('wld');
          _activeWorld = null;
          _preview = null;
          _basePreview = null;
          _markersVisible = false;
        }
        if (_activePlayer?.id == id) {
          await _release('plr');
          _activePlayer = null;
        }
        _records.removeWhere((r) => r.id == id);
        _chestBaselines.remove(id);
      }
    }
    _status = restore ? '本地版本已恢复。' : '所选应用内版本已移入回收站，外部原件不变。';
  }

  Future<void> _preparePlayerConversion(int target) async {
    _conversionBytes = null;
    _conversionSourceHash = null;
    _conversionReview = null;
    final record = _activePlayer,
        doc = _player,
        backend = playerProjectionBackend;
    if (record == null || doc == null || backend == null) {
      throw const EngineException('请先导入角色并加载转换引擎。');
    }
    if (doc.metadata['version'] == target) {
      throw const EngineException('角色已是所选版本。');
    }
    final plan = PlayerConversion.prepare(
      doc.metadata,
      target,
      catalog: _resources?.catalog,
    );
    final bytes = await backend.projectPlayer(plan.candidate);
    final candidate = await engine.open(bytes, kind: 'plr');
    try {
      _conversionReview = plan.reviewProjection(
        await engine.inspect(candidate),
        catalog: _resources?.catalog,
      );
    } finally {
      await engine.close(candidate);
    }
    _conversionBytes = bytes;
    _conversionSourceHash = sha256.convert(record.current).toString();
    _status = '转换预览已完成，尚未修改角色。请检查全部变化及兼容性限制。';
  }

  Future<void> _applyPlayerConversion(bool confirmed) async {
    final record = _activePlayer,
        bytes = _conversionBytes,
        review = _conversionReview;
    if (!confirmed || record == null || bytes == null || review == null) {
      throw const EngineException('请先预览并明确确认版本转换。');
    }
    if (review.gameplayCompatibilityBlocked) {
      throw EngineException('目标兼容性未验证：${review.blockers.join('；')}');
    }
    if (sha256.convert(record.current).toString() != _conversionSourceHash) {
      throw const EngineException('角色已变化，请重新预览转换。');
    }
    await _validateRecord(record, bytes);
    _resourceOperationGuard?.call();
    record.commit(bytes);
    await _activate(record);
    await _persist(record);
    _conversionBytes = null;
    _conversionSourceHash = null;
    _conversionReview = null;
    _changes.add({
      'kind': 'plr',
      'operation': 'version_conversion',
      'fields': '已确认转换，可撤销',
    });
    _status = '版本转换已通过回读并暂存，原件保留。';
  }

  Future<void> _export(String kind) async {
    if (kind == 'world' && _worldCircuit != null) {
      throw const EngineException('请在世界电路中保存当前状态。');
    }
    Uint8List bytes;
    String name;
    if (kind == 'achievements') {
      final doc = _achievements;
      if (doc == null) {
        throw const EngineException('请先导入成就文件。');
      }
      bytes = doc.exportBytes();
      AchievementFile.open(bytes);
      name = 'achievements.dat';
    } else if (kind == 'fusionProject') {
      if (_regionCompanionWarning != null) {
        throw EngineException(_regionCompanionWarning!);
      }
      bytes = Uint8List.fromList(
        utf8.encode(_region?.encode() ?? jsonEncode(_fusion.toJson())),
      );
      name = 'fusion.terraforge.json';
    } else if (kind == 'circuitProject') {
      bytes = Uint8List.fromList(utf8.encode(jsonEncode(_circuit.toJson())));
      name = 'circuit.terraforge.json';
    } else if (kind.endsWith('Project')) {
      final canvas = kind.replaceFirst('Project', '');
      final c = _canvases[canvas]!;
      bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({...c.toJson(), 'canvas': canvas})),
      );
      name = '$canvas.terraforge.json';
    } else if (kind == 'pixelPng') {
      final c = _canvases['pixel']!,
          image = img.Image(
            width: _canvases['pixel']!.width,
            height: _canvases['pixel']!.height,
            numChannels: 4,
          );
      for (var y = 0; y < c.height; y++) {
        for (var x = 0; x < c.width; x++) {
          final p = c.pixels[y * c.width + x];
          image.setPixelRgba(
            x,
            y,
            (p >> 16) & 255,
            (p >> 8) & 255,
            p & 255,
            (p >> 24) & 255,
          );
        }
      }
      bytes = Uint8List.fromList(img.encodePng(image));
      name = 'pixel-art.png';
    } else if (kind == 'mapPng') {
      if (_preview == null) {
        throw const EngineException('没有可导出的地图预览。');
      }
      bytes = _preview!;
      name = 'world-map.png';
    } else if (kind == 'worldRules') {
      bytes = Uint8List.fromList(utf8.encode(_worldRuleScheme.encode()));
      name = 'world-rules.json';
    } else if (kind == 'markers') {
      bytes = Uint8List.fromList(utf8.encode(_markerProfile.encode()));
      name = 'map-markers.json';
    } else if (kind == 'mapping') {
      bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'terraforge.mapping',
            'version': 1,
            'rules': _mapping,
          }),
        ),
      );
      name = 'mapping.json';
    } else {
      final r = kind == 'player' ? _activePlayer : _activeWorld;
      if (kind != 'player' && kind != 'world') {
        throw const EngineException('该格式尚未启用导出。');
      }
      if (r == null) {
        throw const EngineException('请先导入存档。');
      }
      bytes = r.current;
      await _validateRecord(r, bytes);
      name = r.exportName;
    }
    if (kind != 'world' && kind != 'player') {
      await _persistArtifact(name, kind.replaceFirst('Project', ''), bytes);
    }
    _status = await files.save(name, bytes)
        ? '文件已交给系统保存/下载界面：$name（${bytes.length} 字节）。请确认已保存。'
        : '已取消导出。';
  }
}

Uint8List _applyStamp(Map<String, Object?> request) => WorldStamp.apply(
  request['source'] as Uint8List,
  x: request['x'] as int,
  y: request['y'] as int,
  width: request['width'] as int,
  height: request['height'] as int,
  cells: request['cells'] as List<StampCell?>,
  overwrite: request['overwrite'] == true,
);
List<StampCell?> _extractStamp(Map<String, Object?> request) =>
    WorldStamp.extract(
      request['source'] as Uint8List,
      x: request['x'] as int,
      y: request['y'] as int,
      width: request['width'] as int,
      height: request['height'] as int,
    );
