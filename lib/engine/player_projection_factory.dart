import 'engine.dart';
import 'player_projection_backend.dart';

PlayerProjectionBackend? createPlayerProjectionBackend(TerraEngine engine) =>
    engine is PlayerProjectionBackend
    ? engine as PlayerProjectionBackend
    : null;
