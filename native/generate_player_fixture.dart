import 'dart:convert';
import 'dart:io';

import 'package:terraforge/engine/player_schema.dart';

void main(List<String> args) {
  if (args.length != 1) {
    throw ArgumentError('Provide an output JSON path');
  }
  final model = blankPlayer('ABC synthetic player');
  final json = jsonEncode(model).replaceFirst(
    '"magicAndType":"244154697780061554"',
    '"magicAndType":244154697780061554',
  );
  File(args.single).writeAsStringSync(json);
  stdout.writeln('Wrote synthetic player semantic model');
}
