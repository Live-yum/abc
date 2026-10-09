import 'dart:convert';
import 'dart:js_interop';

import 'map_fixture.dart';
import 'map_perf_core.dart';

@JS('mapPerfInput')
external JSString get _input;
@JS('mapPerfOutput')
external set _output(JSString value);
@JS('mapPerfMemory')
external JSString _memory();

void main() {
  final options = jsonDecode(_input.toDart) as Map<String, dynamic>;
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
    if (options['base64'] != null)
      MapPerfFixture(
        'local-map-1',
        options['provenance'] as String? ?? 'authorized-local-input',
        base64Decode(options['base64'] as String),
      ),
  ];
  _output = jsonEncode(
    benchmarkMaps(
      fixtures,
      iterations: options['iterations'] as int? ?? 10,
      runtime: 'dart2js-node',
      tier: options['tier'] as String? ?? 'local',
      buildMode: 'dart2js-O2',
      memorySnapshot: () =>
          Map<String, Object?>.from(jsonDecode(_memory().toDart) as Map),
    ),
  ).toJS;
}
