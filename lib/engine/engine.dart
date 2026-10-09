import 'dart:typed_data';

class EngineDocument {
  final int handle;
  final String kind;
  final Map<String, dynamic> metadata;
  const EngineDocument(this.handle, this.kind, this.metadata);
}

abstract class TerraEngine {
  Future<EngineDocument> open(Uint8List bytes, {required String kind});
  Future<Map<String, dynamic>> inspect(EngineDocument doc);
  Future<void> mutate(
    EngineDocument doc,
    String operation,
    Map<String, dynamic> args,
  );
  Future<Uint8List> save(EngineDocument doc);
  Future<Uint8List?> preview(EngineDocument doc);
  Future<void> close(EngineDocument doc);
}

class EngineException implements Exception {
  final String message;
  final int? code;
  const EngineException(this.message, [this.code]);
  @override
  String toString() => message;
}

abstract interface class CreatablePlayerEngine {
  Future<EngineDocument> createPlayer(String name);
}
