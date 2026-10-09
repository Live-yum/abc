import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_js/javascript_runtime.dart';
import 'package:flutter_js/javascriptcore/jscore_runtime.dart';

import 'engine.dart';
import 'native_circuit_rules_bindings.dart';
import 'native_quickjs_runtime.dart';

/// Owns the retained private rules bundle in the existing engine isolate.
/// There is no HTTP bridge, browser, MethodChannel or asynchronous native
/// callback: device effects finish before the next native traversal step.
class NativeCircuitRulesRuntime {
  NativeCircuitRulesRuntime(DynamicLibrary library, String source)
    : _native = NativeCircuitRulesBindings(library),
      _runtime = Platform.isIOS || Platform.isMacOS
          ? JavascriptCoreRuntime()
          : createBoundedQuickJsRuntime() {
    try {
      _checkText(source, maxMessageBytes, '电路规则代码');
      // This owner only executes synchronous commands. flutter_js otherwise
      // registers Dart timers that can retain or recreate a disposed runtime.
      JavascriptRuntime
          .channelFunctionsRegistered[_runtime.getEngineInstanceId()]
          ?.remove('SetTimeout');
      _runtime.evaluate('''
        globalThis.setTimeout = globalThis.setInterval = function() {
          throw new Error('Asynchronous circuit timers are disabled');
        };
      ''');
      _runtime.onMessage('terraCircuitNative', _native.dispatch);
      final result = _runtime.evaluate(
        source,
        sourceUrl: 'circuit_rules_native.js',
      );
      if (result.isError) {
        throw EngineException('电路规则初始化失败：${result.stringResult}');
      }
      final ready = _runtime.evaluate(
        "typeof TerraCircuitRules === 'object' && typeof TerraCircuitRules.invoke === 'function'",
      );
      if (ready.isError || ready.stringResult != 'true') {
        throw const EngineException('电路规则模块未提供调用接口');
      }
      _ready = true;
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  final NativeCircuitRulesBindings _native;
  final JavascriptRuntime _runtime;
  static const maxMessageBytes = 16 * 1024 * 1024;
  // The facade checks the payload; leave room for our success/error envelope
  // so a valid boundary-sized response is not rejected after a committed edit.
  static const maxEnvelopeBytes = maxMessageBytes + 8192;
  bool _ready = false;
  bool _closed = false;

  static void _checkText(String text, int maximum, String label) {
    if (text.length > maximum || utf8.encode(text).length > maximum) {
      throw EngineException('$label超过安全大小限制');
    }
  }

  Object? invoke(String method, List<Object?> args) {
    if (_closed) throw const EngineException('电路规则模块已关闭');
    if (method.isEmpty || method.length > 128 || args.length > 8) {
      throw const EngineException('电路规则请求格式无效');
    }
    final encodedMethod = jsonEncode(method);
    final encodedArgs = jsonEncode(args);
    _checkText(encodedArgs, maxMessageBytes, '电路请求');
    final result = _runtime.evaluate('''
      (function() {
        try {
          const value = TerraCircuitRules.invoke($encodedMethod, $encodedArgs);
          if (value && typeof value.then === 'function') throw new Error('电路规则调用必须同步完成');
          const reply = JSON.stringify({ok: true, value: value === undefined ? null : value});
          if (reply.length > $maxEnvelopeBytes) throw new Error('电路响应超过安全大小限制');
          return reply;
        } catch (error) {
          return JSON.stringify({ok: false, error: String(error && error.message || error).slice(0, 4096), code: error && error.nativeStatus});
        }
      })()
    ''');
    if (result.isError) {
      throw EngineException('电路规则执行失败：${result.stringResult}');
    }
    _checkText(result.stringResult, maxEnvelopeBytes, '电路响应');
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stringResult);
    } on FormatException {
      throw const EngineException('电路规则输出不是有效 JSON');
    }
    if (decoded is! Map || decoded['ok'] is! bool) {
      throw const EngineException('电路规则输出格式无效');
    }
    if (decoded['ok'] != true) {
      throw EngineException(
        decoded['error'].toString(),
        decoded['code'] is int ? decoded['code'] as int : null,
      );
    }
    return decoded['value'];
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    try {
      if (_ready) {
        _runtime.evaluate("TerraCircuitRules.invoke('dispose', [])");
      }
    } finally {
      _native.dispose();
      JavascriptRuntime.channelFunctionsRegistered.remove(
        _runtime.getEngineInstanceId(),
      );
      _runtime.dispose();
    }
  }
}
