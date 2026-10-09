import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../platform/vault.dart';
import 'computerraria_computer.dart';

const _maxSafeInteger = 9007199254740991;

bool _digest(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

Uint8List _copyProgram(Uint8List image) {
  if (image.length > ComputerrariaComputer.romBytes || image.length % 4 != 0) {
    throw const FormatException('计算机程序记录必须包含完整且按字对齐的 ROM 映像。');
  }
  return Uint8List.fromList(image);
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('计算机导出来源记录包含无效字段。');
  }
  return value;
}

/// Local evidence for one exact app-issued WLD/TWLD pair. Names and paths are
/// never identities. The image is the known ROM extent, including word padding,
/// so replacing it later can clear the previous program's entire tail.
final class ComputerProvenanceRecord {
  final String wldSha256;
  final String twldSha256;
  final String? programName;
  final int? physicalPulses;
  final Uint8List _programImage;

  ComputerProvenanceRecord({
    required this.wldSha256,
    required this.twldSha256,
    required this.programName,
    required Uint8List programImage,
    this.physicalPulses,
  }) : _programImage = _copyProgram(programImage) {
    if (!_digest(wldSha256) || !_digest(twldSha256)) {
      throw const FormatException('计算机导出来源必须包含完整的小写 SHA-256。');
    }
    if ((programName == null) != _programImage.isEmpty) {
      throw const FormatException('计算机程序记录必须包含完整且按字对齐的 ROM 映像。');
    }
    final name = programName;
    if (name != null &&
        (name.trim().isEmpty ||
            name.length > 255 ||
            name.contains(RegExp(r'[/\\\x00-\x1f\x7f]')))) {
      throw const FormatException('计算机程序名称无效。');
    }
    if (physicalPulses != null &&
        (physicalPulses! < 0 || physicalPulses! > _maxSafeInteger)) {
      throw const FormatException('计算机物理时钟计数无效。');
    }
  }

  String get baseProfileSha256 => ComputerrariaComputer.sourceSha256;
  bool get programKnown => programName != null;
  int get programLength => _programImage.length;
  String get programSha256 => crypto.sha256.convert(_programImage).toString();
  Uint8List get programImage => Uint8List.fromList(_programImage);

  bool matches(String wld, String twld) =>
      wldSha256 == wld && twldSha256 == twld;

  Map<String, Object?> toJson() => {
    'wldSha256': wldSha256,
    'twldSha256': twldSha256,
    'programKnown': programKnown,
    'programName': programName,
    'programLength': programLength,
    'programSha256': programSha256,
    'programImage': base64Encode(_programImage),
    if (physicalPulses != null) 'physicalPulses': physicalPulses,
  };

  factory ComputerProvenanceRecord.fromJson(Object? value) {
    final json = _object(value, {
      'wldSha256',
      'twldSha256',
      'programKnown',
      'programName',
      'programLength',
      'programSha256',
      'programImage',
      'physicalPulses',
    });
    final encoded = json['programImage'];
    final length = json['programLength'];
    final name = json['programName'];
    final pulses = json['physicalPulses'];
    if (!_digest(json['wldSha256']) ||
        !_digest(json['twldSha256']) ||
        !_digest(json['programSha256']) ||
        !json.containsKey('programName') ||
        (name != null && name is! String) ||
        json['programKnown'] is! bool ||
        json['programKnown'] != (name != null) ||
        length is! int ||
        length < 0 ||
        length > ComputerrariaComputer.romBytes ||
        length % 4 != 0 ||
        encoded is! String ||
        encoded.length != ((length + 2) ~/ 3) * 4 ||
        (json.containsKey('physicalPulses') && pulses is! int)) {
      throw const FormatException('计算机程序来源记录不完整或超过大小限制。');
    }
    final image = base64Decode(encoded);
    if (image.length != length ||
        base64Encode(image) != encoded ||
        crypto.sha256.convert(image).toString() != json['programSha256']) {
      throw const FormatException('计算机程序映像校验失败。');
    }
    return ComputerProvenanceRecord(
      wldSha256: json['wldSha256'] as String,
      twldSha256: json['twldSha256'] as String,
      programName: name as String?,
      programImage: image,
      physicalPulses: pulses as int?,
    );
  }
}

/// Bounded, ordered evidence. Oldest means earliest registration, independent
/// of the system clock; replacing an exact pair moves it to the newest slot.
class ComputerProvenanceRegistry {
  static const format = 'terraforge.computer-provenance';
  static const version = 1;
  static const maxRecords = 8;
  static const maxJsonBytes = 9 * 1024 * 1024;
  final List<ComputerProvenanceRecord> records;

  ComputerProvenanceRegistry() : records = const [];
  ComputerProvenanceRegistry._(Iterable<ComputerProvenanceRecord> records)
    : records = List.unmodifiable(records);

  ComputerProvenanceRecord? find(String wldSha256, String twldSha256) {
    for (final record in records) {
      if (record.matches(wldSha256, twldSha256)) return record;
    }
    return null;
  }

  ComputerProvenanceRegistry register(ComputerProvenanceRecord record) {
    final next = [
      ...records.where(
        (previous) => !previous.matches(record.wldSha256, record.twldSha256),
      ),
      record,
    ];
    return ComputerProvenanceRegistry._(
      next.skip(next.length > maxRecords ? next.length - maxRecords : 0),
    );
  }

  String encode() {
    final encoded = jsonEncode({
      'format': format,
      'version': version,
      'baseProfileSha256': ComputerrariaComputer.sourceSha256,
      'records': records.map((record) => record.toJson()).toList(),
    });
    if (utf8.encode(encoded).length > maxJsonBytes) {
      throw const FormatException('计算机导出来源记录超过大小限制。');
    }
    return encoded;
  }

  factory ComputerProvenanceRegistry.decode(String encoded) {
    if (encoded.length > maxJsonBytes ||
        utf8.encode(encoded).length > maxJsonBytes) {
      throw const FormatException('计算机导出来源记录超过大小限制。');
    }
    final json = _object(jsonDecode(encoded), {
      'format',
      'version',
      'baseProfileSha256',
      'records',
    });
    final entries = json['records'];
    if (json['format'] != format ||
        json['version'] is! int ||
        json['version'] != version ||
        json['baseProfileSha256'] != ComputerrariaComputer.sourceSha256 ||
        entries is! List ||
        entries.length > maxRecords) {
      throw const FormatException('计算机导出来源版本、布局或记录数无效。');
    }
    final records = <ComputerProvenanceRecord>[];
    for (final entry in entries) {
      final record = ComputerProvenanceRecord.fromJson(entry);
      if (records.any(
        (previous) => previous.matches(record.wldSha256, record.twldSha256),
      )) {
        throw const FormatException('计算机导出来源包含重复的文件对。');
      }
      records.add(record);
    }
    return ComputerProvenanceRegistry._(records);
  }
}

/// Private local persistence only. Call register only after both exported files
/// were saved successfully from a verified, complete computer session.
///
/// LocalVault records are immutable. A new snapshot is verified before old
/// snapshots are pruned or it becomes visible. There is normally one snapshot;
/// an interrupted commit can leave two. Before another commit, pruning must
/// succeed so repeated storage failures cannot grow an unbounded history.
class ComputerProvenanceStore {
  static const entryPrefix = 'preferences-computer-provenance-v1-';
  static const entryKind = 'computer-provenance';
  static final _gates = Expando<_StoreGate>();
  final LocalVault? vault;
  final _memoryGate = _StoreGate();
  ComputerProvenanceRegistry _registry = ComputerProvenanceRegistry();
  bool _available;
  Object? _error;

  ComputerProvenanceStore({this.vault}) : _available = vault == null;

  ComputerProvenanceRegistry get registry => _registry;
  bool get available => _available;
  Object? get error => _error;
  String? get diagnostic =>
      _error == null ? null : '本机计算机导出来源记录不可用；导入世界仍按普通世界处理。$_error';

  static bool isEntry(VaultEntry entry) => entry.id.startsWith(entryPrefix);

  ComputerProvenanceRecord? find(String wldSha256, String twldSha256) =>
      _available ? _registry.find(wldSha256, twldSha256) : null;

  Future<void> load() => _run(() async {
    if (vault == null) return;
    try {
      final loaded = await _readLatest();
      _registry = loaded.registry;
      _available = true;
      _error = null;
    } catch (error) {
      _failClosed(error);
      rethrow;
    }
  });

  Future<void> register(ComputerProvenanceRecord record) => _run(() async {
    if (vault == null) {
      _registry = _registry.register(record);
      return;
    }
    try {
      final loaded = await _readLatest();
      final previous = loaded.entries.isEmpty ? null : loaded.entries.last;
      await _prune(loaded.entries, keeping: previous?.id);
      final next = loaded.registry.register(record);
      final sequence = previous == null ? 1 : _sequence(previous) + 1;
      if (sequence > _maxSafeInteger) {
        throw const FormatException('计算机导出来源版本序号超出范围。');
      }
      final bytes = Uint8List.fromList(utf8.encode(next.encode()));
      final entry = VaultEntry(
        id: '$entryPrefix${sequence.toString().padLeft(20, '0')}',
        name: '计算机导出来源',
        kind: entryKind,
        sha256: crypto.sha256.convert(bytes).toString(),
        size: bytes.length,
        modified: DateTime.now().toUtc(),
      );
      await vault!.put(entry, bytes);
      final committed = await _entries();
      final matches = committed.where((candidate) => candidate.id == entry.id);
      if (matches.length != 1 ||
          committed.last.id != entry.id ||
          matches.single.sha256 != entry.sha256 ||
          matches.single.size != entry.size ||
          matches.single.kind != entry.kind) {
        throw const VaultException('计算机导出来源提交信息校验失败。');
      }
      final verified = await _readSnapshot(matches.single);
      await _prune(committed, keeping: entry.id);
      _registry = verified;
      _available = true;
      _error = null;
    } catch (error) {
      _failClosed(error);
      rethrow;
    }
  });

  void _failClosed(Object error) {
    _registry = ComputerProvenanceRegistry();
    _available = false;
    _error = error;
  }

  Future<_LoadedRegistry> _readLatest() async {
    final entries = await _entries();
    final registry = entries.isEmpty
        ? ComputerProvenanceRegistry()
        : await _readSnapshot(entries.last);
    return _LoadedRegistry(registry, entries);
  }

  Future<List<VaultEntry>> _entries() async {
    final entries = (await vault!.list()).where(isEntry).toList();
    final ids = <String>{};
    for (final entry in entries) {
      _sequence(entry);
      validateVaultEntry(entry);
      if (!ids.add(entry.id) ||
          entry.kind != entryKind ||
          entry.size > ComputerProvenanceRegistry.maxJsonBytes) {
        throw const VaultException('计算机导出来源存储记录无效。');
      }
    }
    entries.sort((a, b) => a.id.compareTo(b.id));
    return entries;
  }

  static int _sequence(VaultEntry entry) {
    final suffix = entry.id.substring(entryPrefix.length);
    final sequence = int.tryParse(suffix);
    if (!RegExp(r'^\d{20}$').hasMatch(suffix) ||
        sequence == null ||
        sequence < 1 ||
        sequence > _maxSafeInteger) {
      throw const VaultException('计算机导出来源存储标识无效。');
    }
    return sequence;
  }

  Future<ComputerProvenanceRegistry> _readSnapshot(VaultEntry entry) async {
    final bytes = await vault!.read(entry.id);
    // Verify against the shared vault listing, including on implementations
    // that validate reads internally, rather than trusting metadata alone.
    validateVaultBytes(entry, bytes);
    if (bytes.length > ComputerProvenanceRegistry.maxJsonBytes) {
      throw const FormatException('计算机导出来源记录超过大小限制。');
    }
    return ComputerProvenanceRegistry.decode(utf8.decode(bytes));
  }

  Future<void> _prune(List<VaultEntry> entries, {String? keeping}) async {
    final stale = entries.where((entry) => entry.id != keeping).toList();
    for (final entry in stale) {
      await vault!.remove(entry.id);
    }
    if (stale.isNotEmpty &&
        (await _entries()).any(
          (entry) => stale.any((old) => old.id == entry.id),
        )) {
      throw const VaultException('计算机导出来源旧记录清理尚未完成。');
    }
  }

  Future<void> _run(Future<void> Function() action) {
    final gate = vault == null
        ? _memoryGate
        : (_gates[vault!] ??= _StoreGate());
    final result = gate.tail.then((_) => action());
    gate.tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class _StoreGate {
  Future<void> tail = Future<void>.value();
}

class _LoadedRegistry {
  final ComputerProvenanceRegistry registry;
  final List<VaultEntry> entries;
  _LoadedRegistry(this.registry, this.entries);
}
