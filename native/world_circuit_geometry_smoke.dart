import 'dart:io';

import 'package:terraforge/domain/world_circuit_geometry.dart';
import 'package:terraforge/platform/resource_store.dart';

void main(List<String> args) {
  final pack = ResourceStore.importPack(File(args.single).readAsBytesSync());
  final geometry = WorldCircuitGeometry.fromCatalog(
    pack.catalog,
    worldVersion: 326,
  );
  if (geometry.records.isEmpty || geometry.records.length > 65536 * 4) {
    throw StateError('Invalid bounded geometry index');
  }
  stdout.writeln(
    'PASS: ${pack.catalog.families['tile-object-data']!.length} local placement rows; '
    '${geometry.records.length ~/ 4} exact cell frames; '
    '${geometry.ambiguousFrameCount} ambiguous frames omitted; '
    '${geometry.unverifiedSupportFrameCount} support-unverified frames remain blocked',
  );
}
