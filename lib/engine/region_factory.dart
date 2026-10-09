import 'engine.dart';
import 'region_backend.dart';

RegionBackend? createRegionBackend(TerraEngine engine) =>
    engine is RegionBackend ? engine as RegionBackend : null;
