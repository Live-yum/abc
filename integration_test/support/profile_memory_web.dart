Map<String, Object?> runtimeMetadata() => {
  'platform': 'web',
  'memorySource': 'unavailable: requires browser-specific profiling',
};

Future<Map<String, Object?>> memorySnapshot() async => {
  'rssBytes': null,
  'heapUsedBytes': null,
  'heapCapacityBytes': null,
  'externalBytes': null,
  'gc': 'unavailable',
};

Future<void> closeMemoryProbe() async {}

Map<String, Object?> runtimeOverrides() => {};
int? currentRss() => null;

Future<void> writeStandaloneReport(Map<String, dynamic> report) async {}
