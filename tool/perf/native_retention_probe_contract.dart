// Tiny native/FFI contract only. Does not import Flutter or open a world.
import 'dart:convert';
import 'dart:io';

import '../../integration_test/support/native_retention_probe.dart';

void main(List<String> arguments) {
  if (arguments.length != 3) {
    throw ArgumentError('HELPER EXPECTED_STATUS NEW_JOURNAL');
  }
  final journal = File(arguments[2]);
  final observer = NativeRetentionProbe.open(arguments[0], journal: journal);
  try {
    final first = observer.sample();
    if (journal.readAsLinesSync().length != 1) {
      throw StateError('Completed call was not persisted before return');
    }
    final second = observer.sample();
    for (final value in [first, second]) {
      if (value['status'] != arguments[1] ||
          value['atomic'] != false ||
          (value['startUs'] as int) > (value['endUs'] as int)) {
        throw StateError('Invalid probe metadata');
      }
      final fields = value['fields'] as Map;
      if (fields.keys.join(',') != retentionMallinfoFields.join(',')) {
        throw StateError('Missing or reordered mallinfo2 fields');
      }
      if (arguments[1] == 'unsupported') {
        if (fields.values.any((value) => value != null)) {
          throw StateError('Unsupported measurements must remain null');
        }
      } else if (fields.values.any((value) => value is! int || value < 0)) {
        throw StateError('Available measurements must be unsigned integers');
      }
    }
    if (first['sequence'] != 0 || second['sequence'] != 1) {
      throw StateError('Call sequence changed');
    }
    final rows = journal.readAsLinesSync().map(jsonDecode).toList();
    if (jsonEncode(rows) != jsonEncode(observer.observations)) {
      throw StateError('Raw call journal differs from reported calls');
    }
    observer.close();
    observer.close();
    var rejected = false;
    try {
      observer.sample();
    } on StateError {
      rejected = true;
    }
    if (!rejected) throw StateError('Closed buffer remained callable');
    // ignore: avoid_print
    print(
      jsonEncode({
        'status': 'contract-passed',
        'samples': [first, second],
      }),
    );
  } finally {
    observer.close();
  }
}
