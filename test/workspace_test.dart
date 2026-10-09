import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/platform/files.dart';

class FakeFiles implements FileGateway {
  PickedFile? next;
  String? saved;
  Uint8List? bytes;
  @override
  Future<PickedFile?> pick(String kind) async => next;
  @override
  Future<bool> save(String name, Uint8List data) async {
    saved = name;
    bytes = data;
    return true;
  }
}

class FakeEngine implements TerraEngine {
  int serial = 0;
  bool fail = false;
  final handles = <int, Uint8List>{};
  @override
  Future<EngineDocument> open(Uint8List bytes, {required String kind}) async {
    if (bytes.isEmpty) {
      throw const EngineException('bad file');
    }
    final id = ++serial;
    handles[id] = Uint8List.fromList(bytes);
    return EngineDocument(id, kind, {});
  }

  @override
  Future<Map<String, dynamic>> inspect(EngineDocument doc) async => {
    'name': 'world',
    'version': 326,
  };
  @override
  Future<void> mutate(
    EngineDocument doc,
    String operation,
    Map<String, dynamic> args,
  ) async {
    if (fail) {
      throw const EngineException('rejected');
    }
    handles[doc.handle] = Uint8List.fromList([9, 2]);
  }

  @override
  Future<Uint8List> save(EngineDocument doc) async => handles[doc.handle]!;
  @override
  Future<Uint8List?> preview(EngineDocument doc) async => null;
  @override
  Future<void> close(EngineDocument doc) async {
    handles.remove(doc.handle);
  }
}

void main() {
  test('cancel import creates no records', () async {
    final w = Workspace(engine: FakeEngine(), files: FakeFiles());
    await w.dispatch('import');
    expect(w.view.files, isEmpty);
    expect(w.view.busy, false);
  });
  test('failed edit leaves original active and no staged success', () async {
    final engine = FakeEngine(),
        files = FakeFiles()
          ..next = PickedFile('a.wld', Uint8List.fromList([1, 2]));
    final w = Workspace(engine: engine, files: files);
    await w.dispatch('import');
    engine.fail = true;
    await w.dispatch('stageWorld', {'field': 'name', 'value': 'x'});
    expect(w.view.error, 'rejected');
    expect(w.view.stagedCount, 0);
    await w.dispatch('export', {'kind': 'world'});
    expect(files.saved, 'a_terraforge.wld');
    expect(files.bytes, [1, 2]);
    expect(engine.handles.length, 1);
  });
  test('actual edited bytes validate and export as copy', () async {
    final engine = FakeEngine(),
        files = FakeFiles()
          ..next = PickedFile('a.wld', Uint8List.fromList([1, 2]));
    final w = Workspace(engine: engine, files: files);
    await w.dispatch('import');
    await w.dispatch('stageWorld', {'field': 'name', 'value': 'x'});
    expect(w.view.error, isEmpty);
    expect(w.view.stagedCount, 1);
    await w.dispatch('export', {'kind': 'world'});
    expect(files.bytes, [9, 2]);
    expect(engine.handles.length, 1);
  });
  test('unsupported cloud does not fabricate success', () async {
    final w = Workspace(engine: FakeEngine(), files: FakeFiles());
    await w.dispatch('generate', {'name': 'x'});
    expect(w.view.error, contains('未连接'));
    expect(w.view.files, isEmpty);
  });
}
