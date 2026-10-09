// Original offline integration fixture transformer. Run after generate_world_fixture.py.
import 'dart:io';

import 'package:terraforge/domain/world_stamp.dart';

void main(List<String> args) {
  if (args.length != 2) throw ArgumentError('input.wld output.wld required');
  final source = File(args[0]).readAsBytesSync();
  final output = WorldStamp.apply(
    source,
    x: 2,
    y: 10,
    width: 2,
    height: 2,
    overwrite: true,
    cells: [
      const StampCell(block: 0, blockPaint: 3),
      null,
      const StampCell(wall: 1, wallPaint: 4),
      const StampCell(block: -1),
    ],
  );
  File(args[1]).writeAsBytesSync(output);
  stdout.writeln(
    'Stamped ${source.length} -> ${output.length} bytes; source preserved',
  );
}
