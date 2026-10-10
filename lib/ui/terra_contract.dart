import 'package:flutter/foundation.dart';

import '../platform/resource_store.dart';
import '../diagnostics/host_stage_timings.dart';
import '../domain/region_document.dart';
import '../domain/terraria_map.dart';
import '../engine/map_backend.dart';
import '../domain/world_map_overlay.dart';
import '../domain/map_markers.dart';
import '../domain/world_rules.dart';
import '../domain/named_scheme_library.dart';
import '../cloud/cloud.dart';
import '../resources/online_resource_service.dart';

/// Engine boundary. The UI never interprets a picked filename as parsed data.
abstract class TerraController extends ChangeNotifier {
  final HostStageTimings hostStages = HostStageTimings();
  TerraViewState get view;

  /// Ordinary workspace changes. Controllers without scoped updates keep the
  /// original notification and one-snapshot rendering path.
  Listenable get workspaceChanges => this;
  Listenable? get worldCircuitChanges => null;
  Map<String, Object?> get worldCircuitView =>
      Map<String, Object?>.from(view.result['worldCircuit'] as Map? ?? const {});
  Future<void> dispatch(String action, [Map<String, Object?> args = const {}]);
}

@immutable
class TerraFile {
  final String id, name, kind, detail;
  const TerraFile({
    required this.id,
    required this.name,
    required this.kind,
    this.detail = '',
  });
}

@immutable
class TerraViewState {
  final bool busy, canUndo, canRedo, circuitRunning;
  final String status, error;
  final List<TerraFile> files;
  final Map<String, Object?> world, player, result;
  final Uint8List? worldPreview;
  final WorldMapOverlay? worldOverlay;
  final MapMarkerProfile? markerProfile;
  final WorldRuleScheme? worldRuleScheme;
  final NamedSchemeLibrary? mappingSchemes, worldRuleSchemes;
  final Uint8List? worldRulePreviewPng;
  final ResourceStore? resources;
  final AdvancedRegionDocument? region;
  final MapSessionInfo? map;
  final TerrariaMapRaster? mapRaster;
  final bool canGenerateWorldMap;
  final CloudBackend? cloud;
  final OnlineResourceService? onlineResources;
  final Map<String, TerraCanvas> canvases;
  final List<Map<String, Object?>> catalog, mapping, changes;
  final int stagedCount, circuitTick;
  const TerraViewState({
    this.busy = false,
    this.canUndo = false,
    this.canRedo = false,
    this.circuitRunning = false,
    this.status = '',
    this.error = '',
    this.files = const [],
    this.world = const {},
    this.player = const {},
    this.result = const {},
    this.worldPreview,
    this.worldOverlay,
    this.markerProfile,
    this.worldRuleScheme,
    this.mappingSchemes,
    this.worldRuleSchemes,
    this.worldRulePreviewPng,
    this.resources,
    this.region,
    this.map,
    this.mapRaster,
    this.canGenerateWorldMap = false,
    this.cloud,
    this.onlineResources,
    this.canvases = const {},
    this.catalog = const [],
    this.mapping = const [],
    this.changes = const [],
    this.stagedCount = 0,
    this.circuitTick = 0,
  });
}

@immutable
class TerraCanvas {
  final int width, height;
  final List<int> colors;
  const TerraCanvas({
    required this.width,
    required this.height,
    required this.colors,
  });
}

/// Action vocabulary (all persistence and codec decisions belong to the engine):
/// import {kind: save|world|player|image|project|achievements}
/// export {kind: pixelPng|mapPng|pixelProject|fusionProject|circuitProject|player|world|achievements|mapping}
/// paint {canvas: pixel|fusion|circuit, x, y, color: ARGB, tool, material}
/// strokeStart/strokeEnd {canvas}; undo/redo/clear {canvas}
/// resize {canvas,width,height}; stageWorld/stagePlayer {field,value}
/// stageInventory {slot,itemId,quantity,prefix}; stageChest {index,slot,itemId,quantity}
/// generate {name,seed,size,difficulty,evil}; validate/write {source,x,y,...}
/// circuitToggle/circuitStep; mappingSave {name,rules}; openFile {id}
/// addMarker {itemId}; settings {key,value}; dismissError.
