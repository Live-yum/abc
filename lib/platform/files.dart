import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Rect;
import 'package:share_plus/share_plus.dart';

class PickedFile {
  final String name;
  final Uint8List bytes;
  const PickedFile(this.name, this.bytes);
}

abstract class FileGateway {
  Future<PickedFile?> pick(String kind);
  Future<bool> save(String name, Uint8List bytes);
}

/// Mobile export uses the system share sheet (including Save to Files), because
/// file_selector deliberately has no save-location implementation on iOS/Android.
class PlatformFiles implements FileGateway {
  final TargetPlatform? platform;
  final Future<XFile?> Function(List<XTypeGroup>)? picker;
  final Future<ShareResult> Function(ShareParams)? share;
  PlatformFiles({this.platform, this.picker, this.share});
  TargetPlatform get _platform => platform ?? defaultTargetPlatform;
  @override
  Future<PickedFile?> pick(String kind) async {
    final extensions = switch (kind) {
      'world' => ['wld', 'bak'],
      'player' => ['plr', 'bak'],
      'image' => ['png', 'jpg', 'jpeg', 'webp'],
      'achievements' => ['dat', 'bak'],
      'project' => ['json'],
      'resources' => ['abcpack'],
      _ => ['wld', 'plr', 'dat', 'bak', 'json'],
    };
    final types = [
      XTypeGroup(
        label: kind,
        extensions: extensions,
        uniformTypeIdentifiers: kind == 'image'
            ? ['public.image']
            : ['public.data'],
      ),
    ];
    final file =
        await (picker?.call(types) ?? openFile(acceptedTypeGroups: types));
    if (file == null) {
      return null;
    }
    final extension = file.name.toLowerCase().split('.').last;
    if (!extensions.contains(extension)) {
      throw const FormatException('所选文件扩展名不符合当前导入类型。');
    }
    final limit = kind == 'resources'
        ? 256 * 1024 * 1024
        : kind == 'world' || kind == 'save'
        ? 128 * 1024 * 1024
        : 32 * 1024 * 1024;
    if (await file.length() > limit) {
      throw FormatException('文件超过本机处理上限（${limit ~/ 1048576} MiB）。');
    }
    return PickedFile(file.name, await file.readAsBytes());
  }

  @override
  Future<bool> save(String name, Uint8List bytes) async {
    final file = XFile.fromData(
      bytes,
      name: name,
      mimeType: 'application/octet-stream',
    );
    if (kIsWeb) {
      await file.saveTo(name);
      return true;
    }
    if (_platform == TargetPlatform.android ||
        _platform == TargetPlatform.iOS) {
      final params = ShareParams(
        files: [file],
        fileNameOverrides: [name],
        title: '导出 $name',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      );
      final result =
          await (share?.call(params) ?? SharePlus.instance.share(params));
      return result.status != ShareResultStatus.dismissed;
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) {
      return false;
    }
    await file.saveTo(location.path);
    return true;
  }
}
