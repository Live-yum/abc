import 'dart:io';

import 'map_fixture.dart';

/// Repository-authored binary MAP; never a PNG preview or personal save.
void main(List<String> args) {
  if (args.length != 1) throw ArgumentError('Expected one output MAP path');
  final output = File(args.single);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(
    syntheticMap(chunked: false, width: 4200, height: 1200),
  );
}
