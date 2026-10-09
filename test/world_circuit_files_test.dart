import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/platform/world_circuit_files_native.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

class _LargeFile extends XFile {
  _LargeFile() : super('/virtual/406mb.wld', name: '406mb.wld');
  @override
  Future<int> length() async => 405983441;
  @override
  Future<Uint8List> readAsBytes() =>
      throw StateError('Whole-file bytes are forbidden');
}

void main() {
  test(
    'export rejects original and symlink aliases without changing source',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'computer-export-',
      );
      try {
        final original = File('${directory.path}/original.wld');
        await original.writeAsBytes([1, 2, 3]);
        final source = WorldCircuitSource.file(
          path: original.path,
          length: 3,
          name: 'original.wld',
        );
        await expectLater(
          ensureSeparateCircuitExport(original.path, [source]),
          throwsFormatException,
        );
        if (!Platform.isWindows) {
          final alias = Link('${directory.path}/alias.wld');
          await alias.create(original.path);
          await expectLater(
            ensureSeparateCircuitExport(alias.path, [source]),
            throwsFormatException,
          );
        }
        await ensureSeparateCircuitExport('${directory.path}/copy.wld', [
          source,
        ]);
        expect(await original.readAsBytes(), [1, 2, 3]);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    '406MB native world picker returns only its ranged source handle',
    () async {
      final files = PlatformWorldCircuitFiles(
        picker: (types) async {
          expect(types.single.extensions, ['wld']);
          expect(types.single.uniformTypeIdentifiers, ['public.data']);
          return _LargeFile();
        },
      );
      final source = await files.pick(companion: false);
      expect(source!.path, '/virtual/406mb.wld');
      expect(source.length, 405983441);
      expect(source.blob, isNull);
    },
  );
}
