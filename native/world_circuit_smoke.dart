import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

void main(List<String> args) {
  final api = NativeWorldCircuitBindings(DynamicLibrary.open(args[0]));
  final bytes = File(args[1]).readAsBytesSync();
  var opened = api.dispatch('worldCircuitOpen', [bytes, null]) as Map;
  var id = opened['session'] as int;
  Map command(WorldCircuitCommand c) =>
      api.dispatch('worldCircuitCommand', [id, c.words, c.records]) as Map;
  int torchFrame() {
    final result =
        command(WorldCircuitCommand.viewport(3, 10, 1, 1))['records']
            as Uint8List;
    final data = ByteData.sublistView(result);
    if (result.length != 16 ||
        data.getUint32(0, Endian.little) != 3 ||
        data.getUint32(4, Endian.little) != 10) {
      throw StateError('Wrong viewport coordinate');
    }
    return data.getUint32(12, Endian.little) & 65535;
  }

  void require(bool ok, String detail) {
    if (!ok) throw StateError(detail);
  }

  try {
    require(
      (opened['stats'] as List)[11] == 2,
      'Expected real timer and torch devices',
    );
    require(torchFrame() == 0, 'Initial torch frame');
    command(WorldCircuitCommand.trigger(2, 10, mask: 1, hitSwitch: false));
    require(torchFrame() == 66, 'Real wire pulse did not toggle torch');
    final saved = command(WorldCircuitCommand.save())['world'] as Uint8List;
    require(bytes.length == File(args[1]).lengthSync(), 'Original changed');
    api.dispatch('worldCircuitClose', [id]);
    opened = api.dispatch('worldCircuitOpen', [saved, null]) as Map;
    id = opened['session'] as int;
    require(
      torchFrame() == 66,
      'Saved circuit state did not survive independent reopen',
    );
    api.dispatch('worldCircuitClose', [id]);
    opened = api.dispatch('worldCircuitOpen', [bytes, null]) as Map;
    id = opened['session'] as int;
    require(torchFrame() == 0, 'Reset did not restore original');
    command(WorldCircuitCommand.trigger(2, 10, mask: 1));
    require(torchFrame() == 0, 'Starting a timer should not immediately pulse');
    command(WorldCircuitCommand.ticks(59));
    require(torchFrame() == 0, 'Timer fired before 60 ticks');
    final advanced = command(WorldCircuitCommand.ticks(1));
    require(torchFrame() == 66, 'Actual timer scheduler failed after 60 ticks');
    require(
      (advanced['stats'] as List)[18] == 60,
      'Incorrect simulation tick count',
    );
    stdout.writeln(
      'PASS: native 64-bit whole-world load, wire pulse, device timer boundary, VM ticks, candidate save/reopen, reset, immutable source',
    );
  } finally {
    api.dispatch('worldCircuitClose', [id]);
  }
  var rejected = false;
  try {
    api.dispatch('worldCircuitOpen', [
      Uint8List.fromList([1, 2, 3]),
      null,
    ]);
  } catch (_) {
    rejected = true;
  }
  require(rejected, 'Malformed WLD was accepted');
  final recovered = api.dispatch('worldCircuitOpen', [bytes, null]) as Map;
  api.dispatch('worldCircuitClose', [recovered['session']]);
  stdout.writeln(
    'PASS: malformed WLD rejected; next valid session recovers cleanly',
  );
}
