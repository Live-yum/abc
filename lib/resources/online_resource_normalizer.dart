import 'dart:convert';
import 'dart:typed_data';

import '../platform/resource_store.dart';
import 'online_resource_protocol.dart';

/// These catalogs require sources outside the public resource manifest. Their
/// absence must stay visible; a texture or item row cannot establish the rules.
const onlineSupplementalFamilies = <String>{
  'achievements',
  'tile-atlases',
  'wall-atlases',
  'player-conversion-profiles',
  'entity-markers',
  'world-rule-presets',
};

typedef OnlineObjectReader = Future<Uint8List> Function(OnlineObjectRef ref);
typedef OnlineImageReader = Future<Uint8List> Function(OnlineTexture texture);

/// Converts only verified manifest data into the separate local ABCPACK1 format.
/// It never evaluates scripts or infers supplemental rules from textures.
Future<Uint8List> normalizeOnlineResources({
  required OnlineManifest manifest,
  required String authorityEndpoint,
  required String authorityId,
  required OnlineObjectReader readObject,
  required OnlineImageReader readImage,
  required void Function() check,
}) async {
  final families = <String, List<Map<String, Object?>>>{};
  var decodedBudget = manifest.textures.decodedSize;
  var rowCount = 0;
  for (final family in manifest.families.entries) {
    if (onlineSupplementalFamilies.contains(family.key)) continue;
    resourceRequire(
      RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(family.key),
      '目录族名称不受支持',
    );
    final rows = <Map<String, Object?>>[];
    final ids = <String>{};
    for (final shard in family.value) {
      decodedBudget += shard.object.decodedSize;
      resourceRequire(
        decodedBudget <= ResourceStore.maxMetadataBytes,
        '目录解码超过内存上限',
      );
      check();
      final values = parseResourceJson(await readObject(shard.object));
      resourceRequire(
        values is List && values.length == shard.rows,
        '目录分片行数不匹配',
      );
      for (final value in values as List) {
        resourceRequire(
          value is Map<String, dynamic> &&
              (value['id'] is String || value['id'] is int) &&
              '${value['id']}'.isNotEmpty &&
              ids.add('${value['id']}'),
          '目录 ID 无效或重复',
        );
        rows.add(Map<String, Object?>.from(value as Map)..remove('icon'));
      }
      resourceRequire(rows.length <= 50000, '目录超过行数上限');
    }
    rowCount += rows.length;
    resourceRequire(rowCount <= 150000, '目录总行数超过上限');
    families[family.key] = rows;
  }
  final index = {
    for (final row in families.remove('item-index') ?? <Map<String, Object?>>[])
      '${row['id']}': row,
  };
  if (families.containsKey('items')) {
    families['items'] = [
      for (final row in families['items']!) {...?index['${row['id']}'], ...row},
    ];
  }
  // The index establishes research counts; no item or count is invented.
  if (index.isNotEmpty) {
    families['research'] = [
      for (final row in index.values)
        if (row['research'] is int && (row['research'] as int) > 0)
          {...row, 'required': row['research']},
    ];
  }
  final stableRef = manifest.rgb['stableCandidates']!;
  decodedBudget += stableRef.decodedSize;
  resourceRequire(
    decodedBudget <= ResourceStore.maxMetadataBytes,
    '目录解码超过内存上限',
  );
  final stable = parseResourceJson(await readObject(stableRef));
  resourceRequire(stable is List && stable.length <= 50000, '稳定颜色目录无效');
  final colors = <Map<String, Object?>>[];
  for (final row in stable as List) {
    resourceRequire(
      row is List &&
          row.length == 8 &&
          row.every((v) => v is int && v >= 0) &&
          (row[0] == 0 || row[0] == 1) &&
          row[1] <= 65535 &&
          row[3] <= 30 &&
          row[4] <= 255 &&
          row[5] <= 255 &&
          row[6] <= 255 &&
          row[7] == 1,
      '稳定颜色候选无效',
    );
    colors.add({
      'id': colors.length,
      'kind': row[0],
      'type': row[1],
      'variant': row[2],
      'paint': row[3],
      'rgb': row.sublist(4, 7),
      'stable': row[7],
    });
  }
  families['stable-rgb'] = colors;
  final textures = manifest.parseTextures(
    parseResourceJson(await readObject(manifest.textures)),
  );
  final payloads = <String, Uint8List>{};
  var payloadSize = 0;
  void add(String path, Uint8List bytes) {
    if (payloads.containsKey(path)) return;
    payloadSize += bytes.length;
    resourceRequire(
      payloadSize <= ResourceStore.maxPackBytes && payloads.length < 30000,
      '本地资源包超过上限',
    );
    payloads[path] = bytes;
  }

  for (final family in families.entries) {
    for (final row in family.value) {
      check();
      final asset = switch (family.key) {
        'buffs' => 'Buff_${row['id']}',
        'tiles' => 'Tiles_${row['type']}',
        'walls' => 'Wall_${row['type']}',
        'paints' => 'Item_${row['itemId']}',
        _ => row['texture'] ?? row['assetId'],
      };
      final texture = textures[asset];
      if (texture == null) continue;
      final path = 'images/${texture.object.sha256}.png';
      if (!payloads.containsKey(path)) {
        final bytes = await readImage(texture);
        texture.verify(bytes);
        add(path, bytes);
      }
      row['icon'] = path;
    }
  }
  var metadataSize = 0;
  for (final family in families.entries) {
    final bytes = resourceJsonBytes(family.value);
    metadataSize += bytes.length;
    resourceRequire(
      metadataSize <= ResourceStore.maxMetadataBytes,
      '目录编码超过内存上限',
    );
    add('catalog/${family.key}.json', bytes);
  }
  final paths = payloads.keys.toList()..sort();
  var offset = 0;
  final entries = <Map<String, Object>>[];
  for (final path in paths) {
    final bytes = payloads[path]!;
    entries.add({
      'path': path,
      'offset': offset,
      'bytes': bytes.length,
      'sha256': resourceDigest(bytes),
    });
    offset += bytes.length;
  }
  final header = resourceJsonBytes({
    'format': 1,
    'gameVersion': manifest.gameVersion,
    'provenance': {
      'source': 'approved-public-manifest',
      'normalization': 'ABCPACK1-public-v1',
      'authorityEndpoint': authorityEndpoint,
      'authorityId': authorityId,
      'sourceManifestSha256': manifest.sha256,
      'absentSupplementalFamilies': onlineSupplementalFamilies.toList()..sort(),
      'redistributionRights': 'not-granted-by-this-tool',
    },
    'entries': entries,
  });
  resourceRequire(
    header.length <= ResourceStore.maxHeaderBytes &&
        12 + header.length + offset <= ResourceStore.maxPackBytes,
    '本地资源包总大小超过上限',
  );
  final output = Uint8List(12 + header.length + offset);
  output.setRange(0, 8, ascii.encode('ABCPACK1'));
  ByteData.sublistView(output).setUint32(8, header.length, Endian.little);
  output.setRange(12, 12 + header.length, header);
  offset = 12 + header.length;
  for (final path in paths) {
    final bytes = payloads[path]!;
    output.setRange(offset, offset + bytes.length, bytes);
    offset += bytes.length;
  }
  check();
  return output;
}
