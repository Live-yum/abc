import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 2),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final path = Platform.environment['ABC_PAINTER_OUTPUT'];
    if (path == null || path.isEmpty) {
      throw StateError('An explicit new painter report path is required.');
    }
    final file = File(path);
    if (await file.exists()) throw StateError('Painter report already exists.');
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  },
);
