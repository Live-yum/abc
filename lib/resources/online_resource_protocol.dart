// Contract port of viewer-app infrastructure/assets/protocol.mjs and
// authority.mjs. See docs/ONLINE_RESOURCES.md for source provenance and limits.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const onlineManifestMaxBytes = 2 * 1024 * 1024;
const onlineApprovalMaxBytes = 1024 * 1024;
const onlineObjectMaxBytes = 128 * 1024 * 1024;
final onlineHashPattern = RegExp(r'^[a-f0-9]{64}$');

String resourceDigest(List<int> bytes) => sha256.convert(bytes).toString();
Uint8List resourceJsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void resourceRequire(bool valid, String message) {
  if (!valid) throw FormatException(message);
}

bool _safeInt(Object? value, int max) =>
    value is int && value >= 0 && value <= max;

/// Preserve the reference's integers beyond JavaScript's exact range as text.
/// Catalog identifiers therefore stay identical on native and Web.
Object? parseResourceJson(Uint8List bytes) {
  final text = utf8.decode(bytes);
  final number = RegExp(
    r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
  );
  final out = StringBuffer();
  var quoted = false, escaped = false;
  for (var i = 0; i < text.length;) {
    final c = text[i];
    if (quoted) {
      out.write(c);
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
      i++;
      continue;
    }
    if (c == '"') {
      quoted = true;
      out.write(c);
      i++;
      continue;
    }
    final match = number.matchAsPrefix(text, i);
    if (match == null) {
      out.write(c);
      i++;
      continue;
    }
    final token = match.group(0)!;
    final digits = token.startsWith('-') ? token.substring(1) : token;
    final large =
        !token.contains(RegExp(r'[.eE]')) &&
        (digits.length > 16 ||
            digits.length == 16 && digits.compareTo('9007199254740991') > 0);
    out.write(large ? '"$token"' : token);
    i = match.end;
  }
  return jsonDecode(out.toString());
}

Map<String, dynamic> _map(Object? value, String label) {
  resourceRequire(value is Map<String, dynamic>, '$label 格式无效');
  return value as Map<String, dynamic>;
}

class OnlineObjectRef {
  OnlineObjectRef._(
    this.path,
    this.sha256,
    this.bytes,
    this.mediaType,
    this.decodedBytes,
    this.raw,
  );
  final String path, sha256, mediaType;
  final int bytes;
  final int? decodedBytes;
  final Map<String, dynamic> raw;
  bool get compressed => decodedBytes != null;
  int get decodedSize => decodedBytes ?? bytes;

  factory OnlineObjectRef.parse(Object? input, {bool delivery = false}) {
    final ref = _map(input, '资源对象');
    final path = ref['path'], sha = ref['sha256'];
    final match = path is String
        ? RegExp(
            r'^objects/([a-f0-9]{2})/([a-f0-9]{64})\.(json\.gz|srgb\.gz|txci\.gz|zip(?:\.gz)?|png)$',
          ).firstMatch(path)
        : null;
    resourceRequire(
      sha is String &&
          onlineHashPattern.hasMatch(sha) &&
          match != null &&
          match[1] == sha.substring(0, 2) &&
          match[2] == sha,
      '资源对象路径或摘要无效',
    );
    final media = ref['mediaType'];
    final bundle = media == 'application/zip';
    final limit = delivery
        ? 32 * 1024 * 1024
        : bundle
        ? 16 * 1024 * 1024
        : onlineObjectMaxBytes;
    resourceRequire(
      _safeInt(ref['bytes'], limit) && ref['bytes'] > 0,
      '资源对象大小无效',
    );
    final encoded = ref['encoding'];
    resourceRequire(
      (encoded == null || encoded == 'gzip') &&
          (encoded != null) == (path as String).endsWith('.gz'),
      '资源对象编码与路径不一致',
    );
    resourceRequire(
      encoded != null
          ? _safeInt(ref['decodedBytes'], limit) && ref['decodedBytes'] > 0
          : !ref.containsKey('decodedBytes'),
      '资源解压大小无效',
    );
    resourceRequire(
      media is String &&
          media.length <= 80 &&
          (!bundle || RegExp(r'\.zip(?:\.gz)?$').hasMatch(path)),
      '资源媒体类型无效',
    );
    resourceRequire(
      !delivery || encoded == null && path.endsWith('.zip') && bundle,
      '资源整包必须是未压缩封装的 ZIP',
    );
    return OnlineObjectRef._(
      path,
      sha as String,
      ref['bytes'] as int,
      media as String,
      ref['decodedBytes'] as int?,
      Map.unmodifiable(ref),
    );
  }

  Uint8List decode(Uint8List wire) {
    resourceRequire(
      wire.length == bytes && resourceDigest(wire) == sha256,
      '资源对象 SHA-256 或字节数不匹配',
    );
    if (!compressed) return wire;
    resourceRequire(
      wire.length >= 20 &&
          wire[0] == 31 &&
          wire[1] == 139 &&
          wire[2] == 8 &&
          wire[3] & 0xe0 == 0,
      '资源 gzip 头无效',
    );
    final sink = _BoundedOutput(decodedBytes!);
    // Force the same bounded Dart decoder on every platform. The native
    // archive convenience decoder accumulates chunks before its sink callback.
    final ok = GZipDecoderWeb().decodeStream(
      InputMemoryStream(wire),
      sink,
      verify: true,
    );
    resourceRequire(ok && sink.length == decodedBytes, '资源 gzip 解压校验失败');
    return sink.getBytes();
  }

  Object? validateDecoded(Uint8List bytes) {
    if (path.endsWith('.json.gz')) {
      final json = parseResourceJson(bytes);
      resourceRequire(json is Map || json is List, '资源 JSON 结构无效');
      return json;
    }
    final view = ByteData.sublistView(bytes);
    if (path.endsWith('.srgb.gz')) {
      resourceRequire(
        bytes.length >= 12 + 65537 * 4 &&
            ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'SRGB',
        'SRGB 格式无效',
      );
      resourceRequire(
        bytes.length == 12 + 65537 * 4 + view.getUint32(8, Endian.little) * 5,
        'SRGB 长度无效',
      );
    }
    if (path.endsWith('.txci.gz')) {
      resourceRequire(
        bytes.length >= 44 &&
            ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'TXCI' &&
            view.getUint16(4, Endian.little) == 3 &&
            view.getUint16(6, Endian.little) == 8,
        'TXCI 格式或版本无效',
      );
      var previous = 44;
      for (final at in [20, 24, 28, 32, 36]) {
        final current = view.getUint32(at, Endian.little);
        resourceRequire(
          current >= previous && current <= bytes.length,
          'TXCI 偏移无效',
        );
        previous = current;
      }
    }
    return null;
  }
}

class _BoundedOutput extends OutputStream {
  _BoundedOutput(int size)
    : _data = Uint8List(size),
      super(byteOrder: ByteOrder.littleEndian);
  final Uint8List _data;
  int _length = 0;
  @override
  int get length => _length;
  @override
  void clear() => _length = 0;
  @override
  void flush() {}
  @override
  void writeByte(int value) {
    resourceRequire(_length < _data.length, '资源解压超过声明大小');
    _data[_length++] = value;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final n = length ?? bytes.length;
    resourceRequire(
      n >= 0 && n <= bytes.length && _length + n <= _data.length,
      '资源解压超过声明大小',
    );
    _data.setRange(_length, _length + n, bytes);
    _length += n;
  }

  @override
  void writeStream(InputStream stream) => writeBytes(stream.toUint8List());
  @override
  Uint8List subset(int start, [int? end]) {
    final a = start < 0 ? _length + start : start;
    final b = end == null
        ? _length
        : end < 0
        ? _length + end
        : end;
    resourceRequire(a >= 0 && b >= a && b <= _length, '资源解压窗口无效');
    return Uint8List.sublistView(_data, a, b);
  }
}

class OnlineFamilyShard {
  OnlineFamilyShard(this.rows, this.object);
  final int rows;
  final OnlineObjectRef object;
}

class OnlineManifest {
  OnlineManifest._(
    this.sha256,
    this.gameVersion,
    this.families,
    this.textures,
    this.rgb,
    this.objects,
    this.raw,
  );
  final String sha256, gameVersion;
  final Map<String, List<OnlineFamilyShard>> families;
  final OnlineObjectRef textures;
  final Map<String, OnlineObjectRef> rgb;
  final List<OnlineObjectRef> objects;
  final Map<String, dynamic> raw;

  factory OnlineManifest.parse(Uint8List bytes, String sha) {
    resourceRequire(
      onlineHashPattern.hasMatch(sha) &&
          bytes.isNotEmpty &&
          bytes.length <= onlineManifestMaxBytes &&
          resourceDigest(bytes) == sha,
      '资源清单 SHA-256 或大小无效',
    );
    final data = _map(parseResourceJson(bytes), '资源清单');
    resourceRequire(
      data['schema'] == 1 &&
          data['gameVersion'] is String &&
          (data['gameVersion'] as String).isNotEmpty &&
          data['missing'] is List &&
          (data['missing'] as List).isEmpty,
      '资源清单不完整',
    );
    final found = <String, OnlineObjectRef>{};
    OnlineObjectRef add(Object? value) {
      final ref = OnlineObjectRef.parse(value);
      final previous = found[ref.path];
      resourceRequire(
        previous == null || jsonEncode(previous.raw) == jsonEncode(ref.raw),
        '资源对象引用冲突',
      );
      found[ref.path] = ref;
      return ref;
    }

    final textures = add(data['textures']);
    final families = <String, List<OnlineFamilyShard>>{};
    for (final entry in _map(data['families'], '资源族').entries) {
      resourceRequire(
        RegExp(r'^[a-z0-9-]{1,80}$').hasMatch(entry.key) &&
            entry.value is List &&
            (entry.value as List).length <= 100000,
        '资源族结构无效',
      );
      families[entry.key] = List.unmodifiable(
        (entry.value as List).map((part) {
          final shard = _map(part, '资源分片');
          resourceRequire(_safeInt(shard['rows'], 100000), '资源分片行数无效');
          return OnlineFamilyShard(shard['rows'] as int, add(shard['object']));
        }),
      );
    }
    final rgb = <String, OnlineObjectRef>{};
    final rgbInput = _map(data['rgb'], 'RGB');
    for (final key in ['candidates', 'stableCandidates', 'srgb', 'txci']) {
      resourceRequire(rgbInput.containsKey(key), 'RGB 资源缺失');
    }
    for (final entry in rgbInput.entries) {
      rgb[entry.key] = add(entry.value);
    }
    final bundles = data['imageBundles'] == null
        ? <String, dynamic>{}
        : _map(data['imageBundles'], '图片包');
    for (final entry in bundles.entries) {
      resourceRequire(RegExp(r'^[a-f0-9]{2}$').hasMatch(entry.key), '图片包分桶无效');
      final ref = add(entry.value);
      resourceRequire(ref.mediaType == 'application/zip', '图片包媒体类型无效');
    }
    if (data['textureScope'] != null) {
      final scope = _map(data['textureScope'], '纹理范围');
      resourceRequire(
        scope['mode'] == 'consumer-closure' &&
            _safeInt(scope['sourceCount'], 100000) &&
            _safeInt(scope['selectedCount'], 100000) &&
            scope['selectedCount'] > 0 &&
            scope['selectedCount'] <= scope['sourceCount'] &&
            data['sources'] is Map &&
            scope['sourceCount'] == data['sources']['textureFiles'] &&
            data['capabilities'] is Map &&
            data['capabilities']['publicTextureClosure'] is Map &&
            data['capabilities']['publicTextureClosure']['available'] == true &&
            (families['player-texture-bindings']?.isNotEmpty ?? false),
        '公开纹理闭包声明无效',
      );
    }
    if (data['deliveryPacks'] != null) {
      final packs = data['deliveryPacks'];
      resourceRequire(
        bundles.isNotEmpty &&
            packs is List &&
            packs.isNotEmpty &&
            packs.length <= 1024,
        '资源整包目录无效',
      );
      final seen = <String>{}, paths = <String>{};
      for (final pack in packs as List) {
        final part = _map(pack, '资源整包');
        final ref = OnlineObjectRef.parse(part['object'], delivery: true);
        final members = part['members'];
        resourceRequire(
          !found.containsKey(ref.path) &&
              paths.add(ref.path) &&
              members is List &&
              members.isNotEmpty &&
              members.length <= 65534,
          '资源整包成员目录无效',
        );
        var size = 0;
        for (final path in members as List) {
          resourceRequire(
            path is String && found.containsKey(path) && seen.add(path),
            '资源整包含重复或未知成员',
          );
          size += found[path]!.bytes;
        }
        resourceRequire(size < ref.bytes, '资源整包大小与成员不符');
      }
      resourceRequire(seen.length == found.length, '资源整包缺少成员');
    }
    final objects = found.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return OnlineManifest._(
      sha,
      data['gameVersion'] as String,
      Map.unmodifiable(families),
      textures,
      Map.unmodifiable(rgb),
      List.unmodifiable(objects),
      Map.unmodifiable(data),
    );
  }

  Map<String, OnlineTexture> parseTextures(Object? decoded) {
    final data = _map(decoded, '纹理目录');
    final scope = raw['textureScope'];
    final count = scope is Map
        ? scope['selectedCount']
        : (raw['sources'] as Map?)?['textureFiles'];
    resourceRequire(data.length == count, '纹理数量与来源声明不符');
    final result = <String, OnlineTexture>{}, seen = <String, OnlineTexture>{};
    final buckets = <String>{};
    for (final entry in data.entries) {
      final value = _map(entry.value, '纹理');
      resourceRequire(
        entry.key.isNotEmpty &&
            entry.key.length <= 600 &&
            _safeInt(value['width'], 16384) &&
            value['width'] > 0 &&
            _safeInt(value['height'], 16384) &&
            value['height'] > 0,
        '纹理尺寸或键无效',
      );
      final ref = OnlineObjectRef.parse(value['object']);
      resourceRequire(
        ref.path.endsWith('.png') && ref.mediaType == 'image/png',
        '纹理对象不是 PNG',
      );
      final texture = OnlineTexture(
        value['width'] as int,
        value['height'] as int,
        ref,
      );
      final previous = seen[ref.sha256];
      resourceRequire(
        previous == null ||
            previous.width == texture.width &&
                previous.height == texture.height,
        '共享纹理尺寸冲突',
      );
      seen[ref.sha256] = result[entry.key] = texture;
      buckets.add(ref.sha256.substring(0, 2));
    }
    final bundles = raw['imageBundles'];
    if (bundles is Map && bundles.isNotEmpty) {
      resourceRequire(
        bundles.length == buckets.length && buckets.every(bundles.containsKey),
        '图片包分桶不完整',
      );
    }
    return Map.unmodifiable(result);
  }
}

class OnlineTexture {
  OnlineTexture(this.width, this.height, this.object);
  final int width, height;
  final OnlineObjectRef object;
  void verify(Uint8List bytes) {
    object.decode(bytes);
    resourceRequire(
      bytes.length >= 33 &&
          bytes.take(8).join(',') == '137,80,78,71,13,10,26,10' &&
          ascii.decode(bytes.sublist(12, 16), allowInvalid: true) == 'IHDR',
      '图片 PNG 无效',
    );
    final data = ByteData.sublistView(bytes);
    resourceRequire(
      data.getUint32(16) == width &&
          data.getUint32(20) == height &&
          width <= 8192 &&
          height <= 8192 &&
          width * height <= 4194304 &&
          bytes.length <= 8 * 1024 * 1024,
      '图片尺寸或解码大小超过上限',
    );
  }
}

class OnlineApproval {
  OnlineApproval._(
    this.authorityId,
    this.sequence,
    this.activeSha256,
    this.gameVersion,
    this.revoked,
    this.stateSha256,
  );
  final String authorityId, sequence, stateSha256;
  final String? activeSha256, gameVersion;
  final List<String> revoked;
  Map<String, Object?> get canonical => {
    'active': activeSha256 == null
        ? null
        : {'gameVersion': gameVersion, 'manifestSha256': activeSha256},
    'authorityId': authorityId,
    'channel': 'stable',
    'revokedManifestSha256': revoked,
    'schema': 1,
    'sequence': sequence,
  };
  Map<String, Object?> toJson() => {...canonical, 'stateSha256': stateSha256};
  factory OnlineApproval.parse(Uint8List bytes) {
    resourceRequire(
      bytes.isNotEmpty && bytes.length <= onlineApprovalMaxBytes,
      '审批状态大小无效',
    );
    final envelope = _map(jsonDecode(utf8.decode(bytes)), '审批状态');
    final data = envelope['code'] == 0
        ? _map(envelope['data'], '审批数据')
        : envelope;
    final id = data['authorityId'],
        sequence = data['sequence'],
        revoked = data['revokedManifestSha256'];
    resourceRequire(
      data['schema'] == 1 &&
          id is String &&
          RegExp(r'^[-a-zA-Z0-9_.:]{1,160}$').hasMatch(id) &&
          data['channel'] == 'stable' &&
          sequence is String &&
          RegExp(r'^(0|[1-9][0-9]{0,79})$').hasMatch(sequence) &&
          revoked is List &&
          data['stateSha256'] is String &&
          onlineHashPattern.hasMatch(data['stateSha256']),
      '审批状态格式无效',
    );
    String? previous;
    for (final sha in revoked as List) {
      resourceRequire(
        sha is String &&
            onlineHashPattern.hasMatch(sha) &&
            (previous == null || sha.compareTo(previous) > 0),
        '撤销记录必须完整排序且唯一',
      );
      previous = sha as String;
    }
    final active = data['active'];
    resourceRequire(
      active == null ||
          active is Map &&
              active['manifestSha256'] is String &&
              onlineHashPattern.hasMatch(active['manifestSha256']) &&
              active['gameVersion'] is String &&
              (active['gameVersion'] as String).isNotEmpty,
      '审批版本无效',
    );
    resourceRequire(
      active == null || !revoked.contains(active['manifestSha256']),
      '审批状态引用已撤销版本',
    );
    final value = OnlineApproval._(
      id as String,
      sequence as String,
      active?['manifestSha256'] as String?,
      active?['gameVersion'] as String?,
      List<String>.unmodifiable(revoked),
      data['stateSha256'] as String,
    );
    resourceRequire(
      resourceDigest(resourceJsonBytes(value.canonical)) == value.stateSha256,
      '审批状态摘要无效',
    );
    return value;
  }
}

int compareApprovalSequence(String a, String b) =>
    a.length != b.length ? a.length.compareTo(b.length) : a.compareTo(b);
