import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'world_circuit_backend.dart';

@JS('terraWorldCircuit')
external _Bridge get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external JSPromise<_Result> open(JSUint8Array world, JSUint8Array? twld);
  external JSPromise<_Result> command(
    JSNumber session,
    JSString words,
    JSString records,
  );
  external JSPromise<JSAny?> close(JSNumber session);
}

extension type _Result(JSObject _) implements JSObject {
  external JSNumber get session;
  external JSArray<JSNumber> get stats;
  external JSUint8Array get records;
  external JSUint8Array? get world;
  external JSUint8Array? get twld;
  external JSUint8Array? get objects;
  external JSNumber get resultKind;
  external JSNumber get resultCount;
  external JSNumber get reserved;
  WorldCircuitResult convert() => WorldCircuitResult(
    session.toDartInt,
    stats.toDart.map((v) => v.toDartInt).toList(),
    records.toDart,
    world: world?.toDart,
    twld: twld?.toDart,
    objects: objects?.toDart,
    resultKind: resultKind.toDartInt,
    resultCount: resultCount.toDartInt,
    reserved: reserved.toDartInt,
  );
}

class WebWorldCircuitBackend implements WorldCircuitBackend {
  @override
  Future<WorldCircuitResult> openWorldCircuit(
    Uint8List world, {
    Uint8List? twld,
  }) async => (await _bridge.open(world.toJS, twld?.toJS).toDart).convert();
  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async =>
      (await _bridge
              .command(
                session.toJS,
                jsonEncode(command.words).toJS,
                jsonEncode(command.records).toJS,
              )
              .toDart)
          .convert();
  @override
  Future<void> closeWorldCircuit(int session) async {
    await _bridge.close(session.toJS).toDart;
  }
}
