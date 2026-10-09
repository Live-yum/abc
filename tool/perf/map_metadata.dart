import 'dart:io';

import 'package:crypto/crypto.dart';

String? _command(String program, List<String> args) {
  try {
    final result = Process.runSync(program, args);
    return result.exitCode == 0 ? (result.stdout as String).trim() : null;
  } catch (_) {
    return null;
  }
}

Map<String, Object?> mapReportMetadata() {
  final commit = _command('git', ['rev-parse', 'HEAD']);
  final status = _command('git', [
    'status',
    '--porcelain',
    '--untracked-files=normal',
  ]);
  final explicit = Platform.environment['ABC_PERF_COMMIT'],
      github = Platform.environment['GITHUB_SHA'];
  final executable = File(Platform.resolvedExecutable),
      worker = File('web/engine/map_worker.js');
  return {
    'source': {
      'commit': explicit ?? github ?? commit ?? 'unknown',
      'worktreeCommit': commit ?? 'unknown',
      'dirty': status == null ? 'unknown' : status.isNotEmpty,
      'commitSource': explicit != null
          ? 'ABC_PERF_COMMIT'
          : github != null
          ? 'GITHUB_SHA'
          : commit != null
          ? 'git'
          : 'unknown',
    },
    'toolchain': {
      'dart': Platform.version,
      'operatingSystem': Platform.operatingSystem,
      'flutterPinned': File('.flutter-version').existsSync()
          ? File('.flutter-version').readAsStringSync().trim()
          : 'unknown',
      'artifacts': [
        {
          'id': 'executing-binary',
          'bytes': executable.lengthSync(),
          'sha256': sha256.convert(executable.readAsBytesSync()).toString(),
        },
        if (worker.existsSync())
          {
            'id': 'map-worker',
            'bytes': worker.lengthSync(),
            'sha256': sha256.convert(worker.readAsBytesSync()).toString(),
          },
      ],
    },
  };
}
