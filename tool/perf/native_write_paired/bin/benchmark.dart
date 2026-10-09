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

  Future<Map> display() async {
    final result = await command(WorldCircuitCommand.pixels(6485, 800, 64, 48));
    // Use the shipped coordinate, tile, frame and uniqueness validation.
    ComputerrariaComputer.mono.decode(WorldCircuitResult.fromMap(result));
    return result;
  }

  Future<int> mode(bool optimized) async {
    final value = await command(WorldCircuitCommand.optimization(optimized));
    final flags = value['reserved'] as int;
    require((flags & 14) == (optimized ? 14 : 4), 'Requested mode flags mismatch: $flags');
    return flags;
  }

  Uint8List program(Map fixtures, String name) {
    final hex = (fixtures[name] as Map)['hex'] as String;
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  Future<Map<String, Object?>> snapshot(Map fixtures, Uint8List pong) async {
    // Passive queries only. Do not reset the CPU/bus before save comparison.
    final checks = (fixtures['main'] as Map)['checks'] as List;
    final addresses = <int>{
      for (final c in checks) (c as Map)['address'] as int,
      for (var i = 0; i < 16; i++) 0x100000 + i * 4,
      for (var i = 0; i < 256; i++) 0x15bc00 + i * 4,
    }.toList();
    final ram = await command(WorldCircuitCommand.lamps(ramRecords(addresses)));
    final rom = await command(WorldCircuitCommand.lamps([
      for (var address = 0; address < pong.length; address += 4)
        for (var bit = 0; bit < 32; bit++) ...[
          ComputerrariaComputer.romLamp(address, bit).$1,
          ComputerrariaComputer.romLamp(address, bit).$2, 0, 0,
        ],
    ]));
    final screen = await display();
    final viewport = await command(WorldCircuitCommand.viewport(6485, 800, 64, 48));
    require(recordsHash(screen) == recordsHash(viewport), 'Passive viewport differs');
    return {
      'ramSha256': recordsHash(ram), 'ramAddresses': addresses,
      'romSha256': recordsHash(rom), 'romBytes': pong.length,
      'displaySha256': recordsHash(screen), 'displayRecords': rows(screen).length,
      'litPixels': rows(screen).where((r) => r[3] == 18).length,
      'ready': await ready(), 'modeFlags': screen['reserved'],
      'scope': 'passive ready lamp, fixture/Pong RAM and stack, Pong ROM range and all 3072 pixels; not all CPU internal registers',
    };
  }

  Future<Map<String, Object?>> afterReopen(Map fixtures, bool optimized, Map<String, Object?> evidence) async {
    final checks = (fixtures['main'] as Map)['checks'] as List;
    final expected = [for (final c in checks) (c as Map)['expected'] as int];
    final cpu = await execute(program(fixtures, 'main'), [
      for (final c in checks) (c as Map)['address'] as int,
    ]);
    evidence['cpu'] = cpu;
    require(jsonEncode(cpu['signature']) == jsonEncode(expected), 'Reopened CPU signatures mismatch: $cpu');
    await execute(program(fixtures, 'display'), [0x1000bc]);
    final set = await display();
    final target = rows(set).where((r) => r[1] == 800 && r[0] < 6517).toList();
    evidence['displayTargetSetRows'] = target;
    require(target.where((r) => r[3] != 0).length == (optimized ? 2 : 0),
        'Reopened display target-word mismatch');
    await execute(program(fixtures, 'clear'), [0x1000bc]);
    final clear = await display();
    evidence['displayTargetClearRows'] = rows(clear).where((r) => r[1] == 800 && r[0] < 6517).toList();
    require((evidence['displayTargetClearRows'] as List<List<int>>).every((r) => r[3] == 0),
        'Reopened display target-word clear mismatch');
    evidence.addAll({'displaySetSha256': recordsHash(set),
      'displayClearSha256': recordsHash(clear), 'targetWordsPassed': true});
    return evidence;
  }

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

  Future<Map<String, Object?>> correctness(Map fixtures, Uint8List pong, bool optimized, Map<String, Object?> evidence) async {
    final modeFlags = await mode(optimized);
    evidence['modeFlags'] = modeFlags;
    final initial = await display();
    require(
      rows(initial).length == 3072,
      'Actual screen must contain 3072 pixels',
    );
    final checks = (fixtures['main'] as Map)['checks'] as List;
    final addresses = [for (final c in checks) (c as Map)['address'] as int];
    final expected = [for (final c in checks) (c as Map)['expected'] as int];
    final cpu = await execute(program(fixtures, 'main'), addresses);
    evidence['cpu'] = cpu;
    require(
      jsonEncode(cpu['signature']) == jsonEncode(expected),
      '48 physical CPU signatures mismatch',
    );
    final displayProgram = await execute(program(fixtures, 'display'), [0x1000bc]);
    final mono = await display();
    final lit = rows(mono).where((r) => r[3] != 0).toList();
    evidence['displayLitRows'] = lit;
    require(
      optimized ? (lit.length == 2 && lit[0][0] == 6485 && lit[1][0] == 6516 &&
          lit.every((r) => r[1] == 800 && r[3] == 18)) : lit.isEmpty,
      'Physical two-pixel display program mismatch',
    );
    final viewport = await command(
      WorldCircuitCommand.viewport(6485, 800, 64, 48),
    );
    require(
      recordsHash(viewport) == recordsHash(mono),
      'Physical query mismatch',
    );
    await execute(program(fixtures, 'clear'), [0x1000bc]);
    await load(pong);
    final passive = ramRecords([
      for (var i = 0; i < 16; i++) 0x100000 + i * 4,
      for (var i = 0; i < 256; i++) 0x15bc00 + i * 4,
    ]);
    final frames = <Map<String, Object?>>[];
    evidence['pongFrames'] = frames;
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
    require(optimized ? movingFrames.length >= 3 : frames.every((f) => f['litCount'] == 0),
        'Pong does not match the selected display rule');
    final finalFrame = await display();
    evidence['finalModeFlags'] = finalFrame['reserved'];
    require(finalFrame['reserved'] == (optimized ? 14 : 4), 'Mode changed during physical workload');
    evidence.addAll({
      'sourceSha256': sourceDigest,
      'modeFlags': modeFlags,
      'optimizationEnabled': optimized,
      'displayStatus': optimized ? 'moving' : 'expected-dark',
      'initialDisplaySha256': recordsHash(initial),
      'cpu': cpu,
      'displayProgram': displayProgram,
      'displaySha256': recordsHash(mono),
      'pongSha256': sha256.convert(pong).toString(),
      'pongFrames': frames,
      'finalStats': finalFrame['stats'],
    });
    return evidence;
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 6) throw ArgumentError('library world pong programs report variant');
  final wall = Stopwatch()..start();
  final reportFile = File(args[4]);
  final source = File(args[1]), before = File(args[1]).statSync();
  require(before.size == 405983441, 'Public WLD size mismatch');
  final pong = File(args[2]).readAsBytesSync();
  require(pong.length == 2288 && sha256.convert(pong).toString() == pongDigest,
      'Original Pong identity mismatch');
  final fixtures = jsonDecode(File(args[3]).readAsStringSync()) as Map;
  final library = DynamicLibrary.open(args[0]);
  final api = NativeWorldCircuitBindings(library);
  final liveBytes = library.providesSymbol('abc_perf_native_live_bytes')
      ? library.lookupFunction<Uint32 Function(), int Function()>('abc_perf_native_live_bytes') : null;
  final leases = <String, WorldCircuitSource>{};
  final report = <String, Object?>{
    'schema': 2, 'status': 'running',
    'scope': 'pure-Dart AOT actual host wrapper, not Flutter UI/frame evidence',
    'variant': args[5], 'pid': pid, 'dartVersion': Platform.version,
    'quietMilliseconds': 1200, 'cycles': <Map<String, Object?>>[],
    'scenarioOrder': ['OFF/reset', 'ON/reset', 'OFF/save-reopen', 'ON/save-reopen'],
    'phaseTimingMethod': '20ms observations of existing progress; approximate stage wall intervals; operation totals use direct stopwatch and exclude sampler acknowledgment',
    'coldDefinition': 'first original open in fresh process; every later open is warm; OS page cache is not flushed',
    'nativeCounterAvailable': liveBytes != null,
  };
  void persist() => reportFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  final acknowledgments = StreamIterator<String>(stdin.transform(utf8.decoder).transform(const LineSplitter()));
  Future<void> event(String phase, int cycle) async {
    stdout.writeln(jsonEncode({'event': 'boundary', 'phase': phase, 'cycle': cycle,
      'elapsedUs': wall.elapsedMicroseconds, 'currentRssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss, 'nativeLiveBytes': liveBytes?.call()}));
    await stdout.flush();
    require(await acknowledgments.moveNext() && acknowledgments.current == 'ack',
        'External boundary sampler did not acknowledge');
  }
  final original = WorldCircuitSource.file(path: source.path, length: before.size, name: 'computerraria.wld');
  Future<Map> open(WorldCircuitSource input) async => await Future<Object?>.value(
      api.dispatch('worldCircuitOpenSource', [input.toFileMap()])) as Map;
  Future<String> fileHash(File file) async => (await sha256.bind(file.openRead()).first).toString();
  void checkOriginalStat() {
    final after = source.statSync();
    require(after.size == before.size && after.modified == before.modified && after.type == before.type,
        'Original WLD stat changed');
  }
  void checkClosed() {
    require(liveBytes == null || liveBytes() == 0, 'Tracked native allocations remain after close');
    final ownedOutputs = leases.values.map((s) => File(s.path!).parent.path).toSet();
    require(Directory.systemTemp.listSync().whereType<Directory>()
        .where((d) => d.path.split('/').last.startsWith('abc-circuit-') && !ownedOutputs.contains(d.path)).isEmpty,
        'Unowned session scratch directory remains after close');
    checkOriginalStat();
  }
  void closeAndRejectHandle(int closedId) {
    api.dispatch('worldCircuitClose', [closedId]);
    var rejected = false;
    final query = ComputerrariaComputer.ready();
    try { api.dispatch('worldCircuitCommand', [closedId, query.words, query.records]); }
    catch (error) { rejected = error.toString().contains('session is closed'); }
    require(rejected, 'Closed wrapper handle was not rejected');
  }
  void checkOpen(Map opened, String expectedHash) {
    final stats = (opened['stats'] as List).cast<int>();
    require(opened['sourceSha256'] == expectedHash, 'Opened source SHA mismatch');
    require(stats.length == 24 && stats[0] == 2 && stats[2] == 15200 && stats[3] == 7200 &&
        stats[10] == 72939714 && stats[12] == 13641575, 'Complete public world graph mismatch');
    require((opened['reserved'] as int) & 3 == 0, 'Reopened WLD must default OFF');
  }
  Future<Map> measured(String name, int cycle, Map<String, Object?> timings,
      Future<Map> Function() action, Set<String> stages) async {
    await event('before${name[0].toUpperCase()}${name.substring(1)}', cycle);
    final transitions = <Map<String, Object?>>[];
    final timer = Stopwatch()..start();
    String? lastStage;
    void observe() {
      final progress = api.dispatch('worldCircuitProgress', []);
      if (progress is! Map || !stages.contains(progress['stage'])) return;
      final stage = progress['stage'] as String;
      if (stage != lastStage) {
        transitions.add({'stage': stage, 'elapsedUs': timer.elapsedMicroseconds,
          'progress': Map<String, Object?>.from(progress)});
        lastStage = stage;
      }
    }
    final monitor = Timer.periodic(const Duration(milliseconds: 20), (_) => observe());
    try {
      final value = await action();
      observe();
      return value;
    } finally {
      timer.stop(); monitor.cancel();
      timings['${name}Microseconds'] = timer.elapsedMicroseconds;
      timings['${name}ProgressTransitions'] = transitions;
      final observed = <String, int>{};
      for (var i = 0; i < transitions.length; i++) {
        final end = i + 1 < transitions.length ? transitions[i + 1]['elapsedUs'] as int : timer.elapsedMicroseconds;
        final stage = transitions[i]['stage'] as String;
        observed[stage] = (observed[stage] ?? 0) + end - (transitions[i]['elapsedUs'] as int);
      }
      timings['${name}ObservedMicroseconds'] = observed;
      persist();
    }
  }
  int id = 0;
  try {
    await event('processReady', 0);
    for (var cycle = 1; cycle <= 4; cycle++) {
      final optimized = cycle.isEven, saving = cycle > 2;
      final scenario = '${optimized ? 'ON' : 'OFF'}/${saving ? 'save-reopen' : 'reset'}';
      final timings = <String, Object?>{};
      final item = <String, Object?>{'cycle': cycle, 'scenario': scenario,
        'optimizationEnabled': optimized, 'temperature': cycle == 1 ? 'process-cold' : 'warm',
        'reopenTemperature': 'warm', 'timings': timings};
      (report['cycles'] as List).add(item);
      persist();
      final opened = await measured('open', cycle, timings, () => open(original), {'hash', 'decode', 'compile'});
      id = opened['session'] as int;
      item.addAll({'sourceSha256': opened['sourceSha256'], 'openStats': opened['stats'], 'openFlags': opened['reserved']});
      checkOpen(opened, sourceDigest);
      await event('opened', cycle);
      final probe = Probe(api, id);
      await probe.mode(optimized);
      final pristine = await probe.snapshot(fixtures, pong);
      item['pristineState'] = pristine;
      final correctnessTime = Stopwatch()..start();
      final correctness = <String, Object?>{};
      item['correctness'] = correctness;
      await probe.correctness(fixtures, pong, optimized, correctness);
      timings['correctnessMicroseconds'] = correctnessTime.elapsedMicroseconds;
      final paused = await probe.snapshot(fixtures, pong);
      item['pausedState'] = paused;
      WorldCircuitSource reopenSource = original;
      String reopenHash = sourceDigest;
      Map<String, Object?>? savedEvidence;
      if (saving) {
        final saved = await measured('save', cycle, timings, () => probe.command(WorldCircuitCommand.save()), {'run', 'hash-output'});
        require(saved['resultKind'] == 6 && saved['world'] == null, 'SAVE must return a streamed world lease');
        final lease = WorldCircuitSource.fromMap(saved['worldSource'] as Map);
        require(lease.token != null && !leases.containsKey(lease.token), 'SAVE lease token missing or reused');
        leases[lease.token!] = lease;
        require(lease.path != source.path && lease.length == saved['resultCount'] && lease.length > 0 &&
            File(lease.path!).lengthSync() == lease.length && saved['sourceSha256'] == sourceDigest,
            'SAVE lease identity or result length mismatch');
        savedEvidence = {'status': 'running', 'resultKind': saved['resultKind'], 'resultCount': saved['resultCount'],
          'sourceSha256': saved['sourceSha256'], 'lease': {'token': lease.token, 'bytes': lease.length, 'sha256': lease.sha256},
          'beforeState': paused};
        item['save'] = savedEvidence;
        await event('saved', cycle);
        final hash = await fileHash(File(lease.path!));
        savedEvidence['independentSha256'] = hash;
        require(hash == lease.sha256 && hash != sourceDigest, 'Independent saved WLD hash mismatch');
        final afterSave = await probe.snapshot(fixtures, pong);
        savedEvidence['afterSaveState'] = afterSave;
        require(jsonEncode(afterSave) == jsonEncode(paused), 'SAVE changed paused physical state');
        reopenSource = lease; reopenHash = hash;
      }
      await event('beforeIntermediateClose', cycle);
      final intermediateClose = Stopwatch()..start();
      closeAndRejectHandle(id); id = 0;
      timings['intermediateCloseMicroseconds'] = intermediateClose.elapsedMicroseconds;
      item['intermediateClosedHandleRejected'] = true;
      checkClosed();
      await event('intermediateClosed', cycle);
      if (saving) {
        require(File(reopenSource.path!).existsSync(), 'Output lease did not survive session close');
        savedEvidence!['survivedClose'] = true;
      }
      final reopened = await measured('reopen', cycle, timings, () => open(reopenSource), {'hash', 'decode', 'compile'});
      id = reopened['session'] as int;
      item.addAll({'reopenedSourceSha256': reopened['sourceSha256'], 'reopenedStats': reopened['stats'],
        'reopenedFlags': reopened['reserved']});
      checkOpen(reopened, reopenHash);
      await event('reopened', cycle);
      final next = Probe(api, id);
      final modeFlags = await next.mode(optimized);
      item['reopenedModeFlags'] = modeFlags;
      final restored = await next.snapshot(fixtures, pong);
      final expectedState = saving ? paused : pristine;
      item['restoredState'] = restored;
      require(jsonEncode(restored) == jsonEncode(expectedState), 'Reopen physical state mismatch');
      if (saving) next.previous = pong;
      final verification = Stopwatch()..start();
      final reopenedChecks = <String, Object?>{};
      item['reopenCorrectness'] = reopenedChecks;
      await next.afterReopen(fixtures, optimized, reopenedChecks);
      timings['reopenCorrectnessMicroseconds'] = verification.elapsedMicroseconds;
      await event('beforeClose', cycle);
      final close = Stopwatch()..start();
      closeAndRejectHandle(id); id = 0;
      timings['closeMicroseconds'] = close.elapsedMicroseconds;
      item['closedHandleRejected'] = true;
      checkClosed();
      if (saving) {
        final hash = await fileHash(File(reopenSource.path!));
        final savedItem = savedEvidence!;
        savedItem['sha256AfterReopen'] = hash;
        require(hash == reopenHash, 'Reopen commands modified immutable output lease');
        api.dispatch('worldCircuitReleaseSource', [reopenSource.token!]);
        require(!File(reopenSource.path!).existsSync() && !File(reopenSource.path!).parent.existsSync(),
            'Output lease release did not remove owned file and directory');
        api.dispatch('worldCircuitReleaseSource', [reopenSource.token!]);
        leases.remove(reopenSource.token);
        savedItem.addAll({'status': 'passed', 'released': true, 'secondReleaseSucceeded': true});
      } else {
        item['resetRestoredOriginal'] = true;
      }
      checkClosed();
      await event('verifyOriginal', cycle);
      item['originalSha256After'] = await fileHash(source);
      require(item['originalSha256After'] == sourceDigest, 'Original source hash changed');
      checkOriginalStat();
      await event('closed', cycle);
      final quiet = Stopwatch()..start();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      timings['actualQuietMicroseconds'] = quiet.elapsedMicroseconds;
      await event('closedQuiet', cycle);
      item['closedNativeLiveBytes'] = liveBytes?.call();
      item['status'] = 'passed';
      persist();
    }
    // One bounded hash cancellation/recovery after all four measured scenarios.
    await event('cancellationStart', 5);
    final pending = open(original);
    api.dispatch('worldCircuitCancelOperation', []);
    String? cancelError;
    try { id = (await pending)['session'] as int; }
    catch (error) { cancelError = error.toString(); }
    require(cancelError != null && cancelError.contains('cancelled'), 'Hash cancellation did not reject');
    checkClosed();
    await event('cancelled', 5);
    final recovered = await open(original); id = recovered['session'] as int;
    checkOpen(recovered, sourceDigest);
    final frame = await Probe(api, id).display();
    report['cancellation'] = {'scope': 'first source-hash yield, then full reopen and physical query; not SAVE cancellation or all failure coverage',
      'error': cancelError, 'reopenedSourceSha256': recovered['sourceSha256'],
      'reopenedStats': recovered['stats'], 'displaySha256': recordsHash(frame)};
    closeAndRejectHandle(id); id = 0; checkClosed();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await event('recoveryClosedQuiet', 5);
    report['status'] = 'passed';
  } catch (error, stack) {
    report['status'] = 'failed'; report['error'] = error.toString(); report['stack'] = stack.toString(); exitCode = 1;
  } finally {
    if (id != 0) {
      try { api.dispatch('worldCircuitClose', [id]); }
      catch (error) { report['cleanupError'] = error.toString(); report['status'] = 'failed'; exitCode = 1; }
    }
    for (final token in leases.keys.toList()) {
      try { api.dispatch('worldCircuitReleaseSource', [token]); leases.remove(token); }
      catch (error) { report['leaseCleanupError'] = error.toString(); report['status'] = 'failed'; exitCode = 1; }
    }
    report['elapsedMicroseconds'] = wall.elapsedMicroseconds;
    report['nativeLiveBytesAfterClose'] = liveBytes?.call();
    report['originalStatUnchanged'] = source.statSync().size == before.size && source.statSync().modified == before.modified;
    report['remainingLeaseCount'] = leases.length;
    persist();
    await event('processComplete', 5);
    await acknowledgments.cancel();
  }
}
