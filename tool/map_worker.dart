import 'dart:convert';
import 'dart:js_interop';

import 'package:terraforge/engine/map_worker_owner.dart';

@JS('terraMapDispatch')
external set _handler(JSFunction value);

extension type _Reply._(JSObject _) implements JSObject {
  external factory _Reply({required JSString json, JSUint8Array? bytes});
}

void main() {
  final owner = MapWorkerOwner();
  _handler = ((JSString method, JSString args, JSUint8Array? bytes) {
    final reply = owner.invoke(
      method.toDart,
      jsonDecode(args.toDart) as Map<String, dynamic>,
      bytes?.toDart,
    );
    return _Reply(
      json: jsonEncode(reply.metadata).toJS,
      bytes: reply.bytes?.toJS,
    );
  }).toJS;
}
