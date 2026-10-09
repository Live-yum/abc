import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'online_resource_storage.dart';

@JS('terraOnlineResourceStorage.read')
external JSPromise<JSUint8Array?> _read(JSString kind, JSString id);
@JS('terraOnlineResourceStorage.write')
external JSPromise<JSAny?> _write(
  JSString kind,
  JSString id,
  JSUint8Array bytes,
);
@JS('terraOnlineResourceStorage.remove')
external JSPromise<JSAny?> _remove(JSString kind, JSString id);
@JS('terraOnlineResourceStorage.list')
external JSPromise<JSString> _list();
@JS('terraOnlineResourceStorage.commitActive')
external JSPromise<JSAny?> _commitActive(
  JSString namespace,
  JSUint8Array bytes,
);

OnlineResourceStorage createOnlineResourceStorage() =>
    WebOnlineResourceStorage();

/// IndexedDB storage. Storage failures are surfaced instead of losing installed
/// resources in a volatile fallback when the page closes.
class WebOnlineResourceStorage implements OnlineResourceStorage {
  @override
  Future<Uint8List?> read(String kind, String id) async {
    validateOnlineResourceKey(kind, id);
    final result = await _read(kind.toJS, id.toJS).toDart;
    if (result == null) return null;
    final bytes = result.toDart;
    validateOnlineResourceSize(kind, bytes.length);
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> write(String kind, String id, Uint8List bytes) async {
    validateOnlineResourceKey(kind, id);
    validateOnlineResourceSize(kind, bytes.length);
    final snapshot = Uint8List.fromList(bytes);
    await _write(kind.toJS, id.toJS, snapshot.toJS).toDart;
  }

  @override
  Future<void> remove(String kind, String id) async {
    validateOnlineResourceKey(kind, id);
    await _remove(kind.toJS, id.toJS).toDart;
  }

  @override
  Future<List<OnlineResourceEntry>> list() async {
    final records = jsonDecode((await _list().toDart).toDart) as List<dynamic>;
    return List.unmodifiable(
      records.map((value) {
        final record = value as Map<String, dynamic>;
        final kind = record['kind'] as String;
        final id = record['id'] as String;
        final bytes = record['bytes'] as int;
        validateOnlineResourceKey(kind, id);
        validateOnlineResourceSize(kind, bytes);
        return OnlineResourceEntry(kind: kind, id: id, bytes: bytes);
      }),
    );
  }

  @override
  Future<void> commitActive(String namespace, Uint8List bytes) async {
    validateOnlineResourceKey('state', 'active-$namespace');
    validateOnlineResourceSize('state', bytes.length);
    final snapshot = Uint8List.fromList(bytes);
    await _commitActive(namespace.toJS, snapshot.toJS).toDart;
  }
}
