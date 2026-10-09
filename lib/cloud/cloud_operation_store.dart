import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_models.dart';

/// Only operation identifiers are stored. Sessions and credentials never enter
/// the journal. The key binds origin, tenant, terminal, and authenticated account.
/// Ambiguous legacy v1 queues are intentionally never replayed under a new scope.
abstract interface class CloudOperationStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PreferencesCloudOperationStore implements CloudOperationStore {
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) {
      throw const CloudFailure('Could not save the pending cloud operation.');
    }
  }
}

String cloudRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class PendingRecommendationTransfer {
  PendingRecommendationTransfer({required this.requestId, this.operationId});
  final String requestId;
  String? operationId;
  Map<String, String> toJson() => {
    'requestId': requestId,
    'operationId': ?operationId,
  };
}

class CloudOperationJournal {
  CloudOperationJournal({
    required this.store,
    required String serviceOrigin,
    required String accountId,
    String? tenantId,
    String? terminal,
  }) : key =
           'cloud-operations-v2-${sha256.convert(utf8.encode(jsonEncode([serviceOrigin, tenantId, terminal, accountId])))}';
  final CloudOperationStore store;
  final String key;
  final Set<String> receipts = {};
  final Map<String, PendingRecommendationTransfer> transfers = {};
  bool _loaded = false;
  Future<void> load() async {
    if (_loaded) return;
    final text = await store.read(key);
    if (text != null) {
      try {
        if (text.length > 128 * 1024) throw const FormatException();
        final json = jsonDecode(text) as Map<String, dynamic>;
        final r = json['receipts'] as List,
            t = json['transfers'] as Map<String, dynamic>;
        if (json['version'] != 2 || r.length > 1000 || t.length > 256) {
          throw const FormatException();
        }
        final parsedReceipts = r.map((v) => cloudUuid(v as String)).toSet();
        final parsedTransfers = <String, PendingRecommendationTransfer>{};
        for (final entry in t.entries) {
          final value = entry.value as Map<String, dynamic>;
          parsedTransfers[cloudUuid(entry.key)] = PendingRecommendationTransfer(
            requestId: cloudUuid(value['requestId'] as String),
            operationId: value['operationId'] == null
                ? null
                : cloudUuid(value['operationId'] as String),
          );
        }
        receipts.addAll(parsedReceipts);
        transfers.addAll(parsedTransfers);
      } catch (_) {
        throw const CloudFailure(
          'Pending cloud operations could not be read. No new transfer was started.',
        );
      }
    }
    _loaded = true;
  }

  Future<void> save() async {
    if (!_loaded || receipts.length > 1000 || transfers.length > 256) {
      throw const CloudFailure(
        'Pending cloud operation limit reached. Retry pending receipts first.',
      );
    }
    await store.write(
      key,
      jsonEncode({
        'version': 2,
        'receipts': receipts.toList(),
        'transfers': transfers.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      }),
    );
  }
}
