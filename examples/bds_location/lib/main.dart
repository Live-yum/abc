import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'location_controller.dart';

void main() => runApp(const LocationApp());

class LocationApp extends StatelessWidget {
  const LocationApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'BDS定位',
    theme: ThemeData(colorSchemeSeed: const Color(0xff176b50), useMaterial3: true),
    home: const LocationPage(),
  );
}

class LocationPage extends StatefulWidget {
  const LocationPage({super.key});
  @override
  State<LocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<LocationPage> with WidgetsBindingObserver {
  final controller = LocationController(DeviceLocationGateway());
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      controller.cancel();
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }
  Future<void> _openSettings() async {
    try {
      final opened = controller.settingsAction == SettingsAction.location
          ? await Geolocator.openLocationSettings()
          : await Geolocator.openAppSettings();
      if (!opened && mounted) _settingsFailure();
    } catch (_) {
      if (mounted) _settingsFailure();
    }
  }
  void _settingsFailure() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('无法打开设置，请手动进入系统设置')),
  );
  String seconds(Duration value) => '${(value.inMilliseconds / 1000).toStringAsFixed(1)} 秒';
  Widget field(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Colors.black54)),
      const SizedBox(height: 5),
      SelectableText(value, style: const TextStyle(fontSize: 22)),
    ]),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BDS定位')),
    body: SafeArea(child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('系统高精度定位', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('使用 Android 系统定位服务，并非北斗专用定位。卫星来源由设备决定。'),
          const SizedBox(height: 20),
          Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field('纬度（WGS84）', controller.position?.latitude.toStringAsFixed(6) ?? '—'),
              field('经度（WGS84）', controller.position?.longitude.toStringAsFixed(6) ?? '—'),
              field('水平定位精度（米）', controller.position == null ? '—' : '± ${controller.position!.accuracy.toStringAsFixed(1)} m'),
            ],
          ))),
          const SizedBox(height: 20),
          Text('状态：${controller.status}', style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 12),
          Text('实时时长：${seconds(controller.elapsed)}'),
          Text('最终耗时：${controller.finalElapsed == null ? '—' : seconds(controller.finalElapsed!)}'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: controller.busy ? null : controller.locate,
            icon: const Icon(Icons.my_location),
            label: Text(controller.busy ? '正在定位…' : '开始定位'),
          ),
          if (controller.settingsAction != SettingsAction.none)
            TextButton(onPressed: _openSettings, child: const Text('打开设置')),
          const SizedBox(height: 12),
          const Text('仅点击按钮时定位，最多等待50秒（含权限等待）。离开前台即停止。位置只显示在本机，不上传、不保存。若仅授权大致位置，精度会降低。',
            style: TextStyle(color: Colors.black54, height: 1.5)),
        ]),
      ),
    )),
  );
}
