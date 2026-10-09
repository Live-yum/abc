import 'dart:async';
import 'dart:js_interop';

import 'package:file_selector/file_selector.dart';

import '../engine/world_circuit_backend.dart';
import 'world_circuit_files.dart';

@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external _Input createElement(JSString tag);
  external _Body? get body;
}

extension type _Body(JSObject _) implements JSObject {
  external JSObject appendChild(JSObject child);
}

extension type _Input(JSObject _) implements JSObject {
  external set type(JSString value);
  external set accept(JSString value);
  external set hidden(JSBoolean value);
  external _Files? get files;
  external void addEventListener(JSString type, JSFunction listener);
  external void removeEventListener(JSString type, JSFunction listener);
  external void click();
  external void remove();
}

extension type _Files(JSObject _) implements JSObject {
  external JSNumber get length;
  external _File? item(JSNumber index);
}

extension type _File(JSObject _) implements JSObject {
  external JSString get name;
  external JSNumber get size;
}

/// Keep the browser's original File object. Creating an XFile URL and fetching
/// it back as a Blob would leave full-file response buffering implementation-
/// dependent; this path never creates a response body or a Dart file buffer.
Future<_File?> _pickFile(String extension) {
  final result = Completer<_File?>();
  final input = _document.createElement('input'.toJS)
    ..type = 'file'.toJS
    ..accept = '.$extension'.toJS
    ..hidden = true.toJS;
  late final JSFunction change, cancel, error;
  void cleanup() {
    input.removeEventListener('change'.toJS, change);
    input.removeEventListener('cancel'.toJS, cancel);
    input.removeEventListener('error'.toJS, error);
    input.remove();
  }

  change = ((JSAny? _) {
    if (result.isCompleted) return;
    final files = input.files;
    final file = files == null || files.length.toDartInt == 0
        ? null
        : files.item(0.toJS);
    cleanup();
    result.complete(file);
  }).toJS;
  cancel = ((JSAny? _) {
    if (result.isCompleted) return;
    cleanup();
    result.complete(null);
  }).toJS;
  error = ((JSAny? _) {
    if (result.isCompleted) return;
    cleanup();
    result.completeError(StateError('浏览器无法读取所选文件。'));
  }).toJS;
  input.addEventListener('change'.toJS, change);
  input.addEventListener('cancel'.toJS, cancel);
  input.addEventListener('error'.toJS, error);
  _document.body?.appendChild(input);
  try {
    input.click();
  } catch (e, stack) {
    cleanup();
    result.completeError(e, stack);
  }
  return result.future;
}

@JS('URL.createObjectURL')
external JSString _createUrl(JSObject blob);
@JS('URL.revokeObjectURL')
external void _revokeUrl(JSString url);

class PlatformWorldCircuitFiles implements WorldCircuitFileGateway {
  @override
  Future<WorldCircuitSource?> pick({required bool companion}) async {
    final extension = companion ? 'twld' : 'wld';
    final file = await _pickFile(extension);
    if (file == null) return null;
    final name = file.name.toDart;
    if (!name.toLowerCase().endsWith('.$extension')) {
      throw FormatException('请选择 .$extension 文件。');
    }
    final length = file.size.toDartInt;
    final limit = (companion ? 16 : 1024) * 1024 * 1024;
    if (length < 1 || length > limit) {
      throw FormatException('文件必须为 1 字节到 ${limit ~/ 1048576} MiB。');
    }
    return WorldCircuitSource.blob(blob: file, length: length, name: name);
  }

  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    final blob = source.blob;
    if (blob == null) throw const FormatException('缺少浏览器导出文件。');
    final url = _createUrl(blob as JSObject);
    try {
      await XFile(url.toDart, name: name, length: source.length).saveTo(name);
      return true;
    } finally {
      _revokeUrl(url);
    }
  }
}
