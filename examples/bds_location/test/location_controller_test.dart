import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:bds_location/location_controller.dart';

class FakeGateway implements LocationGateway {
  bool enabled = true;
  LocationPermission granted = LocationPermission.whileInUse;
  LocationPermission requested = LocationPermission.denied;
  int starts = 0;
  int requests = 0;
  final stream = StreamController<Position>();
  @override
  Future<bool> serviceEnabled() async => enabled;
  @override
  Future<LocationPermission> permission() async => granted;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return requested;
  }
  @override
  Stream<Position> positions() { starts++; return stream.stream; }
}

Position sample() => Position(latitude: 31.2, longitude: 121.5,
  timestamp: DateTime.now(), accuracy: 8.5, altitude: 0, altitudeAccuracy: 0,
  heading: 0, headingAccuracy: 0, speed: 0, speedAccuracy: 0);

void main() {
  testWidgets('no automatic location; one request, result and cancellation', (tester) async {
    final gateway = FakeGateway();
    final model = LocationController(gateway);
    expect(gateway.starts, 0);
    unawaited(model.locate());
    unawaited(model.locate());
    await tester.pump();
    expect(gateway.starts, 1);
    gateway.stream.add(sample());
    await tester.pump();
    expect(model.position?.latitude, 31.2);
    expect(model.busy, false);
    expect(model.finalElapsed, isNotNull);
    expect(gateway.stream.hasListener, false);
    model.dispose();
    unawaited(gateway.stream.close());
    await tester.pump();
  });
  testWidgets('service disabled offers settings without starting location', (tester) async {
    final gateway = FakeGateway()..enabled = false;
    final model = LocationController(gateway);
    await model.locate();
    expect(model.settingsAction, SettingsAction.location);
    expect(gateway.starts, 0);
    expect(model.busy, false);
    model.dispose();
  });
  testWidgets('denied permission is requested once and can be retried', (tester) async {
    final gateway = FakeGateway()..granted = LocationPermission.denied;
    final model = LocationController(gateway);
    await model.locate();
    expect(gateway.requests, 1);
    expect(gateway.starts, 0);
    expect(model.status, contains('未获得'));
    await model.locate();
    expect(gateway.requests, 2);
    model.dispose();
  });
  testWidgets('permanent denial opens app settings and does not request again', (tester) async {
    final gateway = FakeGateway()..granted = LocationPermission.deniedForever;
    final model = LocationController(gateway);
    await model.locate();
    expect(model.settingsAction, SettingsAction.app);
    expect(gateway.requests, 0);
    expect(gateway.starts, 0);
    model.dispose();
  });
  testWidgets('50 second timeout cancels underlying subscription', (tester) async {
    final gateway = FakeGateway();
    final model = LocationController(gateway);
    unawaited(model.locate());
    await tester.pump();
    await tester.pump(const Duration(seconds: 50));
    expect(model.busy, false);
    expect(model.status, contains('超时'));
    expect(gateway.stream.hasListener, false);
    model.dispose();
  });
  testWidgets('stream error is handled and timers stop', (tester) async {
    final gateway = FakeGateway();
    final model = LocationController(gateway);
    unawaited(model.locate());
    await tester.pump();
    gateway.stream.addError(StateError('test failure'));
    await tester.pump();
    expect(model.status, contains('失败'));
    expect(model.busy, false);
    model.dispose();
  });
  testWidgets('leaving foreground cancels and late data is ignored', (tester) async {
    final gateway = FakeGateway();
    final model = LocationController(gateway);
    unawaited(model.locate());
    await tester.pump();
    model.cancel();
    gateway.stream.add(sample());
    await tester.pump();
    expect(model.position, isNull);
    expect(model.busy, false);
    expect(gateway.stream.hasListener, false);
    model.dispose();
  });
  testWidgets('dispose stops native subscription and ignores pending checks', (tester) async {
    final gateway = FakeGateway();
    final model = LocationController(gateway);
    unawaited(model.locate());
    model.dispose();
    await tester.pump();
    expect(gateway.starts, 0);
    final second = LocationController(gateway);
    unawaited(second.locate());
    await tester.pump();
    second.dispose();
    expect(gateway.stream.hasListener, false);
  });
}
