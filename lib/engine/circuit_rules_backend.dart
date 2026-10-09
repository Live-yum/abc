/// Authoritative circuit domain/editor host. Only JSON values cross this
/// boundary; source code is bundled from the attributed, pinned source subset.
abstract interface class CircuitRulesBackend {
  Future<Object?> invokeCircuitRules(String method, List<Object?> args);
}
