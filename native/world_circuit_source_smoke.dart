import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

Future<void> main(List<String> args) async {
  if (args.length == 2) {
    for (final mode in ['0', '1']) {
      await main([...args, mode]);
    }
    return;
  }
  final optimized = args[2] == '1';
  final library = DynamicLibrary.open(args[0]);
  final api = NativeWorldCircuitBindings(library);
  final path = args[1], original = File(args[1]).readAsBytesSync();
  Future<Map> call(String method, List<dynamic> values) async =>
      await Future<Object?>.value(api.dispatch(method, values)) as Map;
  Map<String, Object?> source() => {
    'path': path,
    'length': original.length,
    'name': 'pixel.wld',
    'sha256':
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
  };
  void require(bool value, String message) {
    if (!value) throw StateError(message);
  }

  var opened = await call('worldCircuitOpenSource', [source(), null]);
  var id = opened['session'] as int;
  Future<Map> command(WorldCircuitCommand c) =>
      call('worldCircuitCommand', [id, c.words, c.records]);
  Future<Uint8List> pixels() async =>
      (await command(WorldCircuitCommand.pixels(1, 8, 5, 5)))['records']
          as Uint8List;
  Future<int> frame() async =>
      ByteData.sublistView(await pixels()).getUint32(12, Endian.little);
  require((opened['reserved'] as int) & 2 == 0, 'Mode defaults OFF');
  final switched = await command(WorldCircuitCommand.optimization(optimized));
  require(
    ((switched['reserved'] as int) & 2 != 0) == optimized,
    'Requested mode acknowledged',
  );
  require(
    (switched['reserved'] as int) & 1 == 0,
    'Mode does not select a mod profile',
  );
  require(
    opened['sourceSha256'] == sha256.convert(original).toString(),
    'Stream identity',
  );
  require(
    (await pixels()).length == 16,
    'Sparse query includes exactly one real pixel',
  );
  require(
    ((await command(WorldCircuitCommand.pixels(1, 1, 1, 1)))['records']
            as Uint8List)
        .isEmpty,
    'Empty pixel query',
  );
  require(await frame() == 0, 'Initial real pixel');
  await command(WorldCircuitCommand.trigger(2, 10, mask: 1, hitSwitch: false));
  await command(WorldCircuitCommand.trigger(3, 9, mask: 2, hitSwitch: false));
  require(await frame() == 0, 'Separate axes do not combine across trips');
  final both = WorldCircuitCommand.trigger(
    2,
    9,
    width: 2,
    height: 2,
    mask: 3,
    hitSwitch: false,
  );
  await command(both);
  require(await frame() == 18, 'One trip toggles native pixel');
  final viewport =
      (await command(WorldCircuitCommand.viewport(3, 10, 1, 1)))['records']
          as Uint8List;
  require(
    viewport.toString() == (await pixels()).toString(),
    'Direct query matches original viewport exactly',
  );
  Future<int> button() async =>
      ByteData.sublistView(
        (await command(WorldCircuitCommand.viewport(2, 20, 1, 1)))['records']
            as Uint8List,
      ).getUint32(12, Endian.little) &
      65535;
  await command(WorldCircuitCommand.trigger(4, 20, mask: 1, hitSwitch: false));
  require(await button() == 36, 'Multipart button toggles once per color');
  await command(WorldCircuitCommand.trigger(4, 20, mask: 3, hitSwitch: false));
  require(await button() == 36, 'Two colors each toggle exactly once');
  await command(
    WorldCircuitCommand.trigger(4, 20, mask: 1, hitSwitch: false, pulses: 3),
  );
  require(await button() == 0, 'Independent pulses reset button dedup');
  var rejected = false;
  try {
    await command(WorldCircuitCommand.pixels(6, 10, 2, 1));
  } catch (_) {
    rejected = true;
  }
  require(
    rejected && await frame() == 18,
    'Invalid bounds preserves live state',
  );
  final saved = await command(WorldCircuitCommand.save());
  final output = WorldCircuitSource.fromMap(saved['worldSource'] as Map);
  require(
    output.sha256 ==
        sha256.convert(File(output.path!).readAsBytesSync()).toString(),
    'Owned output digest matches actual bytes',
  );
  api.dispatch('worldCircuitClose', [id]);
  require(
    File(output.path!).existsSync(),
    'Owned output survives session close',
  );
  opened = await call('worldCircuitOpenSource', [output.toFileMap(), null]);
  id = opened['session'] as int;
  require(await frame() == 18, 'Streamed save reopens lit native pixel');
  require((opened['reserved'] as int) & 2 == 0, 'Reopened mode defaults OFF');
  await command(WorldCircuitCommand.optimization(optimized));
  final beforeSwitch = await pixels();
  await command(WorldCircuitCommand.optimization(!optimized));
  require(
    beforeSwitch.toString() == (await pixels()).toString(),
    'Idle mode switch preserves pixels',
  );
  await command(WorldCircuitCommand.optimization(optimized));
  final before = await pixels();
  final pending = command(
    WorldCircuitCommand.trigger(
      2,
      9,
      width: 2,
      height: 2,
      mask: 3,
      hitSwitch: false,
      pulses: 100000,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 1));
  api.dispatch('worldCircuitCancelOperation', []);
  rejected = false;
  try {
    await pending;
  } catch (_) {
    rejected = true;
  }
  require(rejected, 'Cooperative cancellation reaches running native batch');
  require(
    before.toString() == (await pixels()).toString(),
    'Cancelled batch restores physical pixels',
  );
  final priorButton = await button();
  final pendingButtons = command(
    WorldCircuitCommand.trigger(
      4,
      20,
      mask: 1,
      hitSwitch: false,
      pulses: 100000,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 1));
  api.dispatch('worldCircuitCancelOperation', []);
  rejected = false;
  try {
    await pendingButtons;
  } catch (_) {
    rejected = true;
  }
  require(
    rejected && await button() == priorButton,
    'Cancelled multi-pulse button batch rolls back',
  );
  await command(WorldCircuitCommand.trigger(4, 20, mask: 1, hitSwitch: false));
  require(
    await button() != priorButton,
    'Button accepts a fresh trip after cancellation',
  );
  api.dispatch('worldCircuitClose', [id]);
  api.dispatch('worldCircuitReleaseSource', [output.token]);
  require(
    !File(output.path!).existsSync(),
    'Explicit output release cleans only owned temp file',
  );
  require(
    File(path).readAsBytesSync().toString() == original.toString(),
    'Original source unchanged',
  );
  final live = library.lookupFunction<Uint32 Function(), int Function()>(
    'abc_perf_native_live_bytes',
  )();
  require(live == 0, 'Native owner memory leaked: $live');
  stdout.writeln(
    'PASS (optimization=$optimized): streamed source identity, sparse live pixels/viewport parity, bounds, independent saved-source ownership, cancellation rollback, unchanged source, zero native owners',
  );
}
