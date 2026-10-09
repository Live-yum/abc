import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'vault.dart';

@JS('terraVault.list')
external JSPromise<JSString> _list();
@JS('terraVault.put')
external JSPromise<JSAny?> _put(JSString metadata, JSUint8Array bytes);
@JS('terraVault.read')
external JSPromise<JSObject> _read(JSString id);
@JS('terraVault.remove')
external JSPromise<JSAny?> _remove(JSString id);

extension type _ReadResult(JSObject _) implements JSObject {
  external JSString get metadata;
  external JSUint8Array get bytes;
}

LocalVault createPlatformVault() => WebLocalVault();

class WebLocalVault implements LocalVault {
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on VaultException {
      rethrow;
    } catch (error) {
      throw VaultException('浏览器本地存储失败（可能权限被拒绝、空间不足或数据损坏）：$error');
    }
  }

  @override
  Future<List<VaultEntry>> list() => _guard(() async {
    final items = jsonDecode((await _list().toDart).toDart) as List<dynamic>;
    final entries = items
        .map((e) => VaultEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  });

  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) {
    validateVaultBytes(entry, bytes);
    final snapshot = Uint8List.fromList(bytes);
    return _guard(() async {
      await _put(jsonEncode(entry.toJson()).toJS, snapshot.toJS).toDart;
    });
  }

  @override
  Future<Uint8List> read(String id) {
    validateVaultId(id);
    return _guard(() async {
      final result = _ReadResult(await _read(id.toJS).toDart);
      final entry = VaultEntry.fromJson(
        jsonDecode(result.metadata.toDart) as Map<String, dynamic>,
      );
      if (entry.id != id) {
        throw const VaultException('本地存档标识不匹配。');
      }
      final bytes = result.bytes.toDart;
      validateVaultBytes(entry, bytes);
      return Uint8List.fromList(bytes);
    });
  }

  @override
  Future<void> remove(String id) {
    validateVaultId(id);
    return _guard(() async {
      await _remove(id.toJS).toDart;
    });
  }
}
