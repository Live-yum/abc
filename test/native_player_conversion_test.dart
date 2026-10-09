import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/player_conversion.dart';
import 'package:terraforge/engine/player_schema.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/player_projection_factory.dart';

typedef _ReadC = Int32 Function(
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
);
typedef _ReadD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>);

void main() {
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  test(
    'owning-isolate projection never mutates live source and rejects patches',
    () async {
      final engine = createTerraEngine();
      final source = await (engine as CreatablePlayerEngine).createPlayer(
        'Synthetic source',
      );
      try {
        final before = await engine.save(source);
        final model = await engine.inspect(source);
        final backend = createPlayerProjectionBackend(engine)!;
        for (final target in [38, 135, 218, 279, 326]) {
          final candidate = PlayerConversion.prepare(model, target).candidate;
          final binary = await backend.projectPlayer(candidate);
          final temporary = await engine.open(binary, kind: 'plr');
          try {
            expect((await engine.inspect(temporary))['version'], target);
            expect(await engine.save(temporary), binary);
          } finally {
            await engine.close(temporary);
          }
          expect(await engine.save(source), before);
        }
        await expectLater(
          engine.mutate(source, 'player_patch', {
            'patch': {'version': 279},
          }),
          throwsA(isA<EngineException>()),
        );
        await expectLater(
          backend.projectPlayer({'version': 326}),
          throwsA(isA<EngineException>()),
        );
        expect(await engine.save(source), before);
      } finally {
        await engine.close(source);
      }
    },
    skip: library == null
        ? 'Requires the genuine native engine library.'
        : false,
  );
  test(
    'real codec temporary targets project loss without mutating source',
    () {
      final lib = DynamicLibrary.open(library!);
      final openJson = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Uint32>),
            int Function(Pointer<Utf8>, Pointer<Uint32>)
          >('abc_player_open_json');
      final open = lib
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Uint32, Pointer<Uint32>),
            int Function(Pointer<Uint8>, int, Pointer<Uint32>)
          >('abc_player_open');
      final close = lib
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
            'abc_player_close',
          );
      final save = lib.lookupFunction<_ReadC, _ReadD>('abc_player_save');
      final json = lib.lookupFunction<_ReadC, _ReadD>('abc_player_json');
      Uint8List read(int handle, _ReadD fn) {
        final required = calloc<Uint32>();
        Pointer<Uint8> output = nullptr;
        try {
          expect(fn(handle, nullptr, 0, required), 0);
          expect(required.value, inInclusiveRange(1, 4 * 1024 * 1024));
          output = calloc<Uint8>(required.value);
          expect(fn(handle, output, required.value, required), 0);
          return Uint8List.fromList(output.asTypedList(required.value));
        } finally {
          if (output != nullptr) calloc.free(output);
          calloc.free(required);
        }
      }

      final source = blankPlayer('Synthetic conversion')
        ..['customUnknown'] = {'preserveUntilProjection': true};
      // Native Int64 JSON is a decimal number. No JavaScript number conversion.
      (source['metadata'] as Map)['magicAndType'] = 244154697780061554;
      (source['inventory'] as List)[50] = {
        'itemType': 8,
        'stack': 2,
        'prefix': 0,
        'favorited': true,
      };
      final unchanged = jsonEncode(source);
      for (final target in [38, 135, 218, 279, 326]) {
        final plan = PlayerConversion.prepare(source, target);
        final text = jsonEncode(plan.candidate).toNativeUtf8();
        final handle = calloc<Uint32>();
        Uint8List binary;
        try {
          expect(openJson(text, handle), 0);
          binary = read(handle.value, save);
        } finally {
          if (handle.value != 0) expect(close(handle.value), 0);
          calloc.free(text);
          calloc.free(handle);
        }
        final input = calloc<Uint8>(binary.length);
        final reopened = calloc<Uint32>();
        try {
          input.asTypedList(binary.length).setAll(0, binary);
          expect(open(input, binary.length, reopened), 0);
          final data = read(reopened.value, json);
          final decoded = Map<String, Object?>.from(
            jsonDecode(utf8.decode(data.sublist(0, data.length - 1))) as Map,
          );
          expect(decoded['version'], target);
          expect(read(reopened.value, save), binary);
          final preview = plan.reviewProjection(decoded);
          expect(
            preview.changes.any(
              (change) => change.path == '/customUnknown' && change.removed,
            ),
            isTrue,
          );
          expect(preview.requiresLossConfirmation, isTrue);
          if (target == 38) {
            expect(
              preview.changes.any((change) => change.path == '/inventory/50'),
              isTrue,
            );
          }
          expect(jsonEncode(source), unchanged);
        } finally {
          if (reopened.value != 0) expect(close(reopened.value), 0);
          calloc.free(input);
          calloc.free(reopened);
        }
      }
    },
    skip: library == null
        ? 'Requires the genuine native engine library.'
        : false,
  );
}
