import 'dart:typed_data';

/// Detached, genuine codec projection. Never edits an existing player handle.
/// Callers must inspect the returned binary, review every loss and verify target
/// gameplay compatibility before any user-confirmed application transaction.
abstract interface class PlayerProjectionBackend {
  Future<Uint8List> projectPlayer(Map<String, Object?> candidate);
}
