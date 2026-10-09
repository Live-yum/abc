import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'map_fixture.dart';
import 'map_metadata.dart';
import 'map_perf_core.dart';

void main(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 == args.length) throw ArgumentError('Expected --option value');
    options[args[i]] = args[i + 1];
  }
  final fixtures = [
    MapPerfFixture(
      'synthetic-map-legacy319',
      'repository-authored',
      syntheticMap(chunked: false, width: 4200, height: 1200),
    ),
    MapPerfFixture(
      'synthetic-map-chunk315',
      'repository-authored',
      syntheticMap(width: 512, height: 256),
    ),
  ];
  final input = options['--input'];
  String? originalHash;
  if (input != null) {
    final bytes = File(input).readAsBytesSync();
    originalHash = sha256.convert(bytes).toString();
    fixtures.add(
      MapPerfFixture(
        'local-map-1',
        options['--provenance'] ?? 'authorized-local-input',
        bytes,
      ),
    );
  }
  final report = benchmarkMaps(
    fixtures,
    iterations: int.parse(options['--iterations'] ?? '10'),
    runtime: 'dart-${Platform.operatingSystem}',
    tier: Platform.environment['ABC_PERF_TIER'] ?? 'local',
    buildMode: const String.fromEnvironment(
      'ABC_MAP_BUILD_MODE',
      defaultValue: 'jit',
    ),
    memorySnapshot: () => {'rssBytes': ProcessInfo.currentRss},
  );
  if (input != null &&
      sha256.convert(File(input).readAsBytesSync()).toString() !=
          originalHash) {
    throw StateError('Source file changed during benchmark');
  }
  report.addAll(mapReportMetadata());
  report['sourcePreserved'] = true;
  final output = options['--output'];
  final text = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
  if (output == null) {
    stdout.write(text);
  } else {
    File(output).parent.createSync(recursive: true);
    File(output).writeAsStringSync(text);
    stdout.writeln(
      jsonEncode({
        'status': 'passed',
        'fixtures': fixtures.length,
        'sourcePreserved': true,
      }),
    );
  }
}
