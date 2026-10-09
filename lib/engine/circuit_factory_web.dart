import 'engine.dart';
import 'circuit_backend.dart';
import 'web_circuit_backend.dart';

CircuitBackend createCircuitBackend(TerraEngine engine) => WebCircuitBackend();
