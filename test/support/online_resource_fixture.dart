import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:terraforge/resources/online_resource_protocol.dart';
import 'package:terraforge/resources/online_resource_storage.dart';
import 'package:terraforge/resources/online_resource_transport.dart';

/// Entirely original, scalable fixtures. No game data, service calls or credentials.
class OnlineFixture {
  OnlineFixture([
    String label = 'Synthetic',
    int itemCount = 1,
    int iconCount = 1,
  ]) {
    if (itemCount < 1 || itemCount > 20000) {
      throw ArgumentError.value(itemCount, 'itemCount');
    }
    if (iconCount < 1 || iconCount > itemCount || iconCount > 4096) {
      throw ArgumentError.value(iconCount, 'iconCount');
    }
    final textureRows = <String, Object?>{};
    for (var i = 0; i < iconCount; i++) {
      final image = img.Image(width: 1, height: 1)
        ..setPixelRgb(0, 0, i % 256, i ~/ 256, 37);
      final pngRef = object(
        img.encodePng(image),
        'png',
        media: 'image/png',
        compressed: false,
      );
      textureRows['Item_${17 + i}'] = {
        'width': 1,
        'height': 1,
        'object': pngRef,
      };
    }
    final textures = json(textureRows);
    final index = json([
      for (var i = 0; i < itemCount; i++)
        {'id': 17 + i, 'name': 'Index label', 'research': 3, 'maxStack': 9},
    ]);
    final items = json([
      for (var i = 0; i < itemCount; i++)
        {
          'id': 17 + i,
          'name': i == 0 ? label : '$label $i',
          'texture': 'Item_${17 + i % iconCount}',
        },
    ]);
    itemPath = items['path'] as String;
    final tiles = json([
      {'id': '42:0', 'type': 42, 'variant': 0, 'name': 'Synthetic tile'},
    ]);
    final stable = json([
      [0, 42, 0, 0, 12, 34, 56, 1],
    ]);
    final srgb = Uint8List(12 + 65537 * 4)
      ..setRange(0, 4, ascii.encode('SRGB'));
    final txci = Uint8List(44)..setRange(0, 4, ascii.encode('TXCI'));
    final view = ByteData.sublistView(txci)
      ..setUint16(4, 3, Endian.little)
      ..setUint16(6, 8, Endian.little);
    for (final offset in [20, 24, 28, 32, 36]) {
      view.setUint32(offset, 44, Endian.little);
    }
    manifest = resourceJsonBytes({
      'schema': 1,
      'gameVersion': 'synthetic-1',
      'missing': [],
      'sources': {'textureFiles': iconCount},
      'textures': textures,
      'families': {
        'item-index': [
          {'rows': itemCount, 'object': index},
        ],
        'items': [
          {'rows': itemCount, 'object': items},
        ],
        'tiles': [
          {'rows': 1, 'object': tiles},
        ],
      },
      'rgb': {
        'candidates': json([]),
        'stableCandidates': stable,
        'srgb': object(srgb, 'srgb.gz'),
        'txci': object(txci, 'txci.gz'),
      },
    });
    sha = resourceDigest(manifest);
    files['releases/$sha.json'] = manifest;
  }
  final files = <String, Uint8List>{};
  late final Uint8List manifest;
  late final String sha, itemPath;
  Map<String, Object?> json(Object value) =>
      object(resourceJsonBytes(value), 'json.gz', media: 'application/json');
  Map<String, Object?> object(
    Uint8List bytes,
    String suffix, {
    String media = 'application/octet-stream',
    bool compressed = true,
  }) {
    final wire = compressed
        ? Uint8List.fromList(GZipEncoder().encode(bytes))
        : bytes;
    final sha = resourceDigest(wire);
    final path = 'objects/${sha.substring(0, 2)}/$sha.$suffix';
    files[path] = wire;
    return {
      'path': path,
      'sha256': sha,
      'bytes': wire.length,
      'mediaType': media,
      if (compressed) 'encoding': 'gzip',
      if (compressed) 'decodedBytes': bytes.length,
    };
  }

  Uint8List approval({
    String sequence = '1',
    List<String> revoked = const [],
    bool active = true,
    String id = 'synthetic-authority',
  }) {
    final value = <String, Object?>{
      'active': active
          ? {'gameVersion': 'synthetic-1', 'manifestSha256': sha}
          : null,
      'authorityId': id,
      'channel': 'stable',
      'revokedManifestSha256': [...revoked]..sort(),
      'schema': 1,
      'sequence': sequence,
    };
    return resourceJsonBytes({
      ...value,
      'stateSha256': resourceDigest(resourceJsonBytes(value)),
    });
  }
}

class FixtureResourceTransport implements OnlineResourceTransport {
  FixtureResourceTransport(OnlineFixture fixture)
    : approvalBytes = fixture.approval() {
    add(fixture);
  }
  @override
  String authorityEndpoint = 'https://resources.example.test/api';
  Uint8List approvalBytes;
  final files = <String, Uint8List>{};
  final requests = <String>[];
  Future<void> Function(String, OnlineResourceCancellation)? beforeFetch;
  Future<void> Function(OnlineResourceCancellation)? beforeApproval;
  String? corruptPath;
  bool offline = false;
  void add(OnlineFixture fixture) => files.addAll(fixture.files);
  @override
  Future<Uint8List> approval(OnlineResourceCancellation cancellation) async {
    if (offline) throw StateError('Unexpected network call');
    await beforeApproval?.call(cancellation);
    cancellation.check();
    return Uint8List.fromList(approvalBytes);
  }

  @override
  Future<Uint8List> fetch(
    String path,
    String manifestSha256,
    int maxBytes,
    OnlineResourceCancellation cancellation,
  ) async {
    if (offline) throw StateError('Unexpected network call');
    requests.add(path);
    await beforeFetch?.call(path, cancellation);
    cancellation.check();
    final bytes = Uint8List.fromList(files[path]!);
    if (path == corruptPath) bytes[bytes.length - 1] ^= 1;
    if (bytes.length > maxBytes) {
      throw StateError('Fixture exceeds request bound');
    }
    return bytes;
  }
}

class FaultResourceStorage extends MemoryOnlineResourceStorage {
  bool failCommit = false, failAuthority = false, failRead = false;
  @override
  Future<Uint8List?> read(String kind, String id) async {
    if (failRead) throw StateError('Synthetic transient storage read failure');
    return super.read(kind, id);
  }

  @override
  Future<void> commitActive(String namespace, Uint8List bytes) async {
    if (failCommit) throw StateError('Synthetic active write failure');
    await super.commitActive(namespace, bytes);
  }

  @override
  Future<void> write(String kind, String id, Uint8List bytes) async {
    if (failAuthority && id.startsWith('authority-')) {
      throw StateError('Synthetic ledger failure');
    }
    await super.write(kind, id, bytes);
  }
}
