import 'dart:io';

import 'package:terraforge/domain/circuit_document.dart';
import 'package:terraforge/engine/circuit_backend.dart';
import 'package:terraforge/engine/native_engine.dart';

Future<void> main() async {
  final d = CircuitDocument(width: 8, height: 8);
  for (var x = 1; x <= 5; x++) {
    d.paintWire(x, 2, 0);
  }
  d.placeElement(1, 2, CircuitElement.switchInput);
  d.placeElement(5, 2, CircuitElement.lamp);
  d.placeElement(5, 5, CircuitElement.lamp);
  final engine = createTerraEngine();
  final s = CircuitSimulator(d, engine as CircuitBackend);
  await s.trigger(1, 2);
  if (!s.isOn(5, 2) || s.isOn(5, 5) || s.trace.length != 5) {
    throw StateError('Native circuit connectivity failure');
  }
  await s.trigger(1, 2);
  if (s.isOn(5, 2)) throw StateError('Native circuit parity failure');
  d.paintWire(3, 2, 0, erase: true);
  await s.trigger(1, 2);
  if (s.isOn(5, 2) || s.trace.length != 2) {
    throw StateError('Native disconnected circuit failure');
  }
  stdout.writeln(
    'Native TerraCircuit traversal + host lamp parity + disconnect passed',
  );
  exit(0);
}
