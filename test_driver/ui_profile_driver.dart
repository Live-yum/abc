import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 45),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final path =
        Platform.environment['TERRA_UI_PROFILE_OUTPUT'] ??
        'build/perf/ui-profile.json';
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  },
);
