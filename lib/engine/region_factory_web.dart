import 'engine.dart';
import 'region_backend.dart';
import 'region_backend_web.dart';

RegionBackend createRegionBackend(TerraEngine engine) => WebRegionBackend();
