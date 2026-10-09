import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_js/javascript_runtime.dart';
import 'package:flutter_js/quickjs/ffi.dart' as qjs;
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_circuit_rules_bindings.dart';
import 'package:terraforge/engine/native_circuit_rules_runtime.dart';
import 'package:terraforge/engine/native_quickjs_runtime.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

const _proofSource = r'''
globalThis.TerraCircuitRules = {
  invoke(method) {
    function native(op, args) {
      const value = sendMessage('terraCircuitNative', JSON.stringify({op, args}));
      if (!value || typeof value.then === 'function') throw new Error('Callback was not synchronous');
      if (value.status < 0) throw Object.assign(new Error('Native failure'), {nativeStatus: value.status});
      return value;
    }
    if (method === 'error') return native('stats', [4294967295]);
    if (method === 'async') return Promise.resolve(1);
    if (method === 'timer') return setTimeout(() => {}, 1);
    if (method === 'huge') return 'x'.repeat(17 * 1024 * 1024);
    if (method === 'dispose') return null;
    if (method === 'resume') {
      const handle = globalThis.retainedHandle;
      try {
        native('patch', [handle, [2,0,0,1]]);
        return {second: native('step', [handle, 4096, 4096]), stats: native('stats', [handle]).words};
      } finally { native('close', [handle]); globalThis.retainedHandle = null; }
    }
    const abi = native('abi', []).abi;
    const handle = native('create', [4, 2, 3, 1048576]).handle;
    try {
      // A wire reaches a shape-changing device; the outgoing neighbour is
      // removed synchronously while C is paused on that device's tile hit.
      native('load', [handle, [0,0,1,0, 1,0,1,1, 2,0,1,1]]);
      while (native('compile', [handle, 4096]).status === 1) {}
      native('begin', [handle, [0,0], 0, 1, 100]);
      const first = native('step', [handle, 4096, 4096]);
      if (first.status !== 1 || first.meta[0] !== 2 || first.events[4] !== 1 || !(first.events[7] & 1)) throw new Error('Did not pause at the device');
      if (method === 'retain') { globalThis.retainedHandle = handle; return first; }
      native('patch', [handle, [2,0,0,1]]);
      const second = native('step', [handle, 4096, 4096]);
      const stats = native('stats', [handle]).words;
      native('cancel', [handle]);
      return {abi, first, second, stats};
    } finally { if (globalThis.retainedHandle !== handle) native('close', [handle]); }
  }
};
''';

void main() {
  final libraryPath = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  if (libraryPath == null) {
    throw StateError(
      'Set TERRAFORGE_ENGINE_LIBRARY and LIBQUICKJSC_TEST_PATH for this executable native proof.',
    );
  }

  test('real JS callback synchronously patches paused native traversal in an isolate', () async {
    final proof = await Isolate.run(() {
      final runtime = NativeCircuitRulesRuntime(
        DynamicLibrary.open(libraryPath),
        _proofSource,
      );
      try {
        return runtime.invoke('proof', []) as Map;
      } finally {
        runtime.dispose();
      }
    });
    expect(proof['abi'], 1);
    expect((proof['first'] as Map)['events'], [0, 0, 0, 2, 1, 0, 2, 1]);
    expect((proof['second'] as Map)['status'], 0);
    expect((proof['second'] as Map)['events'], isEmpty);
    expect((proof['stats'] as List)[9], 2);
  });

  test(
    'invalid input and stale handles are rejected before native dispatch',
    () {
      final api = NativeCircuitRulesBindings(DynamicLibrary.open(libraryPath));
      Map call(String op, List<Object?> args) =>
          api.dispatch({'op': op, 'args': args});
      try {
        expect(call('create', [-1, 2, 1, 1024])['status'], -1);
        expect(call('create', [2.5, 2, 1, 1024])['status'], -1);
        expect(call('stats', [123])['status'], -2);
        final handle = call('create', [4, 4, 6, 1048576])['handle'] as int;
        expect(call('load', [handle, List.filled(4097 * 4, 0)])['status'], -1);
        expect(
          call('load', [
            handle,
            [0, 0, 1, 6],
          ])['status'],
          -1,
        );
        for (var routing = 0; routing <= 5; routing++) {
          expect(
            call('load', [
              handle,
              [routing % 4, routing ~/ 4, 1, routing],
            ])['status'],
            0,
          );
        }
        expect(call('compile', [handle, 4096])['status'], 0);
        expect(
          call('begin', [
            handle,
            [0, 0],
            0,
            1,
            1,
          ])['status'],
          0,
        );
        expect(call('step', [handle, 4096, 4096])['status'], -4);
        expect(call('stats', [handle])['words'][7], 0);
        expect(call('close', [handle])['status'], 0);
        expect(call('stats', [handle])['status'], -2);
      } finally {
        api.dispose();
      }
      expect(call('abi', [])['status'], -3);
    },
  );

  test(
    'JS errors retain native status and accidental promises are rejected',
    () {
      final runtime = NativeCircuitRulesRuntime(
        DynamicLibrary.open(libraryPath),
        _proofSource,
      );
      try {
        expect(
          () => runtime.invoke('error', []),
          throwsA(isA<EngineException>().having((e) => e.code, 'status', -2)),
        );
        expect(
          () => runtime.invoke('async', []),
          throwsA(isA<EngineException>()),
        );
        // Failure does not strand the native graph or poison the JS context.
        expect((runtime.invoke('proof', []) as Map)['abi'], 1);
      } finally {
        runtime.dispose();
      }
    },
  );

  test('request and response envelopes have finite byte budgets', () {
    final runtime = NativeCircuitRulesRuntime(
      DynamicLibrary.open(libraryPath),
      _proofSource,
    );
    try {
      expect(
        () => runtime.invoke('proof', ['x' * (17 * 1024 * 1024)]),
        throwsA(isA<EngineException>()),
      );
      expect(() => runtime.invoke('huge', []), throwsA(isA<EngineException>()));
      expect(
        () => runtime.invoke('timer', []),
        throwsA(isA<EngineException>()),
      );
      expect((runtime.invoke('proof', []) as Map)['abi'], 1);
    } finally {
      runtime.dispose();
    }
  });

  test('failed initialization and repeated disposal release callbacks and native handles', () {
    final channels = JavascriptRuntime.channelFunctionsRegistered.length;
    final owners = qjs.runtimeOpaques.length;
    for (var i = 0; i < 20; i++) {
      expect(
        () => NativeCircuitRulesRuntime(
          DynamicLibrary.open(libraryPath),
          "sendMessage('terraCircuitNative', JSON.stringify({op:'create',args:[4,4,6,1048576]})); throw new Error('intentional initialization failure');",
        ),
        throwsA(isA<EngineException>()),
      );
      final runtime = NativeCircuitRulesRuntime(
        DynamicLibrary.open(libraryPath),
        _proofSource,
      );
      expect((runtime.invoke('proof', []) as Map)['abi'], 1);
      runtime.dispose();
      runtime.dispose();
      expect(
        () => runtime.invoke('proof', []),
        throwsA(isA<EngineException>()),
      );
      expect(JavascriptRuntime.channelFunctionsRegistered.length, channels);
      expect(qjs.runtimeOpaques.length, owners);
    }
  });

  test('QuickJS rejects allocations above its actual C heap limit', () {
    final runtime = createBoundedQuickJsRuntime(heapBytes: 1024 * 1024);
    try {
      final tooLarge = runtime.evaluate('new ArrayBuffer(8 * 1024 * 1024)');
      expect(tooLarge.isError, isTrue);
      expect(runtime.evaluate('1 + 1').stringResult, '2');
    } finally {
      runtime.dispose();
    }
  }, skip: Platform.isIOS || Platform.isMacOS);

  test('native graph reservations are bounded and released on close', () {
    final api = NativeCircuitRulesBindings(DynamicLibrary.open(libraryPath));
    Map call(String op, List<Object?> args) =>
        api.dispatch({'op': op, 'args': args});
    try {
      final one = call('create', [4, 4, 1, 128 * 1024 * 1024]);
      final two = call('create', [4, 4, 1, 128 * 1024 * 1024]);
      expect(one['status'], 0);
      expect(two['status'], 0);
      expect(call('create', [4, 4, 1, 1024 * 1024])['status'], -4);
      expect(call('close', [one['handle']])['status'], 0);
      expect(call('create', [4, 4, 1, 1024 * 1024])['status'], 0);
    } finally {
      api.dispose();
    }
  });

  test('paused JS graph survives WLD and TCW world close and reopen', () async {
    final bytes = File('assets/qa/synthetic-circuit.wld').readAsBytesSync();
    final result = await Isolate.run(() {
      final library = DynamicLibrary.open(libraryPath);
      final open = library
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Uint32, Pointer<Uint32>),
            int Function(Pointer<Uint8>, int, Pointer<Uint32>)
          >('abc_world_open');
      final close = library
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
            'abc_world_close',
          );
      final input = calloc<Uint8>(bytes.length), out = calloc<Uint32>();
      input.asTypedList(bytes.length).setAll(0, bytes);
      final runtime = NativeCircuitRulesRuntime(library, _proofSource);
      final results = <Map>[];
      int world = 0;
      final tcw = NativeWorldCircuitBindings(library);
      int? session;
      void openWorld() {
        final status = open(input, bytes.length, out);
        if (status != 0) throw StateError('WLD open failed: $status');
        world = out.value;
      }

      void closeWorld() {
        final status = close(world);
        if (status != 0) throw StateError('WLD close failed: $status');
        world = 0;
      }

      try {
        openWorld();
        runtime.invoke('retain', []);
        closeWorld();
        openWorld();
        results.add(runtime.invoke('resume', []) as Map);
        closeWorld();
        session =
            (tcw.dispatch('worldCircuitOpen', [bytes, null]) as Map)['session']
                as int;
        runtime.invoke('retain', []);
        final trigger = WorldCircuitCommand.trigger(
          2,
          10,
          mask: 1,
          hitSwitch: false,
        );
        tcw.dispatch('worldCircuitCommand', [
          session,
          trigger.words,
          trigger.records,
        ]);
        tcw.dispatch('worldCircuitClose', [session]);
        session = null;
        session =
            (tcw.dispatch('worldCircuitOpen', [bytes, null]) as Map)['session']
                as int;
        results.add(runtime.invoke('resume', []) as Map);
        return results;
      } finally {
        runtime.dispose();
        if (world != 0) closeWorld();
        if (session != null) tcw.dispatch('worldCircuitClose', [session]);
        calloc.free(input);
        calloc.free(out);
      }
    });
    expect(result, hasLength(2));
    for (final proof in result) {
      expect((proof['second'] as Map)['status'], 0);
      expect((proof['second'] as Map)['events'], isEmpty);
      expect((proof['stats'] as List)[9], 2);
    }
  });
}
