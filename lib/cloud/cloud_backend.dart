import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';

import 'cloud_api.dart';
import 'cloud_models.dart';
import 'cloud_operation_store.dart';

/// Completion means bytes and metadata have been durably published and verified.
typedef PersistCloudFile = Future<void> Function(
  CloudSave save,
  Uint8List bytes,
  void Function() assertCurrent,
);

class DownloadedCloudFile {
  const DownloadedCloudFile(
    this.save,
    this.bytes, {
    this.receiptPending = false,
  });
  final CloudSave save;
  final Uint8List bytes;
  final bool receiptPending;
}

/// Stateful cloud workspace. Constructing it never performs network requests.
class CloudBackend extends ChangeNotifier {
  CloudBackend({
    required this.api,
    this.auth = const UnavailableAuthProvider(),
    CloudSession? session,
    CloudOperationStore? operationStore,
    // The public constructor accepts a session while mutable state stays private.
    // ignore: prefer_initializing_formals
  }) : _session = session,
       operationStore = operationStore ?? PreferencesCloudOperationStore();
  final CloudApi api;
  final AuthProvider auth;
  final CloudOperationStore operationStore;
  final Map<String, CloudOperationJournal> _journals = {};
  CloudCancellation? _transferCancellation;
  String? notice;
  int pendingReceiptCount = 0;
  final Map<String, CloudRecommendationTransfer> recommendationTransfers = {};
  List<CloudHelpArticle> helpArticles = [];
  bool helpLoaded = false;
  bool helpLoading = false;
  String? helpError;
  bool get transferring => _transferCancellation != null;
  bool get hasAccountIdentity =>
      connected && (_session?.accountId?.isNotEmpty ?? false);
  String? normalizeAvatar(String value) => api.normalizeAvatar(value);

  CloudSession? _session;
  bool _disposed = false;
  int _epoch = 0;
  Timer? _poll;
  bool busy = false;
  bool submissionUncertain = false;
  String? error;
  List<CloudSave> saves = [];
  int _savesPage = 0, _recommendationsPage = 0;
  bool hasMoreSaves = false, hasMoreRecommendations = false;
  String recommendationKind = 'all';
  List<CloudRecommendation> recommended = [];
  Map<String, dynamic>? account;
  GenerationOptions? generationOptions;
  CloudSave? job;
  bool get connected => _session?.valid ?? false;
  bool supports(CloudCapability capability) =>
      api.capabilities.contains(capability);
  CloudSession get session {
    if (!connected) {
      throw const CloudFailure('Connect a supported cloud session first.');
    }
    return _session!;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setSession(CloudSession? value) {
    _epoch++;
    _transferCancellation?.cancel();
    _transferCancellation = null;
    _poll?.cancel();
    _session = value;
    saves = [];
    recommended = [];
    _savesPage = 0;
    _recommendationsPage = 0;
    hasMoreSaves = false;
    hasMoreRecommendations = false;
    recommendationKind = 'all';
    account = null;
    recommendationTransfers.clear();
    helpArticles = [];
    helpLoaded = false;
    helpLoading = false;
    helpError = null;
    pendingReceiptCount = 0;
    notice = null;
    job = null;
    generationOptions = null;
    error = null;
    busy = false;
    submissionUncertain = false;
    _notify();
  }

  Future<void> signIn() async {
    if (busy) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      final value = await auth.signIn();
      if (!_disposed && epoch == _epoch) setSession(value);
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        error = 'A supported cross-platform sign-in adapter is required.';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> signOut() async {
    setSession(null);
    await auth.signOut();
  }

  Future<void> _run(Future<void> Function(CloudSession, int) action) async {
    if (busy || _disposed) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      await action(session, epoch);
    } catch (e) {
      if (_current(epoch)) {
        error = e is CloudFailure
            ? e.message
            : 'Cloud operation failed. Please try again.';
      }
    } finally {
      if (_current(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;
  Future<void> refreshSaves() => _run((s, e) async {
    final value = await api.listSaves(s);
    if (_current(e)) {
      saves = value;
      _savesPage = 1;
      hasMoreSaves = value.length == 30;
    }
  });
  Future<void> loadMoreSaves() => _run((s, e) async {
    if (!hasMoreSaves) return;
    final page = _savesPage + 1;
    final value = await api.listSaves(s, page: page);
    if (_current(e)) {
      saves = {
        for (final save in [...saves, ...value]) save.id: save,
      }.values.toList();
      _savesPage = page;
      hasMoreSaves = value.length == 30;
    }
  });
  Future<void> _runPublic(
    Future<void> Function(CloudSession?, int) action,
  ) async {
    if (busy || _disposed) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      await action(connected ? _session : null, epoch);
    } catch (e) {
      if (_current(epoch)) {
        error = e is CloudFailure
            ? e.message
            : 'Cloud operation failed. Please try again.';
      }
    } finally {
      if (_current(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> loadRecommendations({String kind = 'all'}) =>
      _runPublic((s, e) async {
        final value = await api.recommendations(s, kind: kind);
        if (!_current(e)) return;
        recommended = value.where((v) => v.ready && v.visible).toList();
        _recommendationsPage = 1;
        hasMoreRecommendations = value.length == 30;
        recommendationKind = kind;
        if (s?.accountId?.isNotEmpty == true) {
          final journal = await _journal(s!);
          if (_current(e)) pendingReceiptCount = journal.receipts.length;
        }
      });
  Future<void> loadMoreRecommendations() => _runPublic((s, e) async {
    if (!hasMoreRecommendations) return;
    final page = _recommendationsPage + 1;
    final value = await api.recommendations(
      s,
      kind: recommendationKind,
      page: page,
    );
    if (_current(e)) {
      recommended = {
        for (final item in [
          ...recommended,
          ...value.where((v) => v.ready && v.visible),
        ])
          item.id: item,
      }.values.toList();
      _recommendationsPage = page;
      hasMoreRecommendations = value.length == 30;
    }
  });
  Future<void> loadHelp() => _runPublic((s, e) async {
    helpError = null;
    helpLoading = true;
    _notify();
    try {
      final value = await api.help(s);
      if (_current(e)) {
        helpArticles = value;
        helpLoaded = true;
      }
    } catch (_) {
      if (_current(e)) {
        helpError = '帮助信息加载失败，请重试。';
        helpLoaded = true;
      }
    } finally {
      if (_current(e)) helpLoading = false;
    }
  });
  Future<void> loadProfile() => _run((s, e) async {
    final value = await api.profile(s);
    if (_current(e)) account = value;
  });
  Future<void> saveProfile(Map<String, dynamic> value) => _run((s, e) async {
    if (account == null || value['id'] != account!['id']) {
      throw const CloudFailure(
        'Reload the current account before editing its profile.',
      );
    }
    await api.updateProfile(s, value);
    if (_current(e)) account = {...?account, ...value};
  });
  Future<void> deleteSave(CloudSave save) => _run((s, e) async {
    await api.deleteSave(s, save.id);
    if (_current(e)) saves = saves.where((v) => v.id != save.id).toList();
  });
  void _applyCounts(CloudRecommendationCounts counts) {
    recommended = recommended
        .map((v) => v.id == counts.id ? v.withCounts(counts) : v)
        .toList();
  }

  Future<void> likeRecommendation(CloudRecommendation item) =>
      _run((s, e) async {
        final latest = await api.getRecommendation(s, item.id);
        if (!_current(e)) return;
        _available(latest, item.id);
        final counts = await api.likeRecommendation(s, item.id);
        if (_current(e)) _applyCounts(counts);
      });
  void _available(CloudRecommendation item, String expectedId) {
    if (item.id != expectedId || !item.visible || !item.ready) {
      throw const CloudFailure(
        'This recommendation is no longer available. Refresh the list.',
      );
    }
  }

  void cancelTransfer() => _transferCancellation?.cancel();
  Future<T> _transfer<T>(
    Future<T> Function(CloudSession, CloudCancellation, void Function()) action,
  ) async {
    if (busy || _disposed) {
      throw const CloudFailure('A cloud operation is already running.');
    }
    final s = session, epoch = _epoch, cancellation = CloudCancellation();
    void check() {
      cancellation.check();
      if (!_current(epoch) || !connected || !identical(s, _session)) {
        throw const CloudFailure(
          'Cloud account changed. Retry using the current account.',
        );
      }
    }

    busy = true;
    error = null;
    notice = null;
    _transferCancellation = cancellation;
    _notify();
    try {
      return await action(s, cancellation, check);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _transferCancellation = null;
        _notify();
      }
    }
  }

  Future<CloudOperationJournal> _journal(CloudSession s) async {
    final owner = s.accountId;
    if (owner == null ||
        owner.isEmpty ||
        owner.length > 128 ||
        owner.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const CloudFailure(
        'A verified account identity is required for resumable recommendations.',
      );
    }
    final scope = jsonEncode([
      api.serviceOrigin,
      api.tenantId,
      api.terminal,
      owner,
    ]);
    final journal = _journals.putIfAbsent(
      scope,
      () => CloudOperationJournal(
        store: operationStore,
        serviceOrigin: api.serviceOrigin,
        tenantId: api.tenantId,
        terminal: api.terminal,
        accountId: owner,
      ),
    );
    await journal.load();
    return journal;
  }

  Future<CloudSave> uploadFile(
    Uint8List bytes,
    String fileName,
    String kind, {
    Future<Uint8List> Function()? prepareWorldPreview,
  }) {
    // Capture caller-owned bytes before the first asynchronous boundary.
    final snapshot = Uint8List.fromList(bytes);
    return _transfer((s, cancel, check) async {
      check();
      final existing = await api.duplicate(
        s,
        kind: kind,
        hash: sha1.convert(snapshot).toString(),
        fileSize: snapshot.length,
        cancellation: cancel,
      );
      check();
      CloudSave result;
      if (existing != null) {
        result = existing;
      } else {
        if (kind == 'world' && prepareWorldPreview == null) {
          throw const CloudFailure(
            'World upload preview renderer is unavailable.',
          );
        }
        final preview = kind == 'world' ? await prepareWorldPreview!() : null;
        check();
        result = await api.upload(
          s,
          snapshot,
          fileName,
          kind,
          preview: preview,
          cancellation: cancel,
        );
      }
      check();
      saves = [result, ...saves.where((v) => v.id != result.id)];
      return result;
    });
  }

  Future<DownloadedCloudFile> downloadSave(
    CloudSave requested,
    PersistCloudFile persist,
  ) => _transfer((s, cancel, check) async {
    final latest = await api.getSave(s, requested.id, cancellation: cancel);
    check();
    if (latest.id != requested.id ||
        latest.status != CloudJobStatus.ready ||
        !{'world', 'player'}.contains(latest.kind) ||
        latest.fileSize < 1) {
      throw const CloudFailure('This save is not ready for download.');
    }
    cloudFileName(latest.fileName);
    final bytes = await api.download(
      s,
      latest.id,
      expectedBytes: latest.fileSize,
      cancellation: cancel,
    );
    check();
    if (bytes.length != latest.fileSize) {
      throw const CloudFailure('Downloaded file is incomplete.');
    }
    await persist(latest, bytes, check);
    check();
    return DownloadedCloudFile(latest, bytes);
  });
  Future<DownloadedCloudFile> downloadRecommendation(
    CloudRecommendation requested,
    PersistCloudFile persist,
  ) => _transfer((s, cancel, check) async {
    final journal = await _journal(s);
    check();
    if (journal.receipts.length >= 1000) {
      throw const CloudFailure(
        'Retry pending receipts before downloading more recommendations.',
      );
    }
    final latest = await api.getRecommendation(
      s,
      requested.id,
      cancellation: cancel,
    );
    check();
    _available(latest, requested.id);
    final ticket = await api.recommendationTicket(
      s,
      requested.id,
      cloudRequestId(),
      cancellation: cancel,
    );
    check();
    final bytes = await api.recommendationDownload(
      s,
      ticket,
      cancellation: cancel,
    );
    check();
    if (bytes.length != ticket.fileSize) {
      throw const CloudFailure('Downloaded file is incomplete.');
    }
    final file = CloudSave(
      id: latest.id,
      kind: latest.kind,
      fileName: ticket.fileName,
      fileSize: ticket.fileSize,
      status: CloudJobStatus.ready,
    );
    // Never count a download until the complete candidate is in durable storage.
    await persist(file, bytes, check);
    check();
    journal.receipts.add(ticket.operationId);
    try {
      await journal.save();
    } catch (_) {
      notice = '文件已保存；回执暂存内存，请在关闭应用前重试。';
    }
    var pending = true;
    try {
      check();
      final counts = await api.recommendationComplete(s, ticket.operationId);
      check();
      journal.receipts.remove(ticket.operationId);
      await journal.save();
      _applyCounts(counts);
      pending = false;
    } catch (_) {
      // Idempotent completion can be retried. Never discard a durable file.
      journal.receipts.add(ticket.operationId);
      try {
        await journal.save();
      } catch (_) {
        /* Keep the in-memory retry. */
      }
    }
    if (identical(s, _session)) {
      pendingReceiptCount = journal.receipts.length;
      notice ??= pending ? '文件已保存到本地；下载统计回执等待重试。' : '文件已保存到本地。';
    }
    return DownloadedCloudFile(file, bytes, receiptPending: pending);
  });
  Future<void> retryRecommendationReceipts() => _run((s, e) async {
    final journal = await _journal(s);
    if (!_current(e)) return;
    for (final operationId in journal.receipts.take(20).toList()) {
      if (!_current(e)) break;
      try {
        final counts = await api.recommendationComplete(s, operationId);
        if (!_current(e)) break;
        journal.receipts.remove(operationId);
        _applyCounts(counts);
      } on CloudFailure catch (failure) {
        if (!_current(e)) break;
        if ({403, 404, 410}.contains(failure.statusCode)) {
          journal.receipts.remove(operationId);
        } else if (failure.statusCode == null || failure.statusCode == 401) {
          break;
        } else {
          journal.receipts.remove(operationId);
          journal.receipts.add(operationId);
        }
      }
      await journal.save();
    }
    if (_current(e)) {
      pendingReceiptCount = journal.receipts.length;
      notice = pendingReceiptCount == 0
          ? '下载回执已同步。'
          : '仍有 $pendingReceiptCount 条回执等待重试。';
    }
  });
  Future<void> transferRecommendation(CloudRecommendation requested) async {
    final epoch = _epoch;
    try {
      await _transfer((s, cancel, check) async {
        final journal = await _journal(s);
        check();
        var pending = journal.transfers[requested.id];
        final isNewRequest = pending == null;
        if (pending == null) {
          if (journal.transfers.length >= 256) {
            throw const CloudFailure('Pending transfer limit reached.');
          }
          pending = PendingRecommendationTransfer(requestId: cloudRequestId());
          journal.transfers[requested.id] = pending;
        }
        // Persist BEFORE POST. A lost response retries the same request ID.
        await journal.save();
        check();
        CloudRecommendationTransfer result;
        if (pending.operationId != null) {
          result = await api.recommendationOperation(
            s,
            pending.operationId!,
            cancellation: cancel,
          );
        } else {
          // A retry must reach the idempotent request lookup even if the
          // published item was hidden after the first POST response was lost.
          if (isNewRequest) {
            final latest = await api.getRecommendation(
              s,
              requested.id,
              cancellation: cancel,
            );
            check();
            _available(latest, requested.id);
          }
          result = await api.recommendationTransfer(
            s,
            requested.id,
            pending.requestId,
            cancellation: cancel,
          );
        }
        check();
        if (pending.operationId != null &&
            pending.operationId != result.operationId) {
          throw const CloudFailure('Transfer operation identity changed.');
        }
        if (result.status == 'pending') {
          pending.operationId = result.operationId;
        } else {
          journal.transfers.remove(requested.id);
        }
        await journal.save();
        check();
        recommendationTransfers[requested.id] = result;
        _applyCounts(
          CloudRecommendationCounts(
            id: requested.id,
            downloadCount: result.downloadCount,
          ),
        );
        notice = result.status == 'ready'
            ? '推荐已转存云端，请刷新存档列表。'
            : result.status == 'pending'
            ? '转存处理中；再次点击将查询同一操作。'
            : '转存失败，可以显式重试。';
      });
    } catch (e) {
      if (_current(epoch)) {
        error = e is CloudFailure
            ? e.message
            : 'Transfer failed. Retry resumes the same operation.';
        _notify();
      }
    }
  }

  Future<void> loadOptions() => _run((s, e) async {
    final value = await api.options(s);
    if (_current(e)) generationOptions = value;
  });
  Future<void> submitGeneration(GenerationRequest request) async {
    if (busy || submissionUncertain || (job != null && !job!.status.terminal)) {
      return;
    }
    final options = generationOptions;
    if (options == null ||
        !options.enabled ||
        !options.versions.contains(request.version) ||
        request.revision != options.schema.revision ||
        options.schema.validate(request.config).isNotEmpty ||
        request.name.trim().isEmpty ||
        request.name.length > 128 ||
        request.seed.length > 256 ||
        !{'small', 'medium', 'large'}.contains(request.size) ||
        !{
          'classic',
          'expert',
          'master',
          'journey',
        }.contains(request.difficulty) ||
        !{'random', 'corruption', 'crimson'}.contains(request.evil)) {
      error =
          'Load generation options and correct the request before submitting.';
      _notify();
      return;
    }
    await _run((s, e) async {
      // A lost response may already have created a job; never auto-repeat a submit.
      submissionUncertain = true;
      final value = await api.submit(s, request);
      if (_current(e)) {
        submissionUncertain = false;
        job = value;
        _schedule();
      }
    });
  }

  Future<void> refreshJob() => _run((s, e) async {
    final id = job?.id;
    if (id == null) return;
    final value = await api.refresh(s, id);
    if (_current(e)) {
      job = value;
      _schedule();
    }
  });

  /// Allows reconciliation after an uncertain submit using a user-selected remote record.
  void observeJob(CloudSave value) {
    if (busy || !connected || _disposed) return;
    job = value;
    submissionUncertain = false;
    _schedule();
    _notify();
  }

  Future<void> retryJob() => _run((s, e) async {
    final current = job;
    if (current == null || !current.status.retryable) return;
    final value = await api.retry(s, current.id);
    if (_current(e)) {
      job = value;
      _schedule();
    }
  });
  Future<void> cancelJob() => _run((s, e) async {
    final current = job;
    if (current == null ||
        current.status.terminal ||
        current.status == CloudJobStatus.cancelling) {
      return;
    }
    final value = await api.cancel(s, current.id);
    if (_current(e)) {
      job = value;
      _schedule();
    }
  });
  void _schedule() {
    _poll?.cancel();
    if (_disposed || job == null || job!.status.terminal || !connected) return;
    _poll = Timer(const Duration(seconds: 5), () async {
      if (busy) {
        _schedule();
        return;
      }
      await refreshJob();
      // Failed polling pauses automatic requests; explicit refresh can resume it.
    });
  }

  void stopPolling() {
    _poll?.cancel();
  }

  @override
  void dispose() {
    _disposed = true;
    _transferCancellation?.cancel();
    _epoch++;
    _poll?.cancel();
    _session = null;
    super.dispose();
  }
}
