/// Native/WASM sparse traversal boundary. No Dart simulation fallback is used.
abstract interface class CircuitBackend {
  Future<List<int>> propagate(
    int width,
    int height,
    List<int> cells,
    int x,
    int y,
    int colour,
  );
}
