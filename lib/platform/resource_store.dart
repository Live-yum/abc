import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/resource_catalog.dart';

/// ABCPACK1 is deliberately uncompressed. It cannot contain ZIP entries,
/// symlinks, executable objects, or filesystem extraction instructions.
class ResourceStore {
  static const maxPackBytes = 256 * 1024 * 1024;
  static const maxHeaderBytes = 8 * 1024 * 1024;
  static const maxMetadataBytes = 64 * 1024 * 1024;
  final Uint8List _bytes;
  final Map<String, (int, int)> _entries;
  final ResourceCatalog catalog;
  final String packSha256;
  ResourceStore._(this._bytes, this._entries, this.catalog, this.packSha256);

  static ResourceStore importPack(Uint8List input) {
    void require(bool valid, String error) {
      if (!valid) throw FormatException(error);
    }

    require(input.length >= 12 && input.length <= maxPackBytes, '资源包大小无效');
    require(
      ascii.decode(input.sublist(0, 8), allowInvalid: true) == 'ABCPACK1',
      '仅支持 ABCPACK1 本地资源包',
    );
    final headerLength = ByteData.sublistView(input)
        .getUint32(8, Endian.little);
    require(
      headerLength > 0 &&
          headerLength <= maxHeaderBytes &&
          12 + headerLength <= input.length,
      '资源清单长度无效',
    );
    final header = jsonDecode(
      utf8.decode(input.sublist(12, 12 + headerLength)),
    );
    require(
      header is Map<String, dynamic> && header['format'] == 1,
      '资源清单版本无效',
    );
    final entries = header['entries'];
    require(
      entries is List && entries.isNotEmpty && entries.length <= 30000,
      '资源索引数量无效',
    );
    require(
      header['gameVersion'] is String &&
          (header['gameVersion'] as String).isNotEmpty &&
          header['provenance'] is Map,
      '资源来源或游戏版本缺失',
    );
    final paths = <String, (int, int)>{};
    var offset = 0;
    var metadataBytes = 0;
    final base = 12 + headerLength;
    final pathPattern = RegExp(
      r'^(catalog/[a-z][a-z0-9-]{0,63}\.json|images/[a-f0-9]{64}\.png)$',
    );
    for (final entry in entries as List) {
      require(entry is Map, '资源条目无效');
      final path = entry['path'];
      final size = entry['bytes'];
      final position = entry['offset'];
      final hash = entry['sha256'];
      require(
        path is String &&
            (pathPattern.firstMatch(path)?.group(0) == path) &&
            !paths.containsKey(path),
        '资源路径无效或重复',
      );
      require(
        size is int &&
            size > 0 &&
            size <= maxMetadataBytes &&
            position is int &&
            position == offset &&
            offset + size <= input.length - base,
        '资源范围无效',
      );
      require(
        hash is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(hash),
        '资源 SHA256 无效',
      );
      final data = Uint8List.sublistView(
        input,
        base + offset,
        base + offset + (size as int),
      );
      require(sha256.convert(data).toString() == hash, '资源 SHA256 不匹配：$path');
      if ((path as String).startsWith('catalog/')) {
        metadataBytes += size;
        require(metadataBytes <= maxMetadataBytes, '资源目录超过内存上限');
      } else {
        require(
          size <= 8 * 1024 * 1024 &&
              data.length >= 24 &&
              data[0] == 137 &&
              ascii.decode(data.sublist(1, 4), allowInvalid: true) == 'PNG' &&
              data[4] == 13 &&
              data[5] == 10 &&
              data[6] == 26 &&
              data[7] == 10 &&
              ascii.decode(data.sublist(12, 16), allowInvalid: true) == 'IHDR',
          '图标 PNG 无效',
        );
        final png = ByteData.sublistView(data);
        final width = png.getUint32(16), height = png.getUint32(20);
        require(
          width > 0 &&
              height > 0 &&
              width <= 8192 &&
              height <= 8192 &&
              width * height <= 4194304,
          '图标解码尺寸超过上限',
        );
        require(path == 'images/$hash.png', '图标名称与 SHA256 不匹配');
      }
      paths[path] = (base + offset, size);
      offset += size;
    }
    require(base + offset == input.length, '资源包包含未登记数据');
    final families = <String, List<CatalogEntry>>{};
    var rowCount = 0;
    for (final entry in paths.entries.where(
      (e) => e.key.startsWith('catalog/'),
    )) {
      final family = entry.key.substring(8, entry.key.length - 5);
      final decoded = jsonDecode(
        utf8.decode(
          Uint8List.sublistView(
            input,
            entry.value.$1,
            entry.value.$1 + entry.value.$2,
          ),
        ),
      );
      require(decoded is List && decoded.length <= 50000, '目录格式无效');
      final ids = <String>{};
      final rows = <CatalogEntry>[];
      for (final raw in decoded as List) {
        require(
          raw is Map<String, dynamic> &&
              (raw['id'] is String || raw['id'] is int),
          '目录 ID 缺失',
        );
        final row = CatalogEntry(family, Map<String, Object?>.from(raw));
        require(row.id.isNotEmpty && ids.add(row.id), '目录 ID 重复');
        require(
          row.fields['icon'] == null ||
              row.fields['icon'] is String &&
                  paths.containsKey(row.fields['icon']) &&
                  (row.fields['icon'] as String).startsWith('images/'),
          '目录图标引用无效',
        );
        rows.add(row);
      }
      rowCount += rows.length;
      require(rowCount <= 150000, '目录记录数量超过上限');
      families[family] = rows;
    }
    require(families.isNotEmpty, '资源包无目录');
    // Retain an owned copy: callers cannot mutate already-verified icon bytes.
    return ResourceStore._(
      Uint8List.fromList(input),
      Map.unmodifiable(paths),
      ResourceCatalog(
        gameVersion: header['gameVersion'] as String,
        provenance: Map<String, Object?>.from(header['provenance'] as Map),
        families: families,
      ),
      sha256.convert(input).toString(),
    );
  }

  /// Materializes only requested encoded PNG bytes. Flutter decodes visible rows.
  Uint8List? iconBytes(CatalogEntry row) {
    final location = _entries[row.iconPath];
    if (location == null) return null;
    return Uint8List.sublistView(
      _bytes,
      location.$1,
      location.$1 + location.$2,
    ).asUnmodifiableView();
  }
}
