import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Rect;
import 'package:share_plus/share_plus.dart';

import '../engine/world_circuit_backend.dart';
import 'world_circuit_files.dart';

/// Also catches symlink and hard-link aliases of an in-use original. A new
/// destination is resolved through its existing parent directory.
Future<void> ensureSeparateCircuitExport(
  String destination,
  Iterable<WorldCircuitSource> protectedSources,
) async {
  final target = File(destination).absolute;
  Future<String> canonical(File file) async {
    if (await file.exists()) return file.resolveSymbolicLinks();
    final parent = await file.parent.resolveSymbolicLinks();
    return '$parent${Platform.pathSeparator}${file.uri.pathSegments.last}';
  }

  final targetPath = await canonical(target);
  for (final source in protectedSources) {
    if (source.path == null) continue;
    final original = File(source.path!).absolute;
    final samePath = targetPath == await canonical(original);
    final sameFile =
        !samePath &&
        await target.exists() &&
        await original.exists() &&
        await FileSystemEntity.identical(target.path, original.path);
    if (samePath || sameFile) {
      throw const FormatException('请另存为新文件，不能覆盖当前会话正在使用的原始 WLD。');
    }
  }
}

class PlatformWorldCircuitFiles implements WorldCircuitFileGateway {
  final Future<XFile?> Function(List<XTypeGroup>)? picker;
  PlatformWorldCircuitFiles({this.picker});

  @override
  Future<WorldCircuitSource?> pick() async {
    const extension = 'wld';
    final types = [
      XTypeGroup(
        label: extension.toUpperCase(),
        extensions: [extension],
        uniformTypeIdentifiers: ['public.data'],
      ),
    ];
    final file =
        await (picker?.call(types) ?? openFile(acceptedTypeGroups: types));
    if (file == null) return null;
    if (!file.name.toLowerCase().endsWith('.$extension')) {
      throw FormatException('请选择 .$extension 文件。');
    }
    final length = await file.length();
    const limit = 1024 * 1024 * 1024;
    if (length < 1 || length > limit) {
      throw FormatException('文件必须为 1 字节到 ${limit ~/ 1048576} MiB。');
    }
    return WorldCircuitSource.file(
      path: file.path,
      length: length,
      name: file.name,
    );
  }

  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    final path = source.path;
    if (path == null) throw const FormatException('缺少导出文件路径。');
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, name: name)],
          fileNameOverrides: [name],
          title: '导出 $name',
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
        ),
      );
      return result.status != ShareResultStatus.dismissed;
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return false;
    await ensureSeparateCircuitExport(location.path, [
      ...protectedSources,
      source,
    ]);
    await File(path).copy(location.path);
    return true;
  }
}
