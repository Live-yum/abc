import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/vault.dart';
import 'package:terraforge/platform/vault_web.dart';

import 'computer_profile_storage.dart';

@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator(JSObject _) implements JSObject {
  external _StorageManager? get storage;
}

extension type _StorageManager(JSObject _) implements JSObject {
  external JSPromise<_DirectoryHandle> getDirectory();
}

extension type _DirectoryHandle(JSObject _) implements JSObject {
  external _DirectoryNames keys();
  external JSPromise<_DirectoryHandle> getDirectoryHandle(
    JSString name,
    _CreateOptions options,
  );
  external JSPromise<_FileHandle> getFileHandle(
    JSString name,
    _CreateOptions options,
  );
  external JSPromise<JSAny?> removeEntry(JSString name, _RemoveOptions options);
}

extension type _DirectoryNames(JSObject _) implements JSObject {
  external JSPromise<_DirectoryName> next();
}

extension type _DirectoryName(JSObject _) implements JSObject {
  external JSBoolean get done;
  external JSString? get value;
}

extension type _CreateOptions._(JSObject _) implements JSObject {
  external factory _CreateOptions({JSBoolean create});
}

extension type _RemoveOptions._(JSObject _) implements JSObject {
  external factory _RemoveOptions({JSBoolean recursive});
}

extension type _FileHandle(JSObject _) implements JSObject {
  external JSPromise<_Writable> createWritable();
  external JSPromise<_Blob> getFile();
}

extension type _Writable(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSObject blob);
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> abort();
}

extension type _Blob(JSObject _) implements JSObject {
  external JSNumber get size;
}

Future<ComputerProfileStorage> createPlatformComputerProfileStorage() async {
  late _DirectoryHandle root;
  final existingNames = <String>{};
  try {
    final manager = _navigator.storage;
    if (manager == null) throw StateError('navigator.storage is unavailable');
    root = await manager.getDirectory().toDart;
    final names = root.keys();
    while (true) {
      final next = await names.next().toDart;
      if (next.done.toDart) break;
      existingNames.add(next.value!.toDart);
    }
  } catch (error) {
    throw UnsupportedError(
      'The computer profile requires writable OPFS in a secure browser context. '
      'No in-memory whole-world fallback is supported. $error',
    );
  }

  final inner = WebLocalVault();
  final existing = await inner.list();
  final random = Random.secure();
  late String nonce, prefix, directoryName;
  do {
    nonce = List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    prefix = 'cp${nonce}_';
    directoryName = 'computer-profile-$nonce';
  } while (existingNames.contains(directoryName) ||
      existing.any((entry) => entry.id.startsWith(prefix)));
  final directory = await root
      .getDirectoryHandle(directoryName.toJS, _CreateOptions(create: true.toJS))
      .toDart;
  return _WebComputerProfileStorage(
    root,
    directory,
    directoryName,
    _ProfileVault(inner, prefix),
  );
}

class _WebComputerProfileStorage implements ComputerProfileStorage {
  final _DirectoryHandle _root, _directory;
  final String _directoryName;
  @override
  final _ProfileVault vault;
  Future<void> _pending = Future<void>.value();
  Future<void>? _closing;
  var _sequence = 0;

  _WebComputerProfileStorage(
    this._root,
    this._directory,
    this._directoryName,
    this.vault,
  );

  @override
  Future<WorldCircuitSource> retain(WorldCircuitSource source, String name) {
    if (_closing != null) {
      return Future.error(StateError('Computer profile storage is closed.'));
    }
    final result = _pending.then((_) async {
      final blob = source.blob;
      if (blob == null || source.length < 1 || source.length > 0x7fffffff) {
        throw const FormatException('Expected a ranged browser world source.');
      }
      final input = blob as JSObject;
      if (_Blob(input).size.toDartInt != source.length) {
        throw const FormatException('Computer profile source length changed.');
      }
      final extension = name.toLowerCase().endsWith('.twld') ? 'twld' : 'wld';
      final filename = 'output-${++_sequence}.$extension';
      _Writable? writable;
      try {
        final handle = await _directory
            .getFileHandle(filename.toJS, _CreateOptions(create: true.toJS))
            .toDart;
        writable = await handle.createWritable().toDart;
        // OPFS consumes the Blob directly. Never call arrayBuffer() or create
        // a Dart world Uint8List merely to retain an engine output lease.
        await writable.write(input).toDart;
        await writable.close().toDart;
        writable = null;
        final retained = await handle.getFile().toDart;
        final length = retained.size.toDartInt;
        if (length != source.length) {
          throw const FormatException(
            'Retained computer output is incomplete.',
          );
        }
        return WorldCircuitSource.blob(
          blob: retained,
          length: length,
          name: name,
          sha256: source.sha256,
        );
      } catch (_) {
        if (writable != null) {
          try {
            await writable.abort().toDart;
          } catch (_) {
            try {
              await writable.close().toDart;
            } catch (_) {
              // Keep the original failure; close() also removes the owned root.
            }
          }
        }
        try {
          await _directory
              .removeEntry(filename.toJS, _RemoveOptions(recursive: false.toJS))
              .toDart;
        } catch (_) {
          // The partial output, if any, stays inside this run's owned directory.
        }
        rethrow;
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<void> close() => _closing ??= _removeOwnedStorage();

  Future<void> _removeOwnedStorage() async {
    await _pending;
    Object? failure;
    StackTrace? failureStack;
    try {
      await vault.close();
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    try {
      await _root
          .removeEntry(
            _directoryName.toJS,
            _RemoveOptions(recursive: true.toJS),
          )
          .toDart;
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }
}

/// The real IndexedDB vault remains responsible for durable commits, hashing,
/// and bounded registry bytes. This adapter only translates IDs and metadata.
class _ProfileVault implements LocalVault {
  final WebLocalVault _inner;
  final String _prefix;
  final _ownedIds = <String>{};
  final _pending = <Future<void>>{};
  var _closed = false;

  _ProfileVault(this._inner, this._prefix);

  String _scoped(String id) {
    validateVaultId(id);
    final scoped = '$_prefix$id';
    if (scoped.length > 96) {
      throw const VaultException(
        'Profile vault ID exceeds its namespace limit.',
      );
    }
    return scoped;
  }

  static VaultEntry _withId(VaultEntry entry, String id) => VaultEntry(
    id: id,
    name: entry.name,
    kind: entry.kind,
    sha256: entry.sha256,
    size: entry.size,
    modified: entry.modified,
  );

  Future<T> _run<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('Profile vault is closed.'));
    // Invoke immediately so WebLocalVault takes its normal caller-byte snapshot
    // during put(), without adding a second snapshot in this adapter.
    final result = Future<T>.sync(action);
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending.add(settled);
    settled.then((_) => _pending.remove(settled));
    return result;
  }

  @override
  Future<List<VaultEntry>> list() => _run(() async {
    final entries = await _inner.list();
    return [
      for (final entry in entries)
        if (entry.id.startsWith(_prefix))
          _withId(entry, entry.id.substring(_prefix.length)),
    ];
  });

  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) => _run(() {
    final id = _scoped(entry.id);
    _ownedIds.add(id); // Also clean up a commit whose verification failed.
    return _inner.put(_withId(entry, id), bytes);
  });

  @override
  Future<Uint8List> read(String id) => _run(() => _inner.read(_scoped(id)));

  @override
  Future<void> remove(String id) => _run(() => _inner.remove(_scoped(id)));

  Future<void> close() async {
    _closed = true;
    await Future.wait(_pending.toList());
    Object? failure;
    StackTrace? failureStack;
    for (final id in _ownedIds) {
      try {
        await _inner.remove(id);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }
}
