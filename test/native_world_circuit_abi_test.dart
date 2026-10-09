import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

void main() {
  test(
    'old circuit ABI rejects bytes and streaming before calling native begin',
    () async {
      final directory = await Directory.systemTemp.createTemp('abc-old-abi-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/old_abi.c');
      await source.writeAsString(r'''
#include <stdint.h>
static uint32_t begin_calls;
static uint32_t info_calls;
const char *abc_engine_build_info(void) {
  ++info_calls;
  return "{\"circuitWorldAbiVersion\":1}";
}
int32_t abc_world_circuit_begin(uint32_t world, uint32_t scratch,
    uint32_t auxiliary, uint32_t auxiliary_size, uint32_t budget,
    uint32_t *out) {
  ++begin_calls;
  return -1;
}
uint32_t old_abi_begin_calls(void) { return begin_calls; }
uint32_t old_abi_info_calls(void) { return info_calls; }
''');
      final libraryPath = '${directory.path}/old_abi.so';
      final compilation = await Process.run('cc', [
        '-shared',
        '-fPIC',
        source.path,
        '-o',
        libraryPath,
      ]);
      expect(compilation.exitCode, 0, reason: '${compilation.stderr}');
      final library = DynamicLibrary.open(libraryPath);
      final api = NativeWorldCircuitBindings(library);
      final rejected = isA<EngineException>().having(
        (error) => error.toString(),
        'ABI diagnostic',
        contains('Unsupported world circuit ABI: 1 (expected 2)'),
      );
      expect(
        () => api.dispatch('worldCircuitOpen', [
          Uint8List.fromList([1]),
        ]),
        throwsA(rejected),
      );
      await expectLater(
        api.dispatch('worldCircuitOpenSource', [
          {
            'path': '${directory.path}/unused.wld',
            'length': 1,
            'name': 'unused.wld',
          },
        ]) as Future<Object?>,
        throwsA(rejected),
      );
      expect(
        library.lookupFunction<Uint32 Function(), int Function()>(
          'old_abi_begin_calls',
        )(),
        0,
      );
      expect(
        library.lookupFunction<Uint32 Function(), int Function()>(
          'old_abi_info_calls',
        )(),
        1,
        reason: 'The host caches build identity for both open paths.',
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'ABI2 without pixel capability cannot enable a misleading ON mode',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'abc-old-pixel-mode-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/old_pixel_mode.c');
      await source.writeAsString(r'''
#include <stdint.h>
#include <string.h>
static uint32_t command_calls;
const char *abc_engine_build_info(void) {
  return "{\"circuitWorldAbiVersion\":2}";
}
int32_t abc_world_open(const void *bytes, uint32_t size, uint32_t *out) {
  *out = 1; return 0;
}
int32_t abc_world_circuit_begin(uint32_t world, uint32_t scratch,
    uint32_t budget, uint32_t *out) { *out = 1; return 0; }
int32_t abc_world_circuit_step(uint32_t id, uint32_t budget,
    uint32_t *event, void **data) {
  memset(event, 0, 12 * sizeof(uint32_t)); event[0] = 2; event[1] = 4;
  *data = 0; return 0;
}
int32_t abc_world_circuit_stats(uint32_t id, uint32_t *stats) {
  memset(stats, 0, 24 * sizeof(uint32_t)); stats[0] = 2; return 0;
}
int32_t abc_world_circuit_command(uint32_t id, const void *words,
    const void *records) { ++command_calls; return 0; }
int32_t abc_world_circuit_close(uint32_t id) { return 0; }
int32_t abc_world_close(uint32_t id) { return 0; }
uint32_t old_pixel_mode_command_calls(void) { return command_calls; }
''');
      final libraryPath = '${directory.path}/old_pixel_mode.so';
      final compilation = await Process.run('cc', [
        '-shared',
        '-fPIC',
        source.path,
        '-o',
        libraryPath,
      ]);
      expect(compilation.exitCode, 0, reason: '${compilation.stderr}');
      final library = DynamicLibrary.open(libraryPath);
      final api = NativeWorldCircuitBindings(library);
      final opened = api.dispatch('worldCircuitOpen', [
        Uint8List.fromList([1]),
      ]) as Map;
      final session = opened['session'] as int;
      addTearDown(() => api.dispatch('worldCircuitClose', [session]));
      final command = WorldCircuitCommand.optimization(true);
      expect(
        () => api.dispatch('worldCircuitCommand', [
          session,
          command.words,
          command.records,
        ]),
        throwsA(
          isA<EngineException>().having(
            (error) => error.toString(),
            'capability diagnostic',
            contains('不支持 WireHead 式像素规则'),
          ),
        ),
      );
      expect(
        library.lookupFunction<Uint32 Function(), int Function()>(
          'old_pixel_mode_command_calls',
        )(),
        0,
      );
    },
    skip: !Platform.isLinux,
  );
}
