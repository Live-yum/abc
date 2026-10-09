// Opt-in acceptance of the complete original public world through ABC's actual
// file-backed Dart/C owner. No instruction decoder or expected framebuffer is
// linked into the DUT. Paths: library, WLD, TWLD, input-once.bin, Pong.bin, report.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

Future<void> main(List<String> args) async {
  if (args.length != 6) {
    throw ArgumentError('library WLD TWLD input.bin Pong.bin report.json');
  }
  final lib = DynamicLibrary.open(args[0]),
      api = NativeWorldCircuitBindings(DynamicLibrary.open(args[0]));
  final fixtures = jsonDecode(
    File('native/fixtures/computerraria/programs.json').readAsStringSync(),
  ) as Map;
  final report = <String, Object?>{
    'schema': 1,
    'status': 'running',
    'temporaryDirectory': Directory.systemTemp.path,
    'host': 'Dart native owner with C physical wiring VM',
    'librarySha256': sha256.convert(File(args[0]).readAsBytesSync()).toString(),
  };
  final optimized = Platform.environment['ABC_COMPUTERRARIA_OPTIMIZED'] == '1';
  report['optimizationEnabled'] = optimized;
  final wall = Stopwatch()..start();
  Map<String, Object?> source(String path) => {
    'path': path,
    'length': File(path).lengthSync(),
    'name': path.split('/').last,
  };
  Future<Map> call(String method, List<dynamic> values) async =>
      await Future<Object?>.value(api.dispatch(method, values)) as Map;
  void require(bool value, String message) {
    if (!value) throw StateError(message);
  }

  final progress = Timer.periodic(const Duration(seconds: 10), (_) {
    stdout.writeln(
      jsonEncode({
        'elapsedMs': wall.elapsedMilliseconds,
        'progress': api.dispatch('worldCircuitProgress', []),
      }),
    );
  });
  int id = 0;
  bool activeOptimization = false;
  final outputTokens = <String>[];
  Uint8List previousProgram = Uint8List(0);
  final clockSamples = <Map<String, Object?>>[];
  Future<Map> command(WorldCircuitCommand c) async {
    final measured = c.words[1] == 2 && c.words[2] == 3194 && c.words[3] == 153;
    final watch = Stopwatch()..start();
    final result = await call('worldCircuitCommand', [id, c.words, c.records]);
    if (c.words[1] != 6) {
      activeOptimization = (result['reserved'] as int) & 2 != 0;
    }
    if (measured) {
      clockSamples.add({
        'pulses': c.words[8],
        'milliseconds': watch.elapsedMicroseconds / 1000,
      });
    }
    return result;
  }

  List<List<int>> rows(Map result) {
    final bytes = result['records'] as Uint8List,
        data = ByteData.sublistView(bytes);
    return [
      for (var offset = 0; offset < bytes.length; offset += 16)
        [
          for (var word = 0; word < 4; word++)
            data.getUint32(offset + word * 4, Endian.little),
        ],
    ];
  }

  String frameHash(Map result) =>
      sha256.convert(result['records'] as Uint8List).toString();
  Future<String> fileHash(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

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
    for (final values in ComputerrariaComputer.programWrites(
      previousProgram,
      bytes,
    )) {
      await command(WorldCircuitCommand.lamps(values, write: true));
    }
    previousProgram = bytes;
    await reset();
  }

  List<int> ramRecords(List<int> addresses, {bool write = false}) {
    final result = <int>[];
    for (final address in addresses) {
      for (var bit = 0; bit < 32; bit++) {
        for (var mirror = 0; mirror < (write ? 2 : 1); mirror++) {
          final (x, y) = ComputerrariaComputer.ramLamp(
            address,
            bit,
            mirror: mirror,
          );
          result.addAll([x, y, 0, 0]);
        }
      }
    }
    return result;
  }

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
    List<int> addresses, {
    WorldCircuitCommand? input,
    List<WorldCircuitCommand> extraInputs = const [],
  }) async {
    final time = Stopwatch()..start();
    await load(bytes);
    await command(
      WorldCircuitCommand.lamps(
        ramRecords(addresses, write: true),
        write: true,
      ),
    );
    await reset();
    if (input != null) await command(input);
    for (final c in extraInputs) {
      await command(c);
    }
    List<int> values = [];
    var clocks = 0;
    while (clocks < 4096) {
      await command(ComputerrariaComputer.clock(128));
      clocks += 128;
      for (var n = 0; !await ready() && n < 3; n++) {
        await command(ComputerrariaComputer.clock());
        clocks++;
      }
      require(
        await ready(),
        'Physical CPU failed to reach an instruction boundary',
      );
      values = await signature(addresses);
      if (values.last == 0x600dc0de) break;
    }
    require(
      values.isNotEmpty && values.last == 0x600dc0de,
      'Physical completion marker was not reached',
    );
    return {
      'signature': values,
      'clocks': clocks,
      'milliseconds': time.elapsedMilliseconds,
    };
  }

  Uint8List image(String name) {
    final text = (fixtures[name] as Map)['hex'] as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  Future<Map> display(bool color, {bool old = false}) => command(
    old
        ? WorldCircuitCommand.viewport(
            color ? 7371 : 6485,
            color ? 1002 : 800,
            color ? 176 : 64,
            color ? 96 : 48,
          )
        : WorldCircuitCommand.pixels(
            color ? 7371 : 6485,
            color ? 1002 : 800,
            color ? 176 : 64,
            color ? 96 : 48,
          ),
  );
  try {
    final opened = await call('worldCircuitOpenSource', [
      source(args[1]),
      source(args[2]),
    ]);
    id = opened['session'] as int;
    report['defaultOptimization'] = (opened['reserved'] as int) & 2 != 0;
    require(
      (opened['reserved'] as int) & 2 == 0,
      'Optimization must default OFF',
    );
    final mode = await command(WorldCircuitCommand.optimization(optimized));
    require(
      ((mode['reserved'] as int) & 2 != 0) == optimized,
      'Native strategy did not match requested mode',
    );
    report['activeOptimizationAtStart'] = activeOptimization;
    final stats = (opened['stats'] as List).cast<int>();
    report['import'] = {
      'milliseconds': wall.elapsedMilliseconds,
      'stats': stats,
      'sourceSha256': opened['sourceSha256'],
      'twldSourceSha256': opened['twldSourceSha256'],
      'rssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
    };
    require(
      opened['twldSourceSha256'] ==
          'c6de694b3d034701513dc1ba17311213561ec359d3ecddde7bc35ea3c9611ed8',
      'Original companion digest must be computed from actual bytes',
    );
    final structure = lib
        .lookupFunction<
          Uint32 Function(Uint32, Uint32),
          int Function(int, int)
        >('abc_perf_world_circuit_count');
    report['structure'] = {
      'devices': structure(id, 0),
      'pixels': structure(id, 1),
      'generalGates': structure(id, 2),
    };
    require(
      opened['sourceSha256'] == ComputerrariaComputer.sourceSha256,
      'Wrong public input identity',
    );
    require(
      stats[2] == 15200 &&
          stats[3] == 7200 &&
          stats[10] == 72939714 &&
          stats[12] == 13641575,
      'Full world was not represented',
    );
    require(
      (opened['reserved'] as int) & 1 == 1,
      'Original TWLD compatibility profile missing',
    );
    require(
      rows(await display(false)).length == 3072 &&
          rows(await display(true)).length == 16896,
      'Native screen geometry',
    );
    final checks = (fixtures['main'] as Map)['checks'] as List;
    final addresses = checks.map((v) => (v as Map)['address'] as int).toList();
    final expected = checks.map((v) => (v as Map)['expected'] as int).toList();
    report['main'] = await execute(image('main'), addresses);
    require(
      jsonEncode((report['main'] as Map)['signature']) == jsonEncode(expected),
      '48 physical CPU signatures mismatch',
    );
    final mutation = image('main');
    mutation[(fixtures['mutationWord'] as int) * 4 + 2] ^= 0x10;
    report['negativeControl'] = await execute(mutation, addresses);
    final changed = List<int>.from(
      (report['negativeControl'] as Map)['signature'] as List,
    );
    require(
      changed.first == 0x7fffffff &&
          jsonEncode(changed.sublist(1)) == jsonEncode(expected.sublist(1)),
      'Actual ROM mutation did not change exactly one expected result',
    );
    report['displayProgram'] = await execute(image('display'), [0x1000bc]);
    final mono = rows(await display(false)), color = rows(await display(true));
    final litMono = mono.where((r) => r[3] != 0).toList(),
        litColor = color.where((r) => r[3] != 0).toList();
    require(
      litMono.length == 2 &&
          litMono[0][0] == 6485 &&
          litMono[1][0] == 6516 &&
          litMono.every((v) => v[1] == 800 && v[3] == 18),
      'Real monochrome display mismatch',
    );
    require(
      litColor.length == 8 &&
          litColor.first[0] == 7371 &&
          litColor.last[0] == 7378 &&
          litColor.every((v) => v[1] == 1002 && v[3] == (54 | (54 << 16))),
      'Real color display mismatch',
    );
    require(
      jsonEncode(rows(await display(false, old: true))) == jsonEncode(mono),
      'Direct mono query differs from original viewport',
    );
    require(
      jsonEncode(rows(await display(true, old: true))) == jsonEncode(color),
      'Direct color query differs from original viewport',
    );
    final pixelTime = Stopwatch()..start();
    for (var n = 0; n < 100; n++) {
      await display(false);
    }
    report['display'] = {
      'mono': litMono,
      'color': litColor,
      'monoQueries100Ms': pixelTime.elapsedMilliseconds,
    };
    report['correctness'] = <String, Object?>{
      'displayMonoSha256': frameHash(await display(false)),
      'displayColorSha256': frameHash(await display(true)),
    };
    stdout.writeln(
      'PASS: full-world identity, 48 CPU signatures, real ROM negative control, actual mono/color output, direct pixels match viewport',
    );
    final input = args[3] == '-'
        ? image('input')
        : File(args[3]).readAsBytesSync();
    final probes = <Map<String, Object?>>[];
    probes.add({
      'sensor': null,
      'run': await execute(input, [0x100000, 0x1000bc]),
    });
    for (final sensor in [
      [6516, 851, 9],
      [6517, 866, 5],
      [6519, 858, 10],
      [6520, 857, 5],
    ]) {
      probes.add({
        'sensor': sensor,
        'pulse': 1,
        'run': await execute(
          input,
          [0x100000, 0x1000bc],
          input: WorldCircuitCommand.trigger(
            sensor[0],
            sensor[1],
            mask: sensor[2],
            hitSwitch: false,
          ),
        ),
      });
      probes.add({
        'sensor': sensor,
        'pulse': 2,
        'run': await execute(
          input,
          [0x100000, 0x1000bc],
          input: WorldCircuitCommand.trigger(
            sensor[0],
            sensor[1],
            mask: sensor[2],
            hitSwitch: false,
            pulses: 2,
          ),
        ),
      });
      probes.add({
        'sensor': sensor,
        'pulse': 3,
        'run': await execute(
          input,
          [0x100000, 0x1000bc],
          input: WorldCircuitCommand.trigger(
            sensor[0],
            sensor[1],
            mask: sensor[2],
            hitSwitch: false,
            pulses: 3,
          ),
        ),
      });
      probes.add({
        'sensor': sensor,
        'pulse': 0,
        'run': await execute(input, [0x100000, 0x1000bc]),
      });
      probes.add({
        'sensor': sensor,
        'pulse': 1,
        'run': await execute(
          input,
          [0x100000, 0x1000bc],
          input: WorldCircuitCommand.trigger(
            sensor[0],
            sensor[1],
            mask: sensor[2],
            hitSwitch: false,
          ),
        ),
      });
    }
    final up = WorldCircuitCommand.trigger(
      6516,
      851,
      mask: 9,
      hitSwitch: false,
    );
    final down = WorldCircuitCommand.trigger(
      6517,
      866,
      mask: 5,
      hitSwitch: false,
    );
    final left = WorldCircuitCommand.trigger(
      6519,
      858,
      mask: 10,
      hitSwitch: false,
    );
    final right = WorldCircuitCommand.trigger(
      6520,
      857,
      mask: 5,
      hitSwitch: false,
    );
    final pair = await execute(
      input,
      [0x100000, 0x1000bc],
      extraInputs: [up, down],
    );
    require(
      ((pair['signature'] as List).first as int) & 15 == 9,
      'UP+DOWN physical input OR',
    );
    probes.add({'sensor': 'up+down', 'run': pair});
    final all = await execute(
      input,
      [0x100000, 0x1000bc],
      extraInputs: [
        up,
        down,
        left,
        right,
        WorldCircuitCommand.optimization(!optimized),
        WorldCircuitCommand.optimization(optimized),
      ],
    );
    require(
      ((all['signature'] as List).first as int) & 15 == 15,
      'All directions survive idle mode switch',
    );
    probes.add({'sensor': 'all+idleSwitch', 'run': all});
    report['inputProbes'] = probes;
    stdout.writeln(jsonEncode({'inputProbes': probes}));
    await execute(image('clear'), [0x1000bc]);
    final pong = File(args[4]).readAsBytesSync();
    await load(pong);
    final frames = <Map<String, Object?>>[], hashes = <String>{};
    final play = Stopwatch()..start(), firstPongSample = clockSamples.length;
    var clocks = 0;
    for (var n = 0; n < 400; n++) {
      await command(ComputerrariaComputer.clock(128));
      clocks += 128;
      final frame = await display(false), bytes = frame['records'] as Uint8List;
      final lit = rows(frame)
          .where((v) => v[3] == 18)
          .map((v) => [v[0] - 6485, v[1] - 800])
          .toList();
      final hash = sha256.convert(bytes).toString();
      if (hashes.add(hash)) {
        frames.add({'clocks': clocks, 'sha256': hash, 'lit': lit});
      }
      final moving = frames
          .where(
            (v) => (v['lit'] as List).any((dynamic p) => p[0] > 1 && p[0] < 62),
          )
          .length;
      if (moving >= 3) break;
    }
    require(
      frames
              .where(
                (v) => (v['lit'] as List).any(
                  (dynamic p) => p[0] > 1 && p[0] < 62,
                ),
              )
              .length >=
          3,
      'Upstream Pong did not produce three actual moving-ball states',
    );
    final samples = clockSamples.sublist(firstPongSample),
        times = samples.map((v) => v['milliseconds'] as double).toList()
          ..sort();
    final pureClockMs = times.fold<double>(0, (a, b) => a + b);
    report['pong'] = {
      'binarySha256': sha256.convert(pong).toString(),
      'bytes': pong.length,
      'clocks': clocks,
      'milliseconds': play.elapsedMilliseconds,
      'frames': frames,
      'pureClockMilliseconds': pureClockMs,
      'pureClockPulsesPerSecond': clocks * 1000 / pureClockMs,
      'batchMedianMs': times[times.length ~/ 2],
      'batchP95Ms': times[((times.length - 1) * .95).ceil()],
      'clockSamples': samples,
    };
    (report['correctness'] as Map<String, Object?>).addAll({
      'pongFinalMonoSha256': frameHash(await display(false)),
      'pongFinalColorSha256': frameHash(await display(true)),
    });
    report['finalStats'] = (await display(false))['stats'];
    report['hostProgress'] = api.dispatch('worldCircuitProgress', []);
    report['maxRssBytes'] = ProcessInfo.maxRss;
    stdout.writeln(
      'PASS: original upstream Pong physically executes and produces multiple real screen states',
    );
    final beforeSwitch = (await display(false))['records'] as Uint8List;
    final beforeReady = await ready();
    final flipped = await command(WorldCircuitCommand.optimization(!optimized));
    require(
      ((flipped['reserved'] as int) & 2 != 0) != optimized,
      'Mode switch did not take effect',
    );
    require(
      (flipped['reserved'] as int) & 1 == 1,
      'Optimization must not replace TWLD compatibility',
    );
    require(
      beforeSwitch.toString() ==
              ((await display(false))['records'] as Uint8List).toString() &&
          beforeReady == await ready(),
      'Idle switch changed physical display/ready state',
    );
    await command(WorldCircuitCommand.optimization(optimized));
    report['idleSwitchPreservesState'] = true;
    if (Platform.environment['ABC_COMPUTERRARIA_SAVE'] == '1') {
      final beforeMono = rows(await display(false)),
          beforeColor = rows(await display(true));
      final beforeHashes = {
        'mono': frameHash(await display(false)),
        'color': frameHash(await display(true)),
      };
      final saveTime = Stopwatch()..start(),
          saved = await command(WorldCircuitCommand.save());
      final wld = WorldCircuitSource.fromMap(saved['worldSource'] as Map),
          twld = WorldCircuitSource.fromMap(saved['twldSource'] as Map);
      outputTokens.addAll([wld.token!, twld.token!]);
      report['save'] = <String, Object?>{
        'milliseconds': saveTime.elapsedMilliseconds,
        'worldBytes': wld.length,
        'twldBytes': twld.length,
        'worldSha256': await fileHash(wld.path!),
        'twldSha256': await fileHash(twld.path!),
        'beforeDisplaySha256': beforeHashes,
      };
      require(
        wld.sha256 == (report['save'] as Map)['worldSha256'] &&
            twld.sha256 == (report['save'] as Map)['twldSha256'],
        'Leased output digests must match independent streamed hashes',
      );
      api.dispatch('worldCircuitClose', [id]);
      id = 0;
      require(
        File(wld.path!).existsSync() && File(twld.path!).existsSync(),
        'Paired output lifetime',
      );
      final reopened = await call('worldCircuitOpenSource', [
        wld.toFileMap(),
        twld.toFileMap(),
      ]);
      id = reopened['session'] as int;
      require(
        (reopened['reserved'] as int) & 2 == 0,
        'Reopened mode must default OFF',
      );
      await command(WorldCircuitCommand.optimization(optimized));
      require(
        jsonEncode(rows(await display(false))) == jsonEncode(beforeMono),
        'Saved native mono frames changed',
      );
      require(
        jsonEncode(rows(await display(true))) == jsonEncode(beforeColor),
        'Saved native color frames changed',
      );
      report['savedSourceSha256'] = reopened['sourceSha256'];
      (report['save'] as Map)['reopenedDisplaySha256'] = {
        'mono': frameHash(await display(false)),
        'color': frameHash(await display(true)),
      };
      await execute(image('display'), [0x1000bc]);
      require(
        rows(await display(false))
                .where((r) => r[1] == 800 && r[0] < 6517)
                .where((r) => r[3] != 0)
                .length ==
            2,
        'Reopened physical mono controller cannot set target word',
      );
      require(
        rows(await display(true))
            .where((r) => r[1] == 1002 && r[0] < 7379)
            .every((r) => r[3] == (54 | (54 << 16))),
        'Reopened physical color controller cannot set target word',
      );
      await execute(image('clear'), [0x1000bc]);
      final clearedMono = rows(await display(false)),
          clearedColor = rows(await display(true));
      require(
        clearedMono
                .where((r) => r[1] == 800 && r[0] < 6517)
                .every((r) => r[3] == 0) &&
            clearedColor
                .where((r) => r[1] == 1002 && r[0] < 7379)
                .every((r) => r[3] == 0),
        'Saved physical target-word set/clear failed',
      );
      report['postReopenTargetWordsCleared'] = true;
      (report['save'] as Map<String, Object?>).addAll({
        'status': 'passed',
        'postProgramDisplaySha256': {
          'mono': frameHash(await display(false)),
          'color': frameHash(await display(true)),
        },
      });
      report['postReopenOtherPixelChanges'] = {
        'scope': 'Observed after reset/replacing a paused Pong ROM and issuing real display updates; partial-word fixture does not promise other buffer words stay unchanged.',
        'mono': [
          for (var i = 0; i < beforeMono.length; i++)
            if (beforeMono[i][3] != clearedMono[i][3])
              [
                clearedMono[i][0],
                clearedMono[i][1],
                beforeMono[i][3],
                clearedMono[i][3],
              ],
        ],
        'color': [
          for (var i = 0; i < beforeColor.length; i++)
            if (beforeColor[i][3] != clearedColor[i][3])
              [
                clearedColor[i][0],
                clearedColor[i][1],
                beforeColor[i][3],
                clearedColor[i][3],
              ],
        ],
      };
      api.dispatch('worldCircuitClose', [id]);
      id = 0;
      api.dispatch('worldCircuitReleaseSource', [wld.token]);
      api.dispatch('worldCircuitReleaseSource', [twld.token]);
      stdout.writeln(
        'PASS: complete streamed paired save, independent output lifetime, reopen and real CPU clear',
      );
    }
    report['activeOptimizationAtEnd'] = activeOptimization;
    report['status'] = 'passed';
  } catch (error) {
    report['status'] = 'failed';
    report['error'] = error.toString();
    rethrow;
  } finally {
    progress.cancel();
    if (id != 0) api.dispatch('worldCircuitClose', [id]);
    for (final token in outputTokens) {
      api.dispatch('worldCircuitReleaseSource', [token]);
    }
    report['nativeBytesAfterClose'] = lib
        .lookupFunction<Uint32 Function(), int Function()>(
          'abc_perf_native_live_bytes',
        )();
    if (report['nativeBytesAfterClose'] != 0) report['status'] = 'failed';
    report['elapsedMilliseconds'] = wall.elapsedMilliseconds;
    File(args[5]).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
  }
  require(
    report['nativeBytesAfterClose'] == 0,
    'Native owner allocations remain after close',
  );
}
