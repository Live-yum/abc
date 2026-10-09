import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_circuit_rules_runtime.dart';

// The generated corpus contains private-derived documents and stays ignored.
// Generate it using tool/test_circuit_rules.mjs before running this replay.
void main() {
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  if (library == null) {
    throw StateError(
      'Set TERRAFORGE_ENGINE_LIBRARY and LIBQUICKJSC_TEST_PATH.',
    );
  }
  final corpusPath =
      Platform.environment['CIRCUIT_RULES_CORPUS'] ??
      'qa-evidence/circuit-rules-corpus.json';
  final corpus = jsonDecode(File(corpusPath).readAsStringSync()) as Map;
  final source = File('assets/private/circuit_rules_native.js')
      .readAsStringSync();
  final cases = corpus['cases'] as List;
  test(
    'QuickJS native rules exactly match the shared authoritative corpus',
    () async {
      expect(corpus['schema'], 1);
      expect(
        corpus['sourceCommit'],
        '366ebc57751cadfb077f968f4d5069028b3bf9a6',
      );
      final results = await Isolate.run(() {
        final runtime = NativeCircuitRulesRuntime(
          DynamicLibrary.open(library),
          source,
        );
        final results = <Map<String, Object?>>[];
        try {
          for (var index = 0; index < cases.length; index++) {
            final row = cases[index] as Map;
            try {
              final value = runtime.invoke(
                row['method'] as String,
                (row['args'] as List).cast<Object?>(),
              );
              String? documentHash;
              if (value is Map) {
                final packet = value['packet'];
                if (packet is Map) packet.remove('native');
                if (row.containsKey('expectedDocumentSha256')) {
                  documentHash = sha256
                      .convert(utf8.encode(value.remove('document') as String))
                      .toString();
                }
              }
              results.add({'value': value, 'documentHash': documentHash});
            } on EngineException catch (error) {
              results.add({'error': error.message});
            }
            if (index % 25 == 0) {
              stdout.writeln('Native corpus replay: $index / ${cases.length}');
            }
          }
          return results;
        } finally {
          runtime.dispose();
        }
      });
      expect(results, hasLength(cases.length));
      for (var index = 0; index < cases.length; index++) {
        final row = cases[index] as Map, actual = results[index];
        final reason = 'Corpus case $index: ${row['method']}';
        if (row.containsKey('expectedError')) {
          expect(actual['error'], isA<String>(), reason: reason);
        } else {
          expect(
            actual.containsKey('error'),
            isFalse,
            reason: '$reason ${actual['error']}',
          );
          expect(
            actual['documentHash'],
            row['expectedDocumentSha256'],
            reason: reason,
          );
          expect(actual['value'], row['expected'], reason: reason);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
