import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'engine.dart';
import 'region_backend.dart';
import 'region_backend_native.dart';
import 'circuit_backend.dart';
import 'native_circuit_bindings.dart';
import 'player_schema.dart';
import 'player_projection_backend.dart';
import 'world_circuit_backend.dart';
import 'native_world_circuit_bindings.dart';
import 'circuit_rules_backend.dart';
import 'native_circuit_rules_runtime.dart';
import 'world_map_backend.dart';

final TerraEngine _sharedEngine = _NativeEngine();
TerraEngine createTerraEngine() => _sharedEngine;

/// One long-lived isolate owns the process-global C runtime. Requests execute
/// synchronously inside that isolate, never on Flutter's rendering isolate.
class _NativeEngine
    implements
        TerraEngine,
        CreatablePlayerEngine,
        PlayerProjectionBackend,
        CircuitBackend,
        RegionBackend,
        WorldCircuitSourceBackend,
        WorldMapBackend,
        CircuitRulesBackend {
  Future<void>? _circuitRulesReady;

  @override
  Future<Uint8List> generateWorldMap(
    EngineDocument world, {
    Map<String, Object?>? markers,
  }) async => (await _call('generateMap', [
    world.handle,
    world.kind,
    markers == null ? null : validatedMapMarkers(markers),
  ])) as Uint8List;

  @override
  Future<Object?> invokeCircuitRules(String method, List<Object?> args) async {
    if (method == 'dispose' || method == 'host.reset') {
      if (args.isNotEmpty) {
        throw const EngineException('电路规则重置不接受参数');
      }
      if (_circuitRulesReady == null) return null;
      try {
        await _circuitRulesReady;
        // FIFO in the existing owner: a reset never interrupts C or closes
        // unrelated WLD/TCW handles while JavaScript is in a native callback.
        return await _call('circuitRulesDispose', []);
      } finally {
        _circuitRulesReady = null;
      }
    }
    await (_circuitRulesReady ??= _initializeCircuitRules());
    return _call('circuitRulesInvoke', [method, args]);
  }

  Future<void> _initializeCircuitRules() async {
    try {
      final source = await rootBundle.loadString(
        'assets/private/circuit_rules_native.js',
        cache: false,
      );
      await _call('circuitRulesInitialize', [source]);
    } catch (_) {
      _circuitRulesReady = null;
      rethrow;
    }
  }

  @override
  Future<WorldCircuitResult> openWorldCircuit(
    Uint8List world, {
    Uint8List? twld,
  }) async => WorldCircuitResult.fromMap(
    (await _call('worldCircuitOpen', [world, twld])) as Map,
  );
  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    WorldCircuitSource? twld,
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    var polling = false, finished = false;
    final timer = onProgress == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 100), (_) async {
            if (polling || finished) return;
            polling = true;
            try {
              final p = await worldCircuitProgress();
              if (!finished && p != null) onProgress(p);
            } catch (_) {
              // The owning operation reports its own error. A progress poll
              // racing a failed/closed owner must not create an unhandled task.
            } finally {
              polling = false;
            }
          });
    try {
      return WorldCircuitResult.fromMap(
        (await _call('worldCircuitOpenSource', [
          world.toFileMap(),
          twld?.toFileMap(),
        ])) as Map,
      );
    } finally {
      finished = true;
      timer?.cancel();
    }
  }

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() async {
    final value = await _call('worldCircuitProgress', []);
    return value == null ? null : WorldCircuitProgress.fromMap(value as Map);
  }

  @override
  Future<void> cancelWorldCircuitOperation() async {
    await _call('worldCircuitCancelOperation', []);
  }

  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) async {
    if (source.token != null) {
      await _call('worldCircuitReleaseSource', [source.token]);
    }
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async => WorldCircuitResult.fromMap(
    (await _call('worldCircuitCommand', [
      session,
      command.words,
      command.records,
    ])) as Map,
  );
  @override
  Future<void> closeWorldCircuit(int session) async {
    await _call('worldCircuitClose', [session]);
  }

  Future<SendPort>? _worker;
  final Map<int, Completer<Object?>> _pending = {};
  int _sequence = 0;

  Future<SendPort> _start() async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    replies.listen((dynamic raw) {
      final message = raw as List<dynamic>;
      if (message[0] == 'ready') {
        ready.complete(message[1] as SendPort);
      } else if (message[0] == 'startupError') {
        ready.completeError(EngineException(message[1] as String));
        replies.close();
      } else {
        final waiter = _pending.remove(message[0] as int);
        if (message[1] == true) {
          waiter?.complete(message[2]);
        } else {
          waiter?.completeError(
            EngineException(
              message[2] as String,
              message.length > 3 ? message[3] as int? : null,
            ),
          );
        }
      }
    });
    try {
      await Isolate.spawn(_engineWorker, replies.sendPort);
    } catch (_) {
      replies.close();
      rethrow;
    }
    return ready.future;
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    final SendPort port;
    final starting = _worker ??= _start();
    try {
      port = await starting;
    } catch (_) {
      if (identical(_worker, starting)) _worker = null;
      rethrow;
    }
    final id = ++_sequence;
    final result = Completer<Object?>();
    _pending[id] = result;
    port.send([id, method, args]);
    return result.future;
  }

  @override
  Future<Uint32List> matchColors(
    Uint32List rgb,
    Uint32List candidateRgb,
    Uint32List candidateFlags, {
    int flags = 0,
  }) async =>
      (await _call('regionMatch', [rgb, candidateRgb, candidateFlags, flags]))
          as Uint32List;
  @override
  Future<Uint8List> readRegion(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
  ) async =>
      (await _call('regionRead', [world, x, y, width, height])) as Uint8List;
  @override
  Future<Uint8List> readRegionObjects(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
  ) async =>
      (await _call('regionObjects', [world, x, y, width, height])) as Uint8List;
  @override
  Future<Uint8List> replaceRegion(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
    Uint8List records,
  ) async =>
      (await _call('regionReplace', [world, x, y, width, height, records]))
          as Uint8List;
  @override
  Future<Uint8List> regionOperation(
    Uint8List world,
    String operation,
    Map<String, dynamic> request, {
    Uint8List? records,
    Uint8List? objects,
  }) async => (await _call('regionOperation', [
    world,
    operation,
    request,
    records,
    objects,
  ])) as Uint8List;
  @override
  Future<Uint8List> writeIndexedPixels(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
    Uint8List maps,
    Uint16List indices,
  ) async =>
      (await _call('regionPixel', [world, x, y, width, height, maps, indices]))
          as Uint8List;

  @override
  Future<List<int>> propagate(
    int width,
    int height,
    List<int> cells,
    int x,
    int y,
    int colour,
  ) async => ((await _call('circuitPropagate', [
    width,
    height,
    cells,
    x,
    y,
    colour,
  ])) as List).cast<int>();

  @override
  Future<Uint8List> projectPlayer(Map<String, Object?> candidate) async =>
      (await _call('projectPlayer', [candidate])) as Uint8List;

  @override
  Future<EngineDocument> createPlayer(String name) async {
    if (name.trim().isEmpty || name.length > 100) {
      throw const EngineException('人物名称须为 1–100 个字符');
    }
    final value = (await _call('createPlayer', [name])) as List<dynamic>;
    return EngineDocument(
      value[0] as int,
      'plr',
      Map<String, dynamic>.from(value[1] as Map),
    );
  }

  @override
  Future<EngineDocument> open(Uint8List bytes, {required String kind}) async {
    final value = (await _call('open', [bytes, kind])) as List<dynamic>;
    return EngineDocument(
      value[0] as int,
      kind,
      Map<String, dynamic>.from(value[1] as Map),
    );
  }

  @override
  Future<Map<String, dynamic>> inspect(EngineDocument doc) async =>
      Map<String, dynamic>.from(
        (await _call('inspect', [doc.handle, doc.kind])) as Map,
      );
  @override
  Future<void> mutate(
    EngineDocument doc,
    String operation,
    Map<String, dynamic> args,
  ) async {
    await _call('mutate', [doc.handle, doc.kind, operation, args]);
  }

  @override
  Future<Uint8List> save(EngineDocument doc) async =>
      (await _call('save', [doc.handle, doc.kind])) as Uint8List;
  @override
  Future<Uint8List?> preview(EngineDocument doc) async =>
      (await _call('preview', [doc.handle, doc.kind])) as Uint8List?;
  @override
  Future<void> close(EngineDocument doc) async {
    await _call('close', [doc.handle, doc.kind]);
  }
}

void _engineWorker(SendPort replies) {
  late final _Bindings engine;
  try {
    engine = _Bindings(_loadLibrary());
  } catch (error) {
    replies.send(['startupError', '无法加载本地存档引擎：$error']);
    return;
  }
  final requests = ReceivePort();
  Future<void> tail = Future.value();
  replies.send(['ready', requests.sendPort]);
  requests.listen((dynamic raw) {
    final message = raw as List<dynamic>;
    Future<void> execute() async {
      try {
        final value = engine.dispatch(
          message[1] as String,
          message[2] as List<dynamic>,
        );
        final result = value is Future ? await value : value;
        replies.send([message[0], true, result]);
      } catch (error) {
        replies.send([
          message[0],
          false,
          error.toString(),
          error is EngineException ? error.code : null,
        ]);
      }
    }

    // These two controls only read host progress/set a cancellation flag. They
    // never invoke C while another operation is suspended. All engine work
    // remains FIFO on this single owner, including unrelated document requests.
    if (message[1] == 'worldCircuitProgress' ||
        message[1] == 'worldCircuitCancelOperation') {
      unawaited(execute());
    } else {
      tail = tail.then((_) => execute());
    }
  });
}

DynamicLibrary _loadLibrary() {
  final override = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isIOS) return DynamicLibrary.process();
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libabc_engine.so');
  }
  if (Platform.isLinux) {
    final bundled =
        '${File(Platform.resolvedExecutable).parent.path}/lib/libabc_engine.so';
    return DynamicLibrary.open(bundled);
  }
  if (Platform.isMacOS) {
    final executable = File(Platform.resolvedExecutable);
    final bundled =
        '${executable.parent.parent.path}/Frameworks/libabc_engine.dylib';
    if (File(bundled).existsSync()) return DynamicLibrary.open(bundled);
    return DynamicLibrary.open('libabc_engine.dylib');
  }
  if (Platform.isWindows) return DynamicLibrary.open('abc_engine.dll');
  throw const EngineException('此平台没有原生存档引擎');
}

typedef _OpenC = Int32 Function(Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _Open = int Function(Pointer<Uint8>, int, Pointer<Uint32>);
typedef _CloseC = Int32 Function(Uint32);
typedef _Close = int Function(int);
typedef _BufferC = Int32 Function(
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
);
typedef _Buffer = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>);
typedef _SectionC = Int32 Function(
  Uint32,
  Pointer<Utf8>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
);
typedef _Section = int Function(
  int,
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
);
typedef _OperationC = Int32 Function(
  Uint32,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
);
typedef _Operation = int Function(
  int,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
);
typedef _SetC = Int32 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>);
typedef _Set = int Function(int, Pointer<Utf8>, Pointer<Utf8>);
typedef _OpenJsonC = Int32 Function(Pointer<Utf8>, Pointer<Uint32>);
typedef _OpenJson = int Function(Pointer<Utf8>, Pointer<Uint32>);
typedef _PatchC = Int32 Function(Uint32, Pointer<Utf8>);
typedef _Patch = int Function(int, Pointer<Utf8>);
typedef _ImageC = Int32 Function(
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _Image = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _ErrorC = Int32 Function(Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _Error = int Function(Pointer<Uint8>, int, Pointer<Uint32>);

class _Bindings {
  final DynamicLibrary library;
  NativeWorldCircuitBindings? _worldCircuit;
  CircuitNativeBindings? _circuit;
  NativeCircuitRulesRuntime? _circuitRules;
  final _Open worldOpen, playerOpen;
  final _Close worldClose, playerClose;
  final _Buffer worldSave, playerSave, playerJson;
  final _Section worldSection;
  final _Operation worldOperation;
  final _Set playerSet;
  final _Patch playerPatch, playerSetMany;
  final _OpenJson playerOpenJson;
  final _Image worldThumbnail, worldMap;
  final _Error lastError;
  final Set<String> _handles = {};

  _Bindings(DynamicLibrary lib)
    : library = lib,
      worldOpen = lib.lookupFunction<_OpenC, _Open>('abc_world_open'),
      playerOpen = lib.lookupFunction<_OpenC, _Open>('abc_player_open'),
      worldClose = lib.lookupFunction<_CloseC, _Close>('abc_world_close'),
      playerClose = lib.lookupFunction<_CloseC, _Close>('abc_player_close'),
      worldSave = lib.lookupFunction<_BufferC, _Buffer>('abc_world_save'),
      playerSave = lib.lookupFunction<_BufferC, _Buffer>('abc_player_save'),
      playerJson = lib.lookupFunction<_BufferC, _Buffer>('abc_player_json'),
      worldSection = lib.lookupFunction<_SectionC, _Section>(
        'abc_world_section',
      ),
      worldOperation = lib.lookupFunction<_OperationC, _Operation>(
        'abc_world_operation',
      ),
      playerSet = lib.lookupFunction<_SetC, _Set>('abc_player_set'),
      playerPatch = lib.lookupFunction<_PatchC, _Patch>('abc_player_patch'),
      playerSetMany = lib.lookupFunction<_PatchC, _Patch>(
        'abc_player_set_many',
      ),
      playerOpenJson = lib.lookupFunction<_OpenJsonC, _OpenJson>(
        'abc_player_open_json',
      ),
      worldThumbnail = lib.lookupFunction<_ImageC, _Image>(
        'abc_world_thumbnail',
      ),
      worldMap = lib.lookupFunction<_ImageC, _Image>('abc_world_map'),
      lastError = lib.lookupFunction<_ErrorC, _Error>('abc_error') {
    final abi = lib.lookupFunction<Uint32 Function(), int Function()>(
      'abc_engine_abi_version',
    )();
    if (abi != 1) throw EngineException('不支持的原生引擎 ABI：$abi');
  }

  void _check(int status) {
    if (status == 0) return;
    final required = calloc<Uint32>();
    final buffer = calloc<Uint8>(8192);
    var message = '存档引擎错误 $status';
    try {
      if (lastError(buffer, 8192, required) == 0 && required.value > 1) {
        final text = buffer.cast<Utf8>().toDartString();
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map) {
            message = (decoded['message'] ?? decoded['error'] ?? text)
                .toString();
          }
        } catch (_) {
          message = text;
        }
      }
    } finally {
      calloc.free(buffer);
      calloc.free(required);
    }
    throw EngineException(message, status);
  }

  Uint8List _read(
    int Function(Pointer<Uint8>, int, Pointer<Uint32>) read, {
    int maximum = 128 * 1024 * 1024,
  }) {
    final required = calloc<Uint32>();
    Pointer<Uint8> output = nullptr;
    try {
      _check(read(nullptr, 0, required));
      final size = required.value;
      if (size > maximum) throw const EngineException('引擎输出超出安全内存预算');
      if (size == 0) return Uint8List(0);
      output = calloc<Uint8>(size);
      _check(read(output, size, required));
      if (required.value > size) throw const EngineException('引擎输出长度发生变化');
      return Uint8List.fromList(output.asTypedList(required.value));
    } finally {
      if (output != nullptr) calloc.free(output);
      calloc.free(required);
    }
  }

  Object? _decode(Uint8List bytes) {
    final length = bytes.isNotEmpty && bytes.last == 0
        ? bytes.length - 1
        : bytes.length;
    final text = utf8.decode(bytes.sublist(0, length));
    final safe = text.replaceAllMapped(
      RegExp(r'"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?'),
      (match) {
        final token = match[0]!;
        if (token.startsWith('"')) return token;
        if (!token.contains(RegExp('[.eE]'))) {
          if (BigInt.parse(token).abs() > BigInt.from(9007199254740991)) {
            return jsonEncode(token);
          }
        } else {
          final value = double.parse(token);
          if (!value.isFinite || value.abs() > 9007199254740991) {
            throw const EngineException('不精确的引擎数值');
          }
        }
        return token;
      },
    );
    return jsonDecode(safe);
  }

  String _encode(Object? value, [String key = '']) {
    const integerKeys = {
      'magicAndType',
      'favoriteFlags',
      'playTimeTicks',
      'lastSaveUtcTicks',
      'creationTime',
      'lastPlayed',
      'worldGeneratorVersion',
    };
    if (value is String &&
        integerKeys.contains(key) &&
        RegExp(r'^-?\d+$').hasMatch(value)) {
      return value;
    }
    if (value is num && (!value.isFinite || value.abs() > 9007199254740991)) {
      throw const EngineException('不精确的输入数值');
    }
    if (value is Map) {
      return '{${value.entries.map((e) => '${jsonEncode(e.key)}:${_encode(e.value, e.key as String)}').join(',')}}';
    }
    if (value is List) return '[${value.map((e) => _encode(e)).join(',')}]';
    return jsonEncode(value);
  }

  Map<String, dynamic> _inspect(int handle, String kind) {
    if (kind == 'plr') {
      return Map<String, dynamic>.from(
        _decode(
          _read(
            (p, n, r) => playerJson(handle, p, n, r),
            maximum: 16 * 1024 * 1024,
          ),
        ) as Map,
      );
    }
    final result = <String, dynamic>{};
    for (final name in ['header', 'format', 'chests', 'bestiary']) {
      final section = name.toNativeUtf8(allocator: calloc);
      try {
        result[name] = _decode(
          _read(
            (p, n, r) => worldSection(handle, section, p, n, r),
            maximum: 16 * 1024 * 1024,
          ),
        );
      } finally {
        calloc.free(section);
      }
    }
    return result;
  }

  void _operation(int handle, String operation, Map<String, dynamic> args) {
    final op = operation.toNativeUtf8(allocator: calloc);
    final json = _encode(args).toNativeUtf8(allocator: calloc);
    try {
      _read(
        (p, n, r) => worldOperation(handle, op, json, p, n, r),
        maximum: 16 * 1024 * 1024,
      );
    } finally {
      calloc.free(op);
      calloc.free(json);
    }
  }

  Object? dispatch(String method, List<dynamic> args) {
    if (method == 'circuitRulesInitialize') {
      _circuitRules ??= NativeCircuitRulesRuntime(library, args[0] as String);
      return null;
    }
    if (method == 'circuitRulesInvoke') {
      final rules = _circuitRules;
      if (rules == null) throw const EngineException('电路规则模块尚未初始化');
      return rules.invoke(args[0] as String, (args[1] as List).cast<Object?>());
    }
    if (method == 'circuitRulesDispose') {
      try {
        _circuitRules?.dispose();
      } finally {
        _circuitRules = null;
      }
      return null;
    }
    if (method.startsWith('worldCircuit')) {
      return (_worldCircuit ??= NativeWorldCircuitBindings(
        library,
      )).dispatch(method, args);
    }
    if (method.startsWith('region')) {
      return regionDispatch(library, method, args);
    }
    if (method == 'circuitPropagate') {
      return (_circuit ??= CircuitNativeBindings(library)).propagate(args);
    }
    if (method == 'projectPlayer') {
      final candidate = Map<String, dynamic>.from(args[0] as Map);
      final version = candidate['version'];
      if (version is! int || version < 38 || version > 326) {
        throw const EngineException('目标版本必须是 38–326。');
      }
      final encoded = _encode(candidate);
      if (utf8.encode(encoded).length > 4 * 1024 * 1024) {
        throw const EngineException('角色转换模型超过 4 MiB。');
      }
      final json = encoded.toNativeUtf8(allocator: calloc);
      final out = calloc<Uint32>();
      try {
        _check(playerOpenJson(json, out));
        late final Uint8List bytes;
        try {
          bytes = _read(
            (p, n, r) => playerSave(out.value, p, n, r),
            maximum: 2 * 1024 * 1024,
          );
        } finally {
          final handle = out.value;
          out.value = 0;
          _check(playerClose(handle));
        }
        final reopened = dispatch('open', [bytes, 'plr']) as List;
        try {
          if ((reopened[1] as Map)['version'] != version) {
            throw const EngineException('转换后二进制版本不匹配。');
          }
        } finally {
          dispatch('close', [reopened[0], 'plr']);
        }
        return bytes;
      } finally {
        if (out.value != 0) _check(playerClose(out.value));
        calloc.free(json);
        calloc.free(out);
      }
    }
    if (method == 'createPlayer') {
      final name = args[0] as String;
      final json = _encode(blankPlayer(name)).toNativeUtf8(allocator: calloc);
      final out = calloc<Uint32>();
      try {
        _check(playerOpenJson(json, out));
        final handle = out.value;
        late final Uint8List bytes;
        try {
          bytes = _read((p, n, r) => playerSave(handle, p, n, r));
        } finally {
          _check(playerClose(handle));
        }
        return dispatch('open', [bytes, 'plr']);
      } finally {
        calloc.free(json);
        calloc.free(out);
      }
    }
    if (method == 'open') {
      final bytes = args[0] as Uint8List;
      final kind = args[1] as String;
      if (kind != 'wld' && kind != 'plr') {
        throw const EngineException('仅支持 .wld 和 .plr');
      }
      final limit = kind == 'plr' ? 2 * 1024 * 1024 : 64 * 1024 * 1024;
      if (bytes.isEmpty || bytes.length > limit) {
        throw EngineException('存档为空或超过 ${limit ~/ (1024 * 1024)} MiB');
      }
      final input = calloc<Uint8>(bytes.length);
      final out = calloc<Uint32>();
      try {
        input.asTypedList(bytes.length).setAll(0, bytes);
        _check(
          (kind == 'wld' ? worldOpen : playerOpen)(input, bytes.length, out),
        );
        final handle = out.value;
        try {
          final metadata = _inspect(handle, kind);
          _handles.add('$kind:$handle');
          return [handle, metadata];
        } catch (_) {
          (kind == 'wld' ? worldClose : playerClose)(handle);
          rethrow;
        }
      } finally {
        calloc.free(input);
        calloc.free(out);
      }
    }
    final handle = args[0] as int;
    final kind = args[1] as String;
    if (!_handles.contains('$kind:$handle')) {
      throw const EngineException('存档会话已关闭或失效');
    }
    switch (method) {
      case 'generateMap':
        if (kind != 'wld') throw const EngineException('只有世界可以生成 MAP');
        final markers = args[2] as Map?;
        final request = markers == null
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(
                validatedMapMarkers(Map<String, Object?>.from(markers)),
              );
        _operation(
          handle,
          markers == null ? 'render_lit_map' : 'mark_tiles_and_chests_map',
          request,
        );
        final width = calloc<Uint32>(), height = calloc<Uint32>();
        try {
          // Successful copy releases the core's owned MAP media buffer.
          return _read(
            (p, n, r) => worldMap(handle, p, n, r, width, height),
            maximum: 128 * 1024 * 1024,
          );
        } finally {
          calloc.free(width);
          calloc.free(height);
        }
      case 'inspect':
        return _inspect(handle, kind);
      case 'save':
        return _read(
          (p, n, r) =>
              (kind == 'wld' ? worldSave : playerSave)(handle, p, n, r),
        );
      case 'close':
        _check((kind == 'wld' ? worldClose : playerClose)(handle));
        _handles.remove('$kind:$handle');
        return null;
      case 'mutate':
        final operation = args[2] as String;
        final data = Map<String, dynamic>.from(args[3] as Map);
        if (kind == 'wld') {
          _operation(handle, operation, data);
          return null;
        }
        if (operation == 'player_patch' || operation == 'patch') {
          final patch = data['patch'] ?? data;
          final before = _inspect(handle, kind);
          if (patch is! Map || patch.isEmpty) {
            throw const EngineException('人物修改不能为空');
          }
          if ((before['version'] as num) > 326) {
            throw const EngineException('此版本人物只读');
          }
          final edits = <String>[];
          for (final entry in patch.entries) {
            final key = entry.key as String;
            if (!before.containsKey(key) ||
                key == 'metadata' ||
                key == 'tailLayout') {
              throw EngineException('不支持的人物字段：$key');
            }
            if (key == 'version' && entry.value != before[key]) {
              throw const EngineException('不支持版本转换');
            }
            final pointer =
                '/${key.replaceAll('~', '~0').replaceAll('/', '~1')}';
            edits.add(
              '{"path":${jsonEncode(pointer)},"value":${_encode(entry.value, key)}}',
            );
          }
          final json = '[${edits.join(',')}]'.toNativeUtf8(allocator: calloc);
          try {
            _check(playerSetMany(handle, json));
          } finally {
            calloc.free(json);
          }
        } else if (operation == 'set' || operation == 'set_field') {
          final pointer = data['pointer'];
          if (pointer is! String || !data.containsKey('value')) {
            throw const EngineException('人物编辑需要 pointer 和 value');
          }
          final p = pointer.toNativeUtf8(allocator: calloc);
          final v = _encode(
            data['value'],
            pointer.split('/').last,
          ).toNativeUtf8(allocator: calloc);
          try {
            _check(playerSet(handle, p, v));
          } finally {
            calloc.free(p);
            calloc.free(v);
          }
        } else if (operation == 'compatibility_patch') {
          final patch = jsonEncode(data).toNativeUtf8(allocator: calloc);
          try {
            _check(playerPatch(handle, patch));
          } finally {
            calloc.free(patch);
          }
        } else {
          throw EngineException('不支持的人物操作：$operation');
        }
        return null;
      case 'preview':
        if (kind == 'plr') return null;
        _operation(handle, 'render_preview_png', {
          'max_w': 1024,
          'max_h': 1024,
        });
        final width = calloc<Uint32>(), height = calloc<Uint32>();
        try {
          return _read(
            (p, n, r) => worldThumbnail(handle, p, n, r, width, height),
            maximum: 32 * 1024 * 1024,
          );
        } finally {
          calloc.free(width);
          calloc.free(height);
        }
      default:
        throw EngineException('未知引擎操作：$method');
    }
  }
}
