import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'engine.dart';
import 'region_backend.dart';

typedef _OpC = Int32 Function(
  Pointer<Uint8>,
  Uint32,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _Op = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _ReadC = Int32 Function(
  Pointer<Uint8>,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _Read = int Function(
  Pointer<Uint8>,
  int,
  int,
  int,
  int,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _ReplaceC = Int32 Function(
  Pointer<Uint8>,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _Replace = int Function(
  Pointer<Uint8>,
  int,
  int,
  int,
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _PixelC = Int32 Function(
  Pointer<Uint8>,
  Uint32,
  Int32,
  Int32,
  Uint32,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint16>,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _Pixel = int Function(
  Pointer<Uint8>,
  int,
  int,
  int,
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint16>,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _ErrorC = Int32 Function(Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _Error = int Function(Pointer<Uint8>, int, Pointer<Uint32>);

typedef _MatchC = Int32 Function(
  Pointer<Uint32>,
  Uint32,
  Pointer<Uint32>,
  Uint32,
  Uint32,
  Pointer<Uint32>,
);
typedef _Match = int Function(
  Pointer<Uint32>,
  int,
  Pointer<Uint32>,
  int,
  int,
  Pointer<Uint32>,
);

Uint32List regionMatch(DynamicLibrary lib, List<dynamic> args) {
  final rgb = args[0] as Uint32List,
      candidates = args[1] as Uint32List,
      flags = args[2] as Uint32List,
      mode = args[3] as int;
  validateColorMatch(rgb, candidates, flags, mode);
  final c = calloc<Uint32>(candidates.length * 2 + 1),
      q = calloc<Uint32>(rgb.length + 1),
      out = calloc<Uint32>(rgb.length + 1);
  try {
    for (var i = 0; i < candidates.length; i++) {
      c[i * 2] = candidates[i];
      c[i * 2 + 1] = flags[i];
    }
    q.asTypedList(rgb.length).setAll(0, rgb);
    final status = lib.lookupFunction<_MatchC, _Match>('abc_region_match')(
      c,
      candidates.length,
      q,
      rgb.length,
      mode,
      out,
    );
    if (status != 0) {
      throw EngineException('Core colour matching failed', status);
    }
    return Uint32List.fromList(out.asTypedList(rgb.length));
  } finally {
    calloc.free(c);
    calloc.free(q);
    calloc.free(out);
  }
}

/// Invoked ONLY from the existing shared native engine worker.
Object regionDispatch(DynamicLibrary lib, String method, List<dynamic> args) {
  if (method == 'regionMatch') return regionMatch(lib, args);
  final allocated = <Pointer>[];
  Pointer<Uint8> copy(Uint8List bytes) {
    if (bytes.isEmpty) return nullptr;
    final p = calloc<Uint8>(bytes.length);
    allocated.add(p);
    p.asTypedList(bytes.length).setAll(0, bytes);
    return p;
  }

  Pointer<Utf8> text(String value) {
    final p = value.toNativeUtf8();
    allocated.add(p);
    return p;
  }

  final world = args[0] as Uint8List;
  if (method == 'regionRead' ||
      method == 'regionObjects' ||
      method == 'regionReplace') {
    validateRegionBounds(
      args[1] as int,
      args[2] as int,
      args[3] as int,
      args[4] as int,
    );
  }
  if (method == 'regionPixel' &&
      ((args[1] as int) < -0x80000000 ||
          (args[1] as int) > 0x7fffffff ||
          (args[2] as int) < -0x80000000 ||
          (args[2] as int) > 0x7fffffff)) {
    throw ArgumentError('Pixel origin outside signed32 range');
  }
  final out = calloc<Pointer<Uint8>>(), size = calloc<Uint32>();
  try {
    final input = copy(world);
    int status;
    if (method == 'regionRead' || method == 'regionObjects') {
      for (final v in args.skip(1)) {
        if (v is! int || v < 0) throw ArgumentError('Invalid region bounds');
      }
      status =
          lib.lookupFunction<_ReadC, _Read>(
            method == 'regionRead' ? 'abc_region_read' : 'abc_region_objects',
          )(
            input,
            world.length,
            args[1] as int,
            args[2] as int,
            args[3] as int,
            args[4] as int,
            out,
            size,
          );
    } else if (method == 'regionReplace') {
      final records = args[5] as Uint8List;
      status = lib.lookupFunction<_ReplaceC, _Replace>('abc_region_replace')(
        input,
        world.length,
        args[1] as int,
        args[2] as int,
        args[3] as int,
        args[4] as int,
        copy(records),
        records.length,
        out,
        size,
      );
    } else if (method == 'regionPixel') {
      final maps = args[5] as Uint8List, indices = args[6] as Uint16List;
      validateIndexedPixels(args[3] as int, args[4] as int, maps, indices);
      status = lib.lookupFunction<_PixelC, _Pixel>('abc_region_pixel')(
        input,
        world.length,
        args[1] as int,
        args[2] as int,
        args[3] as int,
        args[4] as int,
        copy(maps),
        maps.length ~/ 12,
        copy(
          Uint8List.view(
            indices.buffer,
            indices.offsetInBytes,
            indices.lengthInBytes,
          ),
        ).cast(),
        out,
        size,
      );
    } else {
      final records = args.length > 3 ? args[3] as Uint8List? : null,
          objects = args.length > 4 ? args[4] as Uint8List? : null;
      status = lib.lookupFunction<_OpC, _Op>('abc_region_operation')(
        input,
        world.length,
        text(args[1] as String),
        text(jsonEncode(args[2])),
        copy(records ?? Uint8List(0)),
        records?.length ?? 0,
        copy(objects ?? Uint8List(0)),
        objects?.length ?? 0,
        out,
        size,
      );
    }
    if (status != 0) {
      final error = calloc<Uint8>(8192), required = calloc<Uint32>();
      try {
        lib.lookupFunction<_ErrorC, _Error>('abc_error')(error, 8192, required);
        throw EngineException(error.cast<Utf8>().toDartString(), status);
      } finally {
        calloc.free(error);
        calloc.free(required);
      }
    }
    return Uint8List.fromList(out.value.asTypedList(size.value));
  } finally {
    if (out.value != nullptr) {
      lib.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('abc_free')(out.value.cast());
    }
    calloc.free(out);
    calloc.free(size);
    for (final p in allocated) {
      calloc.free(p);
    }
  }
}
