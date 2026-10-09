import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'cloud/cloud.dart';
import 'resources/online_resource_service.dart';
import 'resources/online_resource_transport.dart';

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
  const cloudOrigin = String.fromEnvironment('TERRAFORGE_CLOUD_ORIGIN');
  const cloudTenant = String.fromEnvironment('TERRAFORGE_CLOUD_TENANT_ID');
  const cloudTerminal = String.fromEnvironment('TERRAFORGE_CLOUD_TERMINAL');
  final cloud = cloudOrigin.isEmpty
      ? null
      : CloudBackend(
          api: HttpCloudApi(
            config: CloudServiceConfig.viewer(
              baseUri: Uri.parse(cloudOrigin),
              tenantId: cloudTenant.isEmpty ? null : cloudTenant,
              terminal: cloudTerminal.isEmpty ? null : cloudTerminal,
            ),
            client: http.Client(),
          ),
        );
  const resourceOrigin = String.fromEnvironment('TERRAFORGE_RESOURCE_ORIGIN');
  final onlineResources = resourceOrigin.isEmpty
      ? null
      : OnlineResourceService(
          transport: HttpOnlineResourceTransport(resourceOrigin),
        );
  final workspace = Workspace(
    engine: core,
    cloud: cloud,
    onlineResources: onlineResources,
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
