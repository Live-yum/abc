import 'dart:io';

import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/vault.dart';
import 'package:terraforge/platform/vault_native.dart';

import 'computer_profile_storage.dart';

Future<ComputerProfileStorage> createPlatformComputerProfileStorage() async {
  final root = await Directory.systemTemp.createTemp('computer-profile-');
  return _NativeComputerProfileStorage(root);
}

class _NativeComputerProfileStorage implements ComputerProfileStorage {
  final Directory _root;
  @override
  final LocalVault vault;
  Future<void> _pending = Future<void>.value();
  Future<void>? _closing;
  var _sequence = 0;

  _NativeComputerProfileStorage(this._root)
    : vault = NativeLocalVault(
        directory: () async => Directory('${_root.path}/vault'),
      );

  @override
  Future<WorldCircuitSource> retain(WorldCircuitSource source, String name) {
    if (_closing != null) {
      return Future.error(StateError('Computer profile storage is closed.'));
    }
    final result = _pending.then((_) async {
      final path = source.path;
      if (path == null || source.length < 1 || source.length > 0x7fffffff) {
        throw const FormatException('Expected a ranged native world source.');
      }
      final input = File(path);
      if (await input.length() != source.length) {
        throw const FormatException('Computer profile source length changed.');
      }
      if (!name.toLowerCase().endsWith('.wld')) {
        throw const FormatException('Expected a WLD output name.');
      }
      final output = File('${_root.path}/output-${++_sequence}.wld');
      try {
        // File.copy uses the native filesystem; no whole-world Dart buffer.
        await input.copy(output.path);
        final length = await output.length();
        if (length != source.length) {
          throw const FormatException(
            'Retained computer output is incomplete.',
          );
        }
        return WorldCircuitSource.file(
          path: output.path,
          length: length,
          name: name,
          sha256: source.sha256,
        );
      } catch (_) {
        try {
          if (await output.exists()) await output.delete();
        } catch (_) {
          // The owned root is also removed by close(). Preserve the copy error.
        }
        rethrow;
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<void> close() => _closing ??= _removeOwnedRoot();

  Future<void> _removeOwnedRoot() async {
    await _pending;
    if (await _root.exists()) await _root.delete(recursive: true);
  }
}
