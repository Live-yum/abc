import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _CreateC = Int32 Function(
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Uint32>,
);
typedef _Create = int Function(int, int, int, int, Pointer<Uint32>);
typedef _RecordsC = Int32 Function(Uint32, Pointer<Uint32>, Uint32);
typedef _Records = int Function(int, Pointer<Uint32>, int);
typedef _CompileC = Int32 Function(Uint32, Uint32, Pointer<Uint32>);
typedef _Compile = int Function(int, int, Pointer<Uint32>);
typedef _BeginC = Int32 Function(
  Uint32,
  Pointer<Uint32>,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
);
typedef _Begin = int Function(int, Pointer<Uint32>, int, int, int, int);
typedef _StepC = Int32 Function(
  Uint32,
  Uint32,
  Pointer<Uint32>,
  Uint32,
  Pointer<Uint32>,
);
typedef _Step = int Function(int, int, Pointer<Uint32>, int, Pointer<Uint32>);
typedef _StatsC = Int32 Function(Uint32, Pointer<Uint32>);
typedef _Stats = int Function(int, Pointer<Uint32>);
typedef _HandleC = Int32 Function(Uint32);
typedef _Handle = int Function(int);

/// Synchronous JSON-to-FFI bridge owned by the serialized engine isolate.
/// Native addresses never leave this class. A callback must not enqueue an
/// engine request: JavaScript is waiting on this very isolate for its result.
class NativeCircuitRulesBindings {
  NativeCircuitRulesBindings(DynamicLibrary library)
    : _abi = library.lookupFunction<Uint32 Function(), int Function()>(
        'abc_circuit_rules_abi_version',
      ),
      _create = library.lookupFunction<_CreateC, _Create>(
        'abc_circuit_rules_create',
      ),
      _load = library.lookupFunction<_RecordsC, _Records>(
        'abc_circuit_rules_load',
      ),
      _compile = library.lookupFunction<_CompileC, _Compile>(
        'abc_circuit_rules_compile',
      ),
      _patch = library.lookupFunction<_RecordsC, _Records>(
        'abc_circuit_rules_patch',
      ),
      _begin = library.lookupFunction<_BeginC, _Begin>(
        'abc_circuit_rules_begin',
      ),
      _step = library.lookupFunction<_StepC, _Step>('abc_circuit_rules_step'),
      _stats = library.lookupFunction<_StatsC, _Stats>(
        'abc_circuit_rules_stats',
      ),
      _cancel = library.lookupFunction<_HandleC, _Handle>(
        'abc_circuit_rules_cancel',
      ),
      _close = library.lookupFunction<_HandleC, _Handle>(
        'abc_circuit_rules_close',
      );

  final int Function() _abi;
  final _Create _create;
  final _Records _load, _patch;
  final _Compile _compile;
  final _Begin _begin;
  final _Step _step;
  final _Stats _stats;
  final _Handle _cancel, _close;
  final Map<int, int> _handles = {};
  int _reservedBytes = 0;
  bool _closed = false;

  static int _word(Object? value, {int minimum = 0, int maximum = 0xffffffff}) {
    if (value is! num ||
        !value.isFinite ||
        value != value.truncateToDouble() ||
        value < minimum ||
        value > maximum) {
      throw const FormatException('电路桥接参数不是有效整数');
    }
    return value.toInt();
  }

  static List<int> _words(Object? value, int stride, int maxRecords) {
    if (value is! List ||
        value.length % stride != 0 ||
        value.length > stride * maxRecords) {
      throw const FormatException('电路桥接记录超出安全批次');
    }
    return value.map(_word).toList(growable: false);
  }

  static T _withWords<T>(List<int> words, T Function(Pointer<Uint32>) use) {
    final pointer = calloc<Uint32>(words.isEmpty ? 1 : words.length);
    try {
      pointer.asTypedList(words.length).setAll(0, words);
      return use(pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  /// Return plain maps immediately; returning a Future changes JS semantics.
  Map<String, Object?> dispatch(Object? request) {
    if (_closed) return {'status': -3, 'error': '电路桥接已关闭'};
    try {
      if (request is! Map ||
          request['op'] is! String ||
          request['args'] is! List) {
        throw const FormatException('电路桥接请求格式无效');
      }
      final op = request['op'] as String;
      final args = request['args'] as List;
      const arities = {
        'abi': 0,
        'create': 4,
        'load': 2,
        'compile': 2,
        'patch': 2,
        'begin': 5,
        'step': 3,
        'stats': 1,
        'cancel': 1,
        'close': 1,
      };
      if (arities[op] != args.length) throw const FormatException('电路桥接操作无效');
      if (op == 'abi') return {'status': 0, 'abi': _abi()};
      if (op == 'create') {
        final width = _word(args[0], minimum: 1, maximum: 65536);
        final height = _word(args[1], minimum: 1, maximum: 65536);
        final cells = _word(args[2], minimum: 1, maximum: 1048576);
        final bytes = _word(args[3], minimum: 1, maximum: 128 * 1024 * 1024);
        if (_handles.length >= 8 ||
            _reservedBytes + bytes > 256 * 1024 * 1024) {
          return {'status': -4, 'error': '电路原生所有者内存预算已用完'};
        }
        return _withWords([0], (out) {
          final status = _create(width, height, cells, bytes, out);
          if (status == 0) {
            _handles[out.value] = bytes;
            _reservedBytes += bytes;
          }
          return {'status': status, 'handle': out.value};
        });
      }
      final handle = _word(args[0], minimum: 1);
      if (!_handles.containsKey(handle)) return {'status': -2};
      switch (op) {
        case 'load':
        case 'patch':
          final words = _words(args[1], 4, 4096);
          return _withWords(
            words,
            (input) => {
              'status': (op == 'load' ? _load : _patch)(
                handle,
                input,
                words.length ~/ 4,
              ),
            },
          );
        case 'compile':
          final count = _word(args[1], minimum: 1, maximum: 4096);
          return _withWords([0], (out) {
            final status = _compile(handle, count, out);
            return {'status': status, 'compiled': out.value};
          });
        case 'begin':
          final words = _words(args[1], 2, 8192);
          final colour = _word(args[2], maximum: 3);
          final flags = _word(args[3], maximum: 1);
          final limit = _word(args[4], minimum: 1);
          return _withWords(
            words,
            (input) => {
              'status': _begin(
                handle,
                input,
                words.length ~/ 2,
                colour,
                flags,
                limit,
              ),
            },
          );
        case 'step':
          final maxNodes = _word(args[1], minimum: 1, maximum: 4096);
          final capacity = _word(args[2], minimum: 1, maximum: 4096);
          return _withWords(
            List.filled(4, 0),
            (meta) => _withWords(List.filled(capacity * 4, 0), (events) {
              final status = _step(handle, maxNodes, events, capacity, meta);
              if (meta[0] > maxNodes || meta[1] > capacity) {
                _cancel(handle);
                return {'status': -4, 'error': '电路输出超过桥接缓冲区'};
              }
              return {
                'status': status,
                'meta': meta.asTypedList(4).toList(),
                'events': events.asTypedList(meta[1] * 4).toList(),
              };
            }),
          );
        case 'stats':
          return _withWords(List.filled(16, 0), (out) {
            final status = _stats(handle, out);
            return {'status': status, 'words': out.asTypedList(16).toList()};
          });
        case 'cancel':
          return {'status': _cancel(handle)};
        case 'close':
          final status = _close(handle);
          if (status == 0) _reservedBytes -= _handles.remove(handle)!;
          return {'status': status};
        default:
          throw const FormatException('电路桥接操作无效');
      }
    } on FormatException catch (error) {
      return {'status': -1, 'error': error.message};
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final handle in _handles.keys) {
      _cancel(handle);
      _close(handle);
    }
    _handles.clear();
    _reservedBytes = 0;
  }
}
