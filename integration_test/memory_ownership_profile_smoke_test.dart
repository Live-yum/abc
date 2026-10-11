// Independent CI preflight process. Never import/run this in a measured arm.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kProfileMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/memory_ownership_gauges.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('profile image ownership hooks are active', (tester) async {
    expect(kProfileMode, isTrue);
    final observer = ImageOwnershipObserver()..install();
    try {
      final complete = Completer<ui.Image>();
      ui.decodeImageFromPixels(Uint8List(4), 1, 1,
          ui.PixelFormat.rgba8888, complete.complete);
      final image = await complete.future.timeout(const Duration(seconds: 10));
      final clone = image.clone();
      expect(observer.created, 2);
      clone.dispose();
      image.dispose();
      final row = observer.snapshot();
      expect(row['observedHandleBalance'], 0);
      expect(row['disposedHandles'], 2);
      expect(row['callbacksIntact'], isTrue);
      binding.reportData = {'schema': 'abc.memory-ownership-profile-smoke.v1',
        'status': 'passed', 'images': row};
    } finally {
      expect(observer.close()['restorationComplete'], isTrue);
    }
  });
}
