import 'dart:async';

import 'package:flutter/material.dart';

import 'application/workspace.dart';
import 'engine/native_engine.dart'
    if (dart.library.js_interop) 'engine/web_engine.dart'
    as engine;
import 'engine/circuit_factory.dart'
    if (dart.library.js_interop) 'engine/circuit_factory_web.dart'
    as circuits;
import 'engine/world_circuit_factory.dart'
    if (dart.library.js_interop) 'engine/world_circuit_factory_web.dart'
    as world_circuits;
import 'engine/region_factory.dart'
    if (dart.library.js_interop) 'engine/region_factory_web.dart'
    as regions;
import 'engine/player_projection_factory.dart'
    if (dart.library.js_interop) 'engine/player_projection_factory_web.dart'
    as projections;
import 'platform/files.dart';
import 'platform/vault.dart';
import 'ui/terra_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final core = engine.createTerraEngine();
  final workspace = Workspace(
    engine: core,
    files: PlatformFiles(),
    vault: createLocalVault(),
    circuitBackend: circuits.createCircuitBackend(core),
    worldCircuitBackend: world_circuits.createWorldCircuitBackend(core),
    regionBackend: regions.createRegionBackend(core),
    playerProjectionBackend: projections.createPlayerProjectionBackend(core),
  );
  runApp(TerraForgeApp(controller: workspace));
  unawaited(workspace.initialize());
}
