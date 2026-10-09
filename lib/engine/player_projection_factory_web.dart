import 'engine.dart';
import 'player_projection_backend.dart';
import 'player_projection_web.dart';

PlayerProjectionBackend createPlayerProjectionBackend(TerraEngine engine) =>
    WebPlayerProjectionBackend();
