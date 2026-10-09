import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

abstract class LocationGateway {
  Future<bool> serviceEnabled();
  Future<LocationPermission> permission();
  Future<LocationPermission> requestPermission();
  Stream<Position> positions();
}

class DeviceLocationGateway implements LocationGateway {
  @override
  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();
  @override
  Future<LocationPermission> permission() => Geolocator.checkPermission();
  @override
  Future<LocationPermission> requestPermission() => Geolocator.requestPermission();
  @override
  Stream<Position> positions() => Geolocator.getPositionStream(
    locationSettings: AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      timeLimit: const Duration(seconds: 50),
    ),
  );
}

enum SettingsAction { none, location, app }

class LocationController extends ChangeNotifier {
  LocationController(this.gateway, {this.timeout = const Duration(seconds: 50)});
  final LocationGateway gateway;
  final Duration timeout;
  bool busy = false;
  bool _disposed = false;
  int _generation = 0;
  String status = '等待定位';
  Position? position;
  Duration elapsed = Duration.zero;
  Duration? finalElapsed;
  SettingsAction settingsAction = SettingsAction.none;
  final Stopwatch _watch = Stopwatch();
  Timer? _ticker;
  Timer? _deadline;
  StreamSubscription<Position>? _subscription;

  bool _active(int generation) => !_disposed && busy && generation == _generation;

  Future<void> locate() async {
    if (_disposed || busy) return;
    final generation = ++_generation;
    busy = true;
    position = null;
    finalElapsed = null;
    elapsed = Duration.zero;
    settingsAction = SettingsAction.none;
    status = '检查定位服务与权限…';
    _watch..reset()..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_active(generation)) {
        elapsed = _watch.elapsed;
        notifyListeners();
      }
    });
    _deadline = Timer(timeout, () {
      if (_active(generation)) _finish('定位超时（50秒），请到开阔处重试');
    });
    notifyListeners();
    try {
      final enabled = await gateway.serviceEnabled();
      if (!_active(generation)) return;
      if (!enabled) {
        settingsAction = SettingsAction.location;
        _finish('系统定位服务已关闭，请开启后重试');
        return;
      }
      var permission = await gateway.permission();
      if (!_active(generation)) return;
      if (permission == LocationPermission.denied) {
        status = '请允许应用在使用期间获取位置';
        notifyListeners();
        permission = await gateway.requestPermission();
        if (!_active(generation)) return;
      }
      if (permission == LocationPermission.deniedForever) {
        settingsAction = SettingsAction.app;
        _finish('定位权限被永久拒绝，请到应用设置中开启');
        return;
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        _finish('未获得定位权限，可点击按钮重试');
        return;
      }
      status = '正在获取位置…';
      notifyListeners();
      _subscription = gateway.positions().listen((value) {
        if (!_active(generation)) return;
        if (!value.latitude.isFinite || !value.longitude.isFinite ||
            !value.accuracy.isFinite || value.accuracy < 0) {
          _finish('定位返回无效数据，请重试');
          return;
        }
        position = value;
        _finish('定位成功（实际精度由设备与环境决定）');
      }, onError: (Object error) {
        if (_active(generation)) _failure(error);
      }, onDone: () {
        if (_active(generation)) _finish('定位已结束，未获得位置，请重试');
      });
    } catch (error) {
      if (_active(generation)) _failure(error);
    }
  }

  void _failure(Object error) {
    if (error is TimeoutException) {
      _finish('定位超时（50秒），请到开阔处重试');
    } else if (error is LocationServiceDisabledException) {
      settingsAction = SettingsAction.location;
      _finish('系统定位服务已关闭，请开启后重试');
    } else if (error is PermissionDeniedException) {
      settingsAction = SettingsAction.app;
      _finish('定位权限不可用，请检查应用设置');
    } else {
      _finish('定位失败，请检查权限与定位服务后重试');
    }
  }

  void cancel() {
    if (busy && !_disposed) _finish('已停止定位，返回页面后可重试');
  }

  void _finish(String message) {
    if (_disposed || !busy) return;
    busy = false;
    _watch.stop();
    elapsed = _watch.elapsed;
    finalElapsed = elapsed;
    status = message;
    _ticker?.cancel();
    _deadline?.cancel();
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _watch.stop();
    _ticker?.cancel();
    _deadline?.cancel();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}
