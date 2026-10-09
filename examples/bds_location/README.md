# BDS定位 Android

独立 Flutter 应用，标题沿用 BDS定位；调用 Android 系统高精度定位，并非北斗专用，不选择卫星星座。

- 点击开始后才申请前台位置权限；纬度/经度为 WGS84，水平精度以米显示。
- 显示实时等待时长和本次最终耗时。50 秒总超时包含服务/权限检查等待。
- 获取一个位置后立即停止监听；退到后台、超时或销毁页面时取消；不自动重试。
- 处理服务关闭、普通拒绝、永久拒绝、定位异常和重复点击。Android 12+ 可选择大致位置。
- 不使用后台位置、前台服务、广告或 API 密钥；不保存/上传位置；正式 APK 明确移除 INTERNET 权限。
- 高精度是请求级别，无法保证实际定位误差；应以返回的水平精度为准。室内或首次定位可能超时。

## 构建

Flutter 3.47.6 / Dart 3.13.5，geolocator 14.1.1（依赖锁定文件由第一次构建产生并随完整源码归档）。

首次生成 Android 脚手架前备份 lib、test 和 pubspec.yaml；`flutter create --platforms=android --org=app.local --project-name=bds_location .` 后还原它们，删除默认 test/widget_test.dart。
执行 `python3 ci/prepare_android.py`，然后 `flutter pub get`、`flutter analyze`、`flutter test`、`flutter build apk --release --split-per-abi`。
编译 SDK 使用 Flutter 模板的版本（至少 35）。

交付的是 release 优化、测试签名 APK，不是应用商店/生产签名版本。不同临时签名的后续版本可能需先卸载旧版。设备可能要求允许从浏览器/文件管理器安装；只在确实要安装本文件时按系统提示操作。

## 测试边界

自动测试覆盖控制器的成功、拒绝、永久拒绝、服务关闭、50 秒超时、错误、重复点击、退出和销毁。自动测试不等同真实 GPS 成功；实际权限弹窗、系统定位与卫星环境需在真机验收。

官方文档：
- https://pub.dev/packages/geolocator
- https://pub.dev/documentation/geolocator/latest/geolocator/Geolocator/getPositionStream.html
- https://pub.dev/documentation/geolocator_android/latest/geolocator_android/AndroidSettings-class.html
