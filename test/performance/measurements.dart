import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// Integration timing only. Flutter frame timing belongs in a profile app.
class Measurements {
  final String runId = '${DateTime.now().microsecondsSinceEpoch}-$pid';
  File? _journal;
  Map<String, Object?> Function()? nativeMemory;
  final String tier = Platform.environment['ABC_PERF_TIER'] ?? 'ci';
  late final int cycles = int.parse(
    Platform.environment['ABC_PERF_CYCLES'] ??
        {'ci': '25', 'local': '10', 'soak': '50'}[tier]!,
  );
  final int warmup = int.parse(Platform.environment['ABC_PERF_WARMUP'] ?? '5');
  int cycle = -1;
  final owners = <String>{};
  final rows = <String, Map<String, Object?>>{};
  late final Map<String, Object?> report = {
    'schema': 'abc.performance.v1',
    'runId': runId,
    'suite': 'native-actions',
    'runtime': 'dart-${Platform.version.split(' ').first}',
    'buildMode': 'flutter-test-debug-with-release-native-library',
    'tier': tier,
    'source': _sourceRevision(),
    'toolchain': _toolchain(),
    'machine': {
      'platform': Platform.operatingSystem,
      'osImage': _osImage(),
      'kernel': Platform.operatingSystemVersion,
      'arch': Platform.version.contains('arm64') ? 'arm64' : 'x64',
      'logicalCpus': Platform.numberOfProcessors,
      'cpuModel': _cpuModel(),
    },
    'methodology': {
      'clock': 'Stopwatch',
      'cold': 'First complete workload cycle in this process; an operation can repeat within that cycle. Codec bootstrap may already occur during fixture preparation. OS file cache is not flushed.',
      'warmupCycles': warmup,
      'measuredCycles': cycles,
      'timing': 'Awaited real Native/Workspace operation latency; not frame smoothness',
      'bookkeeping': 'Raw samples/report metadata are retained in this process and contribute to Dart heap/RSS. Compare equal cycle counts; optional core live-payload counters are separate from host bookkeeping.',
      'memory': 'RSS is process-wide and includes Flutter test VM, native heap and allocator capacity. Dart live heap/native live allocation bytes are unavailable. Owned handles track explicitly opened document and circuit owners; hidden runtime allocations are not inferred from this number.',
    },
    'fixtures': <Map<String, Object?>>[],
    'operations': <Map<String, Object?>>[],
    'memory': <Map<String, Object?>>[],
    'gaps': <String>[],
    'status': 'running',
  };

  void journal(String output) {
    _journal = File('$output.events.jsonl');
    _journal!.parent.createSync(recursive: true);
    _event({
      'event': 'run-start',
      'tier': tier,
      'cycles': cycles,
      'warmup': warmup,
    });
  }

  void _event(Map<String, Object?> event) {
    _journal?.writeAsStringSync(
      '${jsonEncode({'runId': runId, ...event})}\n',
      mode: FileMode.append,
    );
  }

  static String? _cpuModel() {
    if (Platform.isMacOS) {
      return _command('sysctl', ['-n', 'machdep.cpu.brand_string']);
    }
    if (!Platform.isLinux) return Platform.environment['PROCESSOR_IDENTIFIER'];
    final match = RegExp(
      r'^model name\s*:\s*(.+)$',
      multiLine: true,
    ).firstMatch(File('/proc/cpuinfo').readAsStringSync());
    return match?.group(1);
  }

  static String _osImage() {
    final configured =
        Platform.environment['ABC_PERF_OS_IMAGE'] ??
        Platform.environment['ImageOS'];
    if (configured != null) return configured;
    try {
      return RegExp(
            r'^PRETTY_NAME="?(.+?)"?$',
            multiLine: true,
          ).firstMatch(File('/etc/os-release').readAsStringSync())?.group(1) ??
          'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  void fixture(
    String id,
    String kind,
    int bytes, {
    bool private = false,
    String? sha256,
  }) {
    if (private && tier == 'ci') {
      throw StateError('Private fixtures require local or soak tier');
    }
    (report['fixtures'] as List).add(<String, Object?>{
      'id': id,
      'kind': kind,
      'bytes': bytes,
      'sha256': sha256,
      'provenance': private ? 'user-provided-local-only' : 'original-synthetic',
    });
  }

  Future<T> measure<T>(
    String id,
    String fixture,
    int bytes,
    Future<T> Function() action,
  ) async {
    report['lastOperation'] = {'id': id, 'fixture': fixture, 'cycle': cycle};
    _event({
      'event': 'begin',
      'id': id,
      'fixture': fixture,
      'cycle': cycle,
      'rssBytes': ProcessInfo.currentRss,
    });
    final watch = Stopwatch()..start();
    late T result;
    try {
      result = await action();
    } catch (error) {
      report['failure'] = {
        'operation': id,
        'fixture': fixture,
        'cycle': cycle,
        'errorType': error.runtimeType.toString(),
      };
      rethrow;
    } finally {
      watch.stop();
    }
    _event({
      'event': 'end',
      'id': id,
      'fixture': fixture,
      'cycle': cycle,
      'durationMs': watch.elapsedMicroseconds / 1000,
      'rssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
    });
    if (cycle >= 0 && cycle < warmup) return result;
    final phase = cycle == -1 ? 'cold' : 'warm';
    final row = rows.putIfAbsent(
      '$id/$fixture/$phase',
      () => {
        'id': id,
        'fixture': fixture,
        'phase': phase,
        'unit': 'ms',
        'warmup': phase == 'cold' ? 0 : warmup,
        'bytesPerOperation': bytes,
        'samplesMs': <double>[],
      },
    );
    (row['samplesMs'] as List<double>).add(watch.elapsedMicroseconds / 1000);
    return result;
  }

  void memory(String phase, [Map<String, Object?> diagnostic = const {}]) {
    (report['memory'] as List).add({
      'cycle': cycle,
      'phase': phase,
      'rssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
      'heapUsedBytes': null,
      'heapCapacityBytes': null,
      'wasmCapacityBytes': null,
      ...diagnostic,
      'ownedHandles': owners.length,
      ...?nativeMemory?.call(),
    });
  }

  Future<void> write(String path, String status) async {
    report['status'] = status;
    report['operations'] = rows.values.map((row) {
      final samples = row['samplesMs'] as List<double>;
      final sorted = [...samples]..sort();
      final n = sorted.length;
      return {
        ...row,
        'iterations': n,
        'medianMs': n.isOdd
            ? sorted[n ~/ 2]
            : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2,
        'p95Ms': sorted[(n * .95).ceil() - 1],
        'maxMs': sorted.last,
        'throughputPerSecond': samples.reduce((a, b) => a + b) > 0
            ? 1000 * n / samples.reduce((a, b) => a + b)
            : null,
      };
    }).toList();
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    if (status != 'running') _event({'event': 'run-end', 'status': status});
  }

  static String? _command(String executable, List<String> args) {
    try {
      final result = Process.runSync(executable, args);
      return result.exitCode == 0 ? (result.stdout as String).trim() : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?> _sourceRevision() {
    final commit = _command('git', ['rev-parse', 'HEAD']);
    final status = _command('git', [
      'status',
      '--porcelain',
      '--untracked-files=normal',
    ]);
    return {
      'commit':
          Platform.environment['ABC_PERF_COMMIT'] ??
          Platform.environment['GITHUB_SHA'] ??
          commit ??
          'unknown',
      'worktreeCommit': commit ?? 'unknown',
      'dirty': status == null ? 'unknown' : status.isNotEmpty,
      'commitSource': Platform.environment.containsKey('ABC_PERF_COMMIT')
          ? 'ABC_PERF_COMMIT'
          : Platform.environment.containsKey('GITHUB_SHA')
          ? 'GITHUB_SHA'
          : commit != null
          ? 'git'
          : 'unknown',
    };
  }

  static String _flutterVersion() {
    try {
      final config = File('.dart_tool/package_config.json');
      final packages =
          jsonDecode(config.readAsStringSync())['packages'] as List;
      final root = config.absolute.uri.resolve(
        packages.firstWhere((p) => p['name'] == 'flutter')['rootUri'] as String,
      );
      final folder = Uri.parse(
        '${root.toString().replaceFirst(RegExp(r"/+$"), "")}/',
      );
      final file = File.fromUri(
        folder.resolve('../../bin/cache/flutter.version.json'),
      );
      return jsonDecode(file.readAsStringSync())['frameworkVersion'] as String;
    } catch (_) {
      return Platform.environment['ABC_PERF_FLUTTER_VERSION'] ?? 'unknown';
    }
  }

  static Map<String, Object?> _toolchain() {
    final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
    return {
      'dart': Platform.version,
      'flutter': _flutterVersion(),
      'flutterPinned': File('.flutter-version').existsSync()
          ? File('.flutter-version').readAsStringSync().trim()
          : 'unknown',
      'hostCompiler':
          _command('cc', ['--version'])?.split('\n').first ?? 'unknown',
      'nativeBuildCompiler':
          Platform.environment['ABC_PERF_NATIVE_COMPILER'] ?? 'unknown',
      'nativeLibrarySha256': library != null && File(library).existsSync()
          ? crypto.sha256.convert(File(library).readAsBytesSync()).toString()
          : null,
    };
  }
}
