import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/memory_ownership_retention.dart';

void main() {
  final helper = Platform.environment['ABC_OWNER_LIBC_HELPER'];
  test('fixed libc slots preserve every call and reject a 53rd capture', () {
    final probe = OwnershipRetentionProbe.open(helper!);
    final initialization = probe.initialization;
    try {
      expect(probe.captureCount, 0);
      expect(initialization['startUs'], isA<int>());
      expect(
        initialization['endUs'],
        greaterThanOrEqualTo(initialization['startUs'] as int),
      );
      expect(initialization['statusCode'], inInclusiveRange(0, 4));
      expect(initialization['clockDomain'], 'dart:developer.Timeline.now');
      for (var i = 0; i < 52; i++) {
        expect(probe.capture(), i);
      }
      expect(probe.captureCount, 52);
      expect(probe.capture, throwsStateError);
      for (var i = 0; i < 52; i++) {
        final raw = probe.rawCapture(i), row = probe.describe(i);
        expect(raw['sequence'], i);
        expect(row['sequence'], i);
        expect(raw['startUs'], row['startUs']);
        expect(raw['endUs'], row['endUs']);
        expect(
          raw['startUs'],
          greaterThanOrEqualTo(initialization['endUs'] as int),
        );
        expect(raw['statusCode'], initialization['statusCode']);
        expect(row['status'], initialization['status']);
        expect(row['reason'], initialization['reason']);
        expect(raw['rawWordEncoding'], 'unsigned-decimal-string');
        final words = (raw['rawWords'] as List).cast<String>();
        expect(words.length, 16);
        expect(words[0], '1');
        expect(words[1], '${raw['statusCode']}');
        final fields = row['fields'] as Map;
        if (row['status'] == 'available') {
          expect(
            fields.values.every((value) => value is int && value >= 0),
            isTrue,
          );
        } else {
          expect(fields.values.every((value) => value == null), isTrue);
          expect(
            words.skip(6).every((word) => word == '18446744073709551615'),
            isTrue,
          );
        }
      }
    } finally {
      probe.close();
    }
    expect(probe.capture, throwsStateError);
    expect(() => probe.describe(0), throwsStateError);
    expect(probe.initialization, initialization);
    probe.close();
  }, skip: !Platform.isLinux || helper == null);
}
