import 'dart:convert';
import 'dart:js_interop';

@JS('mapMemoryFixture')
external JSString get _fixture;
@JS('mapMemorySnapshot')
external JSString _snapshot();
String fixture(List<String> args) => _fixture.toDart;
Map<String, Object?> memory() =>
    Map<String, Object?>.from(jsonDecode(_snapshot().toDart) as Map);
