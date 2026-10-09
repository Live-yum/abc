import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/computer_display.dart';

void main() {
  testWidgets(
    'continuous newer frames publish completed image and coalesce pending',
    (tester) async {
      final pending = <void Function(ui.Image)>[];
      final inputs = <Uint8List>[];
      void decode(
        Uint8List bytes,
        int width,
        int height,
        void Function(ui.Image) complete,
      ) {
        inputs.add(bytes);
        pending.add(complete);
      }

      Future<void> show(int value, {String label = 'mono', int width = 1}) =>
          tester.pumpWidget(
            MaterialApp(
              home: ComputerDisplay(
                rgba: Uint8List(width * 4)..[0] = value,
                width: width,
                height: 1,
                label: label,
                decodePixels: decode,
              ),
            ),
          );
      await show(1);
      await show(2);
      await show(3);
      expect(pending.length, 1, reason: 'Only one decode may be in flight');
      final first = await tester.runAsync(
        () => createTestImage(width: 1, height: 1, cache: false),
      );
      pending.removeAt(0)(first!);
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(first));
      expect(inputs.map((bytes) => bytes[0]), [1, 3]);
      expect(pending.length, 1);
      await show(4);
      final second = await tester.runAsync(
        () => createTestImage(width: 1, height: 1, cache: false),
      );
      pending.removeAt(0)(second!);
      await tester.pump();
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        same(second),
      );
      expect(inputs.map((bytes) => bytes[0]), [1, 3, 4]);
      expect(first.debugDisposed, isTrue);
      await tester.pumpWidget(const SizedBox());
      final last = await tester.runAsync(
        () => createTestImage(width: 1, height: 1, cache: false),
      );
      pending.removeAt(0)(last!);
      expect(last.debugDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'monitor changes cannot publish a previous monitor even after switch back',
    (tester) async {
      final pending = <void Function(ui.Image)>[];
      void decode(
        Uint8List bytes,
        int width,
        int height,
        void Function(ui.Image) complete,
      ) => pending.add(complete);
      Future<void> show(String label, int width) => tester.pumpWidget(
        MaterialApp(
          home: ComputerDisplay(
            rgba: Uint8List(width * 4),
            width: width,
            height: 1,
            label: label,
            decodePixels: decode,
          ),
        ),
      );
      await show('mono', 1);
      await show('color', 2);
      await show('mono', 1);
      final obsolete = await tester.runAsync(
        () => createTestImage(width: 1, height: 1, cache: false),
      );
      pending.removeAt(0)(obsolete!);
      await tester.pump();
      expect(obsolete.debugDisposed, isTrue);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
      expect(pending.length, 1);
      final fresh = await tester.runAsync(
        () => createTestImage(width: 1, height: 1, cache: false),
      );
      pending.removeAt(0)(fresh!);
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(fresh));
    },
  );
  testWidgets(
    'reopened session cannot receive a pending image from closed owner',
    (tester) async {
      final pending = <void Function(ui.Image)>[];
      void decode(
        Uint8List bytes,
        int width,
        int height,
        void Function(ui.Image) complete,
      ) => pending.add(complete);
      Future<void> show(Object identity) => tester.pumpWidget(
        MaterialApp(
          home: ComputerDisplay(
            key: ObjectKey(identity),
            rgba: Uint8List(4),
            width: 1,
            height: 1,
            label: 'mono',
            decodePixels: decode,
          ),
        ),
      );
      await show(Object());
      await show(Object());
      expect(pending.length, 2);
      final oldImage = await tester.runAsync(
        () => createTestImage(cache: false),
      );
      pending.removeAt(0)(oldImage!);
      await tester.pump();
      expect(oldImage.debugDisposed, isTrue);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
      final fresh = await tester.runAsync(() => createTestImage(cache: false));
      pending.removeAt(0)(fresh!);
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(fresh));
    },
  );
}
