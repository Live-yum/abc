import 'dart:io';

String fixture(List<String> args) => args.single;
Map<String, Object?> memory() => {
  'rssBytes': ProcessInfo.currentRss,
  'heapUsedBytes': null,
  'externalBytes': null,
  'arrayBufferBytes': null,
};
