// Host-wrapper benchmark. This does not exercise Flutter frames or its UI.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

const sourceDigest =
    '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33';
const pongDigest =
    'd2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

List<List<int>> rows(Map result) {
  final bytes = result['records'] as Uint8List;
  require(bytes.length % 16 == 0, 'Partial physical record');
  final data = ByteData.sublistView(bytes);
  return [
    for (var offset = 0; offset < bytes.length; offset += 16)
      [
        for (var word = 0; word < 4; word++)
          data.getUint32(offset + word * 4, Endian.little),
      ],
  ];
}

String recordsHash(Map result) =>
    sha256.convert(result['records'] as Uint8List).toString();

class Probe {
  final NativeWorldCircuitBindings api;
  final int id;
  Uint8List previous = Uint8List(0);
  Probe(this.api, this.id);

  Future<Map> command(WorldCircuitCommand c) async =>
      await Future<Object?>.value(
        api.dispatch('worldCircuitCommand', [id, c.words, c.records]),
      ) as Map;

  Future<Map> display() =>
      command(WorldCircuitCommand.pixels(6485, 800, 64, 48));

  Future<bool> ready() async =>
      rows(await command(ComputerrariaComputer.ready())).single[2] == 1;

  Future<void> reset() async {
    for (var n = 0; !await ready() && n < 3; n++) {
      await command(ComputerrariaComputer.clock());
    }
    if (!await ready()) await command(ComputerrariaComputer.resetSignal());
    for (final c in ComputerrariaComputer.resetBus) {
      await command(c);
    }
  }

  Future<void> load(Uint8List bytes) async {
    await reset();
    for (final values in ComputerrariaComputer.programWrites(previous, bytes)) {
      await command(WorldCircuitCommand.lamps(values, write: true));
    }
    previous = bytes;
    await reset();
  }

  List<int> ramRecords(List<int> addresses, {bool write = false}) => [
    for (final address in addresses)
      for (var bit = 0; bit < 32; bit++)
        for (var mirror = 0; mirror < (write ? 2 : 1); mirror++) ...[
          ComputerrariaComputer.ramLamp(address, bit, mirror: mirror).$1,
          ComputerrariaComputer.ramLamp(address, bit, mirror: mirror).$2,
          0,
          0,
        ],
  ];

  Future<List<int>> signature(List<int> addresses) async {
    for (final c in ComputerrariaComputer.resetBus.take(2)) {
      await command(c);
    }
    final values = rows(
      await command(WorldCircuitCommand.lamps(ramRecords(addresses))),
    );
    return [
      for (var i = 0; i < addresses.length; i++)
        [for (var bit = 0; bit < 32; bit++) values[i * 32 + bit][2] << bit]
            .fold<int>(0, (a, b) => a | b),
    ];
  }

  Future<Map<String, Object?>> execute(
    Uint8List bytes,
    List<int> addresses,
  ) async {
    await load(bytes);
    await command(
      WorldCircuitCommand.lamps(
        ramRecords(addresses, write: true),
        write: true,
      ),
    );
    await reset();
    var clocks = 0;
    List<int> values = [];
    while (clocks < 4096) {
      await command(ComputerrariaComputer.clock(128));
      clocks += 128;
      for (var n = 0; !await ready() && n < 3; n++) {
        await command(ComputerrariaComputer.clock());
        clocks++;
      }
      require(await ready(), 'Physical CPU instruction boundary not reached');
      values = await signature(addresses);
      if (values.last == 0x600dc0de) break;
    }
    require(
      values.last == 0x600dc0de,
      'Physical CPU completion marker missing',
    );
    return {'signature': values, 'clocks': clocks};
  }

  Future<Map<String, Object?>> correctness(Map fixtures, Uint8List pong) async {
    final mode = await command(WorldCircuitCommand.optimization(true));
    require(
      (mode['reserved'] as int) & 14 == 14,
      'WireHead mode not available',
    );
    final initial = await display();
    require(
      rows(initial).length == 3072,
      'Actual screen must contain 3072 pixels',
    );
    Uint8List program(String name) {
      final hex = (fixtures[name] as Map)['hex'] as String;
      return Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    }

    final checks = (fixtures['main'] as Map)['checks'] as List;
    final addresses = [for (final c in checks) (c as Map)['address'] as int];
    final expected = [for (final c in checks) (c as Map)['expected'] as int];
    final cpu = await execute(program('main'), addresses);
    require(
      jsonEncode(cpu['signature']) == jsonEncode(expected),
      '48 physical CPU signatures mismatch',
    );
    final displayProgram = await execute(program('display'), [0x1000bc]);
    final mono = await display();
    final lit = rows(mono).where((r) => r[3] != 0).toList();
    require(
      lit.length == 2 &&
          lit[0][0] == 6485 &&
          lit[1][0] == 6516 &&
          lit.every((r) => r[1] == 800 && r[3] == 18),
      'Physical two-pixel display program mismatch',
    );
    final viewport = await command(
      WorldCircuitCommand.viewport(6485, 800, 64, 48),
    );
    require(
      recordsHash(viewport) == recordsHash(mono),
      'Physical query mismatch',
    );
    await execute(program('clear'), [0x1000bc]);
    await load(pong);
    final passive = ramRecords([
      for (var i = 0; i < 16; i++) 0x100000 + i * 4,
      for (var i = 0; i < 256; i++) 0x15bc00 + i * 4,
    ]);
    final frames = <Map<String, Object?>>[];
    final ramHashes = <String>{}, movingFrames = <String>{};
    for (var batch = 1; batch <= 12; batch++) {
      await command(ComputerrariaComputer.clock(128));
      final frame = await display();
      final frameHash = recordsHash(frame);
      final lit = rows(frame).where((r) => r[3] == 18).toList();
      if (lit.any((r) => r[0] - 6485 > 1 && r[0] - 6485 < 62)) {
        movingFrames.add(frameHash);
      }
      final ramHash = recordsHash(
        await command(WorldCircuitCommand.lamps(passive)),
      );
      ramHashes.add(ramHash);
      frames.add({
        'clocks': batch * 128,
        'displaySha256': frameHash,
        'litCount': lit.length,
        'ramSha256': ramHash,
        'ready': await ready(),
      });
    }
    require(ramHashes.length > 1, 'Pong physical RAM/stack did not change');
    require(movingFrames.length >= 3, 'Pong physical display did not move');
    return {
      'sourceSha256': sourceDigest,
      'modeFlags': mode['reserved'],
      'initialDisplaySha256': recordsHash(initial),
      'cpu': cpu,
      'displayProgram': displayProgram,
      'displaySha256': recordsHash(mono),
      'pongSha256': sha256.convert(pong).toString(),
      'pongFrames': frames,
      'finalStats': (await display())['stats'],
    };
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 6) {
    throw ArgumentError('library world pong programs report variant');
  }
  final wall = Stopwatch()..start();
  final reportFile = File(args[4]);
  final source = File(args[1]), before = File(args[1]).statSync();
  require(before.size == 405983441, 'Public WLD size mismatch');
  final pong = File(args[2]).readAsBytesSync();
  require(
    pong.length == 2288 && sha256.convert(pong).toString() == pongDigest,
    'Original Pong identity mismatch',
  );
  final fixtures = jsonDecode(File(args[3]).readAsStringSync()) as Map;
  final library = DynamicLibrary.open(args[0]);
  final api = NativeWorldCircuitBindings(library);
  final liveBytes = library.providesSymbol('abc_perf_native_live_bytes')
      ? library.lookupFunction<Uint32 Function(), int Function()>(
          'abc_perf_native_live_bytes',
        )
      : null;
  final report = <String, Object?>{
    'schema': 1,
    'status': 'running',
    'scope': 'pure-Dart AOT host wrapper, not Flutter UI/frame evidence',
    'variant': args[5],
    'pid': pid,
    'dartVersion': Platform.version,
    'quietMilliseconds': 1200,
    'cycles': <Map<String, Object?>>[],
    'phaseTimingMethod':
        '20ms owner-timer observations of existing progress; '
        'approximate wall intervals, total open duration measured directly',
    'coldDefinition':
        'first open in fresh process; OS page cache is not flushed',
    'nativeCounterAvailable': liveBytes != null,
  };
  void persist() => reportFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  final acknowledgments = StreamIterator<String>(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  Future<void> event(String phase, int cycle) async {
    stdout.writeln(
      jsonEncode({
        'event': 'boundary',
        'phase': phase,
        'cycle': cycle,
        'elapsedUs': wall.elapsedMicroseconds,
        'currentRssBytes': ProcessInfo.currentRss,
        'maxRssBytes': ProcessInfo.maxRss,
        'nativeLiveBytes': liveBytes?.call(),
      }),
    );
    await stdout.flush();
    require(
      await acknowledgments.moveNext() && acknowledgments.current == 'ack',
      'External boundary sampler did not acknowledge',
    );
  }

  Map<String, Object?> sourceMap() => {
    'path': source.path,
    'length': before.size,
    'name': 'computerraria.wld',
  };
  Future<Map> open() async => await Future<Object?>.value(
    api.dispatch('worldCircuitOpenSource', [sourceMap()]),
  ) as Map;
  void checkOriginalStat() {
    final after = source.statSync();
    require(
      after.size == before.size &&
          after.modified == before.modified &&
          after.type == before.type,
      'Original WLD stat changed',
    );
  }

  void checkClosed() {
    require(
      liveBytes == null || liveBytes() == 0,
      'Tracked native allocations remain after close',
    );
    require(
      Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.split('/').last.startsWith('abc-circuit-'))
          .isEmpty,
      'Session scratch directory remains after close',
    );
    checkOriginalStat();
  }

  void closeAndRejectHandle(int closedId) {
    api.dispatch('worldCircuitClose', [closedId]);
    var rejected = false;
    final query = ComputerrariaComputer.ready();
    try {
      api.dispatch('worldCircuitCommand', [
        closedId,
        query.words,
        query.records,
      ]);
    } catch (error) {
      rejected = error.toString().contains('session is closed');
    }
    require(rejected, 'Closed wrapper handle was not rejected');
  }

  int id = 0;
  try {
    await event('processReady', 0);
    for (var cycle = 1; cycle <= 8; cycle++) {
      final timings = <String, Object?>{};
      final transitions = <Map<String, Object?>>[];
      final timer = Stopwatch();
      String? lastStage;
      void observe() {
        final progress = api.dispatch('worldCircuitProgress', []);
        if (progress is! Map ||
            !['hash', 'decode', 'compile'].contains(progress['stage']))
          return;
        final stage = progress['stage'] as String;
        if (stage != lastStage) {
          transitions.add({
            'stage': stage,
            'elapsedUs': timer.elapsedMicroseconds,
            'progress': Map<String, Object?>.from(progress),
          });
          lastStage = stage;
        }
      }

      await event('beforeOpen', cycle);
      timer.start();
      final monitor = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => observe(),
      );
      late Map opened;
      try {
        opened = await open();
        id = opened['session'] as int;
        observe();
      } finally {
        monitor.cancel();
      }
      timings['openMicroseconds'] = timer.elapsedMicroseconds;
      timings['progressTransitions'] = transitions;
      for (var i = 0; i < transitions.length; i++) {
        final end = i + 1 < transitions.length
            ? transitions[i + 1]['elapsedUs'] as int
            : timer.elapsedMicroseconds;
        timings['${transitions[i]['stage']}ObservedMicroseconds'] =
            end - (transitions[i]['elapsedUs'] as int);
      }
      final stats = (opened['stats'] as List).cast<int>();
      require(
        opened['sourceSha256'] == sourceDigest,
        'World source SHA mismatch',
      );
      require(
        stats[0] == 2 &&
            stats[2] == 15200 &&
            stats[3] == 7200 &&
            stats[10] == 72939714 &&
            stats[12] == 13641575,
        'Complete public world graph mismatch',
      );
      require(
        (opened['reserved'] as int) & 3 == 0,
        'WLD default mode mismatch',
      );
      final cycleReport = <String, Object?>{
        'cycle': cycle,
        'temperature': cycle == 1 ? 'process-cold' : 'warm',
        'timings': timings,
        'sourceSha256': opened['sourceSha256'],
        'openStats': stats,
        'openFlags': opened['reserved'],
        'openProgress': api.dispatch('worldCircuitProgress', []),
      };
      (report['cycles'] as List).add(cycleReport);
      await event('opened', cycle);
      final correctnessTime = Stopwatch()..start();
      cycleReport['correctness'] = await Probe(
        api,
        id,
      ).correctness(fixtures, pong);
      timings['correctnessMicroseconds'] = correctnessTime.elapsedMicroseconds;
      await event('beforeClose', cycle);
      final close = Stopwatch()..start();
      closeAndRejectHandle(id);
      id = 0;
      timings['closeMicroseconds'] = close.elapsedMicroseconds;
      cycleReport['closedHandleRejected'] = true;
      checkClosed();
      await event('closed', cycle);
      final quiet = Stopwatch()..start();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      timings['actualQuietMicroseconds'] = quiet.elapsedMicroseconds;
      await event('closedQuiet', cycle);
      cycleReport['closedNativeLiveBytes'] = liveBytes?.call();
      persist();
    }
    // Separate from the eight performance cycles. The first hash chunk yields;
    // cancel then confirms cleanup, and a full reopen confirms recovery.
    await event('cancellationStart', 9);
    final pending = open();
    api.dispatch('worldCircuitCancelOperation', []);
    String? cancelError;
    try {
      final unexpected = await pending;
      id = unexpected['session'] as int;
    } catch (error) {
      cancelError = error.toString();
    }
    require(
      cancelError != null && cancelError.contains('cancelled'),
      'Hash cancellation did not reject as expected',
    );
    checkClosed();
    await event('cancelled', 9);
    final reopened = await open();
    id = reopened['session'] as int;
    require(
      reopened['sourceSha256'] == sourceDigest,
      'Cancellation recovery SHA',
    );
    final recovery = await Probe(api, id).display();
    require(
      rows(recovery).length == 3072,
      'Cancellation recovery physical query',
    );
    report['cancellation'] = {
      'scope':
          'first source-hash yield, then full reopen and physical query; '
          'not decode/compile cancellation or allocator-failure coverage',
      'error': cancelError,
      'reopenedSourceSha256': reopened['sourceSha256'],
      'reopenedStats': reopened['stats'],
      'displaySha256': recordsHash(recovery),
    };
    closeAndRejectHandle(id);
    id = 0;
    checkClosed();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await event('recoveryClosedQuiet', 9);
    report['status'] = 'passed';
  } catch (error, stack) {
    report['status'] = 'failed';
    report['error'] = error.toString();
    report['stack'] = stack.toString();
    exitCode = 1;
  } finally {
    if (id != 0) {
      try {
        api.dispatch('worldCircuitClose', [id]);
      } catch (error) {
        report['cleanupError'] = error.toString();
        report['status'] = 'failed';
        exitCode = 1;
      }
    }
    report['elapsedMicroseconds'] = wall.elapsedMicroseconds;
    report['nativeLiveBytesAfterClose'] = liveBytes?.call();
    report['originalStatUnchanged'] =
        source.statSync().size == before.size &&
        source.statSync().modified == before.modified;
    persist();
    await event('processComplete', 9);
    await acknowledgments.cancel();
  }
}
