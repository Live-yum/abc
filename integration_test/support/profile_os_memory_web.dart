class OsLoadingMemoryProbe {
  static Future<OsLoadingMemoryProbe> start() async => OsLoadingMemoryProbe();
  Future<void> begin(Map<String, Object?> metadata) async {}
  Future<void> end(
    String outcome, [
    Map<String, Object?> evidence = const {},
  ]) async {}
  Future<void> closePoint(Map<String, Object?> metadata) async {}
  Future<Map<String, Object?>> finish() async => {
    'schema': 'abc.profile-loading-os-memory.v1',
    'status': 'unavailable',
    'reason': 'Linux application process proc memory is unavailable on web',
    'windows': <Object>[],
    'closeSamples': <Object>[],
  };
}
