import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'region_backend.dart';

@JS('terraRegion')
external _RegionBridge get _bridge;

extension type _RegionBridge(JSObject _) implements JSObject {
  external JSPromise<JSUint32Array> match(
    JSUint32Array rgb,
    JSUint32Array candidates,
    JSUint32Array candidateFlags,
    JSNumber flags,
  );
  external JSPromise<JSUint8Array> read(
    JSUint8Array world,
    JSNumber x,
    JSNumber y,
    JSNumber w,
    JSNumber h,
  );
  external JSPromise<JSUint8Array> objects(
    JSUint8Array world,
    JSNumber x,
    JSNumber y,
    JSNumber w,
    JSNumber h,
  );
  external JSPromise<JSUint8Array> replace(
    JSUint8Array world,
    JSNumber x,
    JSNumber y,
    JSNumber w,
    JSNumber h,
    JSUint8Array records,
  );
  external JSPromise<JSUint8Array> operation(
    JSUint8Array world,
    JSString op,
    JSString request,
    JSUint8Array records,
    JSUint8Array objects,
  );
  external JSPromise<JSUint8Array> pixel(
    JSUint8Array world,
    JSNumber x,
    JSNumber y,
    JSNumber w,
    JSNumber h,
    JSUint8Array maps,
    JSUint16Array indices,
  );
}

class WebRegionBackend implements RegionBackend {
  @override
  Future<Uint32List> matchColors(
    Uint32List rgb,
    Uint32List candidateRgb,
    Uint32List candidateFlags, {
    int flags = 0,
  }) async {
    validateColorMatch(rgb, candidateRgb, candidateFlags, flags);
    return (await _bridge
            .match(rgb.toJS, candidateRgb.toJS, candidateFlags.toJS, flags.toJS)
            .toDart)
        .toDart;
  }

  @override
  Future<Uint8List> readRegion(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
  ) async =>
      (await _bridge
              .read(world.toJS, x.toJS, y.toJS, width.toJS, height.toJS)
              .toDart)
          .toDart;
  @override
  Future<Uint8List> readRegionObjects(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
  ) async =>
      (await _bridge
              .objects(world.toJS, x.toJS, y.toJS, width.toJS, height.toJS)
              .toDart)
          .toDart;
  @override
  Future<Uint8List> replaceRegion(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
    Uint8List records,
  ) async =>
      (await _bridge
              .replace(
                world.toJS,
                x.toJS,
                y.toJS,
                width.toJS,
                height.toJS,
                records.toJS,
              )
              .toDart)
          .toDart;
  @override
  Future<Uint8List> regionOperation(
    Uint8List world,
    String operation,
    Map<String, dynamic> request, {
    Uint8List? records,
    Uint8List? objects,
  }) async =>
      (await _bridge
              .operation(
                world.toJS,
                operation.toJS,
                jsonEncode(request).toJS,
                (records ?? Uint8List(0)).toJS,
                (objects ?? Uint8List(0)).toJS,
              )
              .toDart)
          .toDart;
  @override
  Future<Uint8List> writeIndexedPixels(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
    Uint8List maps,
    Uint16List indices,
  ) async {
    validateIndexedPixels(width, height, maps, indices);
    return (await _bridge
            .pixel(
              world.toJS,
              x.toJS,
              y.toJS,
              width.toJS,
              height.toJS,
              maps.toJS,
              indices.toJS,
            )
            .toDart)
        .toDart;
  }
}
