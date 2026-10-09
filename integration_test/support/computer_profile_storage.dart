import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/vault.dart';

import 'computer_profile_storage_native.dart'
    if (dart.library.js_interop) 'computer_profile_storage_web.dart'
    as platform;

/// Developer-only durable storage for the actual-world profile. No fixture
/// bytes are bundled, and output names are labels rather than destination paths.
abstract class ComputerProfileStorage {
  LocalVault get vault;

  /// Copies an output before its engine lease is released. The returned source
  /// has no engine token and remains valid until this storage is closed.
  Future<WorldCircuitSource> retain(WorldCircuitSource source, String name);

  /// Call after closing every engine/workspace that uses the retained sources
  /// or vault. Removes only this profile run's owned files and records.
  Future<void> close();
}

Future<ComputerProfileStorage> createComputerProfileStorage() =>
    platform.createPlatformComputerProfileStorage();
