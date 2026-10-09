import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'world_circuit_backend.dart';

@JS('terraWorldCircuit')
external _Bridge get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external JSPromise<_Result> open(JSUint8Array world, JSUint8Array? twld);
  external JSPromise<_Result> openSource(JSObject world, JSObject? twld);
  external JSPromise<_Progress> progress();
  external JSPromise<JSAny?> cancelOperation();
  external JSPromise<JSAny?> releaseSource(JSNumber token);
  external JSPromise<_Result> command(
    JSNumber session,
    JSString words,
    JSString records,
  );
  external JSPromise<_ComputerFrame> computerFrame(
    JSNumber session,
    JSString clockWords,
    JSString pixelWords,
  );
  external JSPromise<JSAny?> close(JSNumber session);
}

extension type _InputBlob(JSObject _) implements JSObject {
  external JSNumber get size;
}

extension type _Source(JSObject _) implements JSObject {
  external JSObject get blob;
  external JSNumber get token;
  external JSNumber get size;
  external JSString get name;
  external JSString? get sha256;
  WorldCircuitSource convert() => WorldCircuitSource.blob(
    blob: blob,
    length: size.toDartInt,
    name: name.toDart,
    token: token.toDartInt.toString(),
    sha256: sha256?.toDart,
  );
}

extension type _Progress(JSObject _) implements JSObject {
  external JSString get stage;
  external JSNumber get phase;
  external JSNumber get completed;
  external JSNumber get total;
  external JSObject? get diagnostics;
  WorldCircuitProgress convert() => WorldCircuitProgress(
    stage: stage.toDart,
    phase: phase.toDartInt,
    completed: completed.toDartInt,
    total: total.toDartInt,
    diagnostics: Map<String, Object?>.from(
      diagnostics?.dartify() as Map? ?? const {},
    ),
  );
}

extension type _Result(JSObject _) implements JSObject {
  external JSNumber get session;
  external JSArray<JSNumber> get stats;
  external JSUint8Array get records;
  external JSUint8Array? get world;
  external JSUint8Array? get twld;
  external JSUint8Array? get objects;
  external _Source? get worldSource;
  external _Source? get twldSource;
  external JSString? get sourceSha256;
  external JSString? get twldSourceSha256;
  external JSNumber get resultKind;
  external JSNumber get resultCount;
  external JSNumber get reserved;
  external JSObject? get hostStagesUs;
  WorldCircuitResult convert() => WorldCircuitResult(
    session.toDartInt,
    stats.toDart.map((v) => v.toDartInt).toList(),
    records.toDart,
    world: world?.toDart,
    twld: twld?.toDart,
    objects: objects?.toDart,
    worldSource: worldSource?.convert(),
    twldSource: twldSource?.convert(),
    sourceSha256: sourceSha256?.toDart,
    twldSourceSha256: twldSourceSha256?.toDart,
    resultKind: resultKind.toDartInt,
    resultCount: resultCount.toDartInt,
    reserved: reserved.toDartInt,
    hostStagesUs: Map<String, num>.from(
      hostStagesUs?.dartify() as Map? ?? const {},
    ),
  );
}

extension type _ComputerFrame(JSObject _) implements JSObject {
  external _Result get clock;
  external _Result? get display;
  external JSString? get displayError;
  external JSObject? get hostStagesUs;
  WorldCircuitComputerFrame convert() => WorldCircuitComputerFrame(
    clock: clock.convert(),
    display: display?.convert(),
    displayError: displayError?.toDart,
    hostStagesUs: Map<String, num>.from(
      hostStagesUs?.dartify() as Map? ?? const {},
    ),
  );
}

class WebWorldCircuitBackend
    implements WorldCircuitSourceBackend, WorldCircuitComputerBackend {
  @override
  Future<WorldCircuitComputerFrame> clockAndReadDisplay(
    int session,
    WorldCircuitCommand clock,
    WorldCircuitCommand pixels,
  ) async =>
      (await _bridge
              .computerFrame(
                session.toJS,
                jsonEncode(clock.words).toJS,
                jsonEncode(pixels.words).toJS,
              )
              .toDart)
          .convert();

  @override
  Future<WorldCircuitResult> openWorldCircuit(
    Uint8List world, {
    Uint8List? twld,
  }) async => (await _bridge.open(world.toJS, twld?.toJS).toDart).convert();
  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    WorldCircuitSource? twld,
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    JSObject input(WorldCircuitSource source) {
      if (source.blob == null ||
          source.length < 1 ||
          source.length > 0x7fffffff) {
        throw const FormatException('Web circuit import requires a File/Blob');
      }
      final value = source.blob as JSObject;
      if (_InputBlob(value).size.toDartInt != source.length) {
        throw const FormatException('Circuit source length changed');
      }
      return value;
    }

    final worldBlob = input(world),
        twldBlob = twld == null ? null : input(twld);
    var polling = false, finished = false;
    final timer = onProgress == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 100), (_) async {
            if (polling || finished) return;
            polling = true;
            try {
              final progress = await worldCircuitProgress();
              if (!finished && progress != null) onProgress(progress);
            } catch (_) {
              // The main open future reports owner loss or decoding failures.
            } finally {
              polling = false;
            }
          });
    try {
      return (await _bridge.openSource(worldBlob, twldBlob).toDart).convert();
    } finally {
      finished = true;
      timer?.cancel();
    }
  }

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() async =>
      (await _bridge.progress().toDart).convert();

  @override
  Future<void> cancelWorldCircuitOperation() async {
    await _bridge.cancelOperation().toDart;
  }

  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) async {
    final token = source.token;
    if (token == null) return;
    final value = int.tryParse(token);
    if (value == null || value < 1) {
      throw const FormatException('Invalid circuit output source token');
    }
    await _bridge.releaseSource(value.toJS).toDart;
  }

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
