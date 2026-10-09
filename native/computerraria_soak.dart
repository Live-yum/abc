// Opt-in repeated complete-world ownership and execution proof. Results are
// journaled one cycle at a time; frame buffers never accumulate in the harness.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

Future<void> main(List<String> args) async {
  if (args.length != 5) {
    throw ArgumentError('library WLD TWLD cycles journal.jsonl');
  }
  final cycles = int.parse(args[3]);
  if (cycles < 1 || cycles > 200) throw ArgumentError('cycles must be 1..200');
  final library = DynamicLibrary.open(args[0]),
      api = NativeWorldCircuitBindings(DynamicLibrary.open(args[0]));
  int nativeBytes() =>
      library.lookupFunction<Uint32 Function(), int Function()>(
        'abc_perf_native_live_bytes',
      )();
  int bridgeBytes() =>
      library.lookupFunction<Uint32 Function(), int Function()>(
        'abc_perf_bridge_live_bytes',
      )();
  int worlds() => library.lookupFunction<Uint32 Function(), int Function()>(
    'abc_perf_world_open_count',
  )();
  int? descriptors() =>
      Platform.isLinux ? Directory('/proc/self/fd').listSync().length : null;
  final journalFile = File(args[4]);
  journalFile.parent.createSync(recursive: true);
  final journal = journalFile.openSync(mode: FileMode.write);
  void record(Map<String, Object?> entry) {
    journal.writeStringSync('${jsonEncode(entry)}\n');
    journal.flushSync();
  }

  void require(bool value, String message) {
    if (!value) throw StateError(message);
  }

  Map<String, Object?> source(String path) => {
    'path': path,
    'length': File(path).lengthSync(),
    'name': path.split('/').last,
  };
  final data = jsonDecode(
    File('native/fixtures/computerraria/programs.json').readAsStringSync(),
  ) as Map;
  final text = (data['main'] as Map)['hex'] as String;
  final program = Uint8List.fromList([
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ]);
  final checks = ((data['main'] as Map)['checks'] as List).cast<Map>();
  final reads = <int>[];
  for (final check in checks) {
    for (var bit = 0; bit < 32; bit++) {
      final (x, y) = ComputerrariaComputer.ramLamp(
        check['address'] as int,
        bit,
      );
      reads.addAll([x, y, 0, 0]);
    }
  }
  final expected = checks.map((v) => v['expected'] as int).toList();
  final pong = File('assets/computer/pong.bin').readAsBytesSync();
  final sidecarHash = (await sha256.bind(File(args[2]).openRead()).first)
      .toString();
  require(
    sidecarHash ==
        'c6de694b3d034701513dc1ba17311213561ec359d3ecddde7bc35ea3c9611ed8',
    'Wrong original TWLD',
  );
  final baselineFd = descriptors(), started = DateTime.now().toUtc();
  final rssAfter = <int>[];
  record({
    'event': 'start',
    'cycles': cycles,
    'startedAt': started.toIso8601String(),
    'librarySha256': sha256.convert(File(args[0]).readAsBytesSync()).toString(),
    'worldBytes': File(args[1]).lengthSync(),
    'twldSha256': sidecarHash,
    'baselineFd': baselineFd,
    'rss': ProcessInfo.currentRss,
    'temporaryDirectory': Directory.systemTemp.path,
  });
  var passed = 0;
  String? baselineFrame;
  try {
    for (var cycle = 0; cycle < cycles; cycle++) {
      final elapsed = Stopwatch()..start(), optimized = cycle.isOdd;
      int id = 0;
      Map? opened;
      List<int>? finalStats;
      String? frameHash;
      int? pongClockMicroseconds;
      Future<Map> call(String method, List<dynamic> params) async =>
          await Future<Object?>.value(api.dispatch(method, params)) as Map;
      Future<Map> command(WorldCircuitCommand c) =>
          call('worldCircuitCommand', [id, c.words, c.records]);
      Future<bool> ready() async =>
          ByteData.sublistView(
            (await command(ComputerrariaComputer.ready()))['records']
                as Uint8List,
          ).getUint32(8, Endian.little) ==
          1;
      Future<void> reset() async {
        for (var n = 0; !await ready() && n < 3; n++) {
          await command(ComputerrariaComputer.clock());
        }
        if (!await ready()) await command(ComputerrariaComputer.resetSignal());
        for (final c in ComputerrariaComputer.resetBus) {
          await command(c);
        }
      }

      try {
        opened = await call('worldCircuitOpenSource', [
          source(args[1]),
          source(args[2]),
        ]);
        id = opened['session'] as int;
        require(
          opened['sourceSha256'] == ComputerrariaComputer.sourceSha256,
          'Input world changed in cycle $cycle',
        );
        require(
          (opened['reserved'] as int) & 3 == 1,
          'New session must use original TWLD and default OFF',
        );
        await command(WorldCircuitCommand.optimization(optimized));
        await reset();
        for (final batch in ComputerrariaComputer.programWrites(
          Uint8List(0),
          program,
        )) {
          await command(WorldCircuitCommand.lamps(batch, write: true));
        }
        await reset();
        await command(ComputerrariaComputer.clock(386));
        for (var n = 0; !await ready() && n < 3; n++) {
          await command(ComputerrariaComputer.clock());
        }
        require(await ready(), 'CPU failed to settle in cycle $cycle');
        for (final c in ComputerrariaComputer.resetBus.take(2)) {
          await command(c);
        }
        final result =
                (await command(WorldCircuitCommand.lamps(reads)))['records']
                    as Uint8List,
            view = ByteData.sublistView(result);
        final words = <int>[];
        for (var word = 0; word < checks.length; word++) {
          var value = 0;
          for (var bit = 0; bit < 32; bit++) {
            value |=
                view.getUint32((word * 32 + bit) * 16 + 8, Endian.little) <<
                bit;
          }
          words.add(value);
        }
        require(
          jsonEncode(words) == jsonEncode(expected),
          '48 CPU signatures differ in cycle $cycle',
        );
        await reset();
        for (final batch in ComputerrariaComputer.programWrites(
          program,
          pong,
        )) {
          await command(WorldCircuitCommand.lamps(batch, write: true));
        }
        await reset();
        final pulseTime = Stopwatch()..start();
        await command(ComputerrariaComputer.clock(1536));
        pongClockMicroseconds = pulseTime.elapsedMicroseconds;
        final screen = await command(
          WorldCircuitCommand.pixels(6485, 800, 64, 48),
        );
        final frames = screen['records'] as Uint8List;
        require(
          frames.length == 3072 * 16,
          'Complete physical display unavailable',
        );
        frameHash = sha256.convert(frames).toString();
        require(
          frameHash == '1f5ba8481be3883b0300456083a84f742616fdea7d0b3738d296d489372178ef',
          'Physical Pong frame differs from the complete acceptance signature',
        );
        finalStats = (screen['stats'] as List).cast<int>();
        baselineFrame ??= frameHash;
        require(
          frameHash == baselineFrame,
          'Physical Pong trace differs across modes/cycles',
        );
      } finally {
        if (id != 0) api.dispatch('worldCircuitClose', [id]);
      }
      final native = nativeBytes(),
          bridge = bridgeBytes(),
          openWorlds = worlds(),
          fd = descriptors(),
          rss = ProcessInfo.currentRss;
      require(
        native == 0 && bridge == 0 && openWorlds == 0,
        'Native ownership leak in cycle $cycle',
      );
      require(
        fd == baselineFd,
        'File descriptor ownership changed: $baselineFd -> $fd',
      );
      rssAfter.add(rss);
      passed++;
      final row = {
        'event': 'cycle',
        'cycle': cycle + 1,
        'optimized': optimized,
        'elapsedMs': elapsed.elapsedMilliseconds,
        'nativeAfterClose': native,
        'bridgeAfterClose': bridge,
        'worldsAfterClose': openWorlds,
        'fdAfterClose': fd,
        'rssAfterClose': rss,
        'maxRss': ProcessInfo.maxRss,
        'peakNative': finalStats[17],
        'sourceSha256': opened['sourceSha256'],
        'frameSha256': frameHash,
        'pongClockPulses': 1536,
        'pongClockMicroseconds': pongClockMicroseconds,
      };
      record(row);
      stdout.writeln(jsonEncode(row));
    }
    final warm = rssAfter.skip(rssAfter.length > 5 ? 5 : 0).toList();
    var slope = 0.0;
    if (warm.length > 1) {
      final n = warm.length.toDouble(),
          sx = n * (n - 1) / 2,
          sxx = n * (n - 1) * (2 * n - 1) / 6,
          sy = warm.fold<double>(0, (a, b) => a + b),
          sxy = [for (var i = 0; i < warm.length; i++) i.toDouble() * warm[i]]
              .fold<double>(0, (a, b) => a + b);
      slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    }
    record({
      'event': 'complete',
      'status': 'passed',
      'cycles': passed,
      'warmRssMin': warm.reduce((a, b) => a < b ? a : b),
      'warmRssMax': warm.reduce((a, b) => a > b ? a : b),
      'warmRssSlopeBytesPerCycle': slope,
      'rssInterpretation': 'Observed host RSS trend, distinct from zero tracked native/bridge owners and fixed descriptor count; no forced GC or allocator trimming.',
      'elapsedSeconds': DateTime.now().toUtc().difference(started).inSeconds,
    });
  } catch (error) {
    record({
      'event': 'failure',
      'cyclesPassed': passed,
      'error': error.toString(),
    });
    rethrow;
  } finally {
    journal.closeSync();
  }
}
