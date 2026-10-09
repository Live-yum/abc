import 'engine.dart';
import 'world_circuit_backend.dart';

WorldCircuitBackend? createWorldCircuitBackend(TerraEngine engine) =>
    engine is WorldCircuitBackend ? engine as WorldCircuitBackend : null;
