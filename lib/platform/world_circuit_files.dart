import '../engine/world_circuit_backend.dart';
import 'world_circuit_files_native.dart'
    if (dart.library.js_interop) 'world_circuit_files_web.dart'
    as platform;

/// Large world inputs are retained file handles, never whole Dart byte arrays.
abstract interface class WorldCircuitFileGateway {
  Future<WorldCircuitSource?> pick();
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  });
}

WorldCircuitFileGateway createWorldCircuitFiles() =>
    platform.PlatformWorldCircuitFiles();
