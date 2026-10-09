import 'engine.dart';
import 'world_circuit_backend.dart';
import 'web_world_circuit_backend.dart';

WorldCircuitBackend createWorldCircuitBackend(TerraEngine engine) =>
    WebWorldCircuitBackend();
