import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/generic_circuit_profile.dart';

Map<String, Object?> world(int width, int height, int x, int y, int mask) {
  final records = Uint8List(16);
  final data = ByteData.sublistView(records);
  data.setUint32(0, x, Endian.little);
  data.setUint32(4, y, Endian.little);
  data.setUint32(8, mask << 24, Endian.little);
  return {'width': width, 'height': height, 'records': records};
}

void main() {
  test('profile selects actual wire and clamps ROI at arbitrary world edges', () {
    final selection = GenericCircuitSelection.fromState(world(48, 36, 45, 35, 5));
    expect(selection.displayRegion, {'x': 16, 'y': 4, 'width': 32, 'height': 32});
    expect(selection.trigger, {'x': 45, 'y': 35, 'mask': 5, 'direct': true});
  });
  test('small worlds use their actual dimensions without computer defaults', () {
    final selection = GenericCircuitSelection.fromState(world(3, 2, 0, 0, 8));
    expect(selection.displayRegion, {'x': 0, 'y': 0, 'width': 3, 'height': 2});
  });
  test('missing or out-of-world wire cannot claim a measured trigger', () {
    for (final state in [world(3, 2, 0, 0, 0), world(3, 2, 3, 2, 1)]) {
      expect(() => GenericCircuitSelection.fromState(state), throwsStateError);
    }
  });
  test('malformed viewport records fail before selection', () {
    expect(() => GenericCircuitSelection.fromState({
      'width': 3, 'height': 2, 'records': Uint8List(15),
    }), throwsStateError);
  });
}
