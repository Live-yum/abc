import 'engine.dart';
import 'circuit_backend.dart';

CircuitBackend? createCircuitBackend(TerraEngine engine) =>
    engine is CircuitBackend ? engine as CircuitBackend : null;
