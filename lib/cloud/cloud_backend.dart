import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cloud_api.dart';
import 'cloud_models.dart';

/// Stateful cloud workspace. Constructing it never performs network requests.
class CloudBackend extends ChangeNotifier {
  CloudBackend({
    required this.api,
    this.auth = const UnavailableAuthProvider(),
    this._session,
  });
  final CloudApi api;
  final AuthProvider auth;
  CloudSession? _session;
  bool _disposed = false;
  int _epoch = 0;
  Timer? _poll;
  bool busy = false;
  bool submissionUncertain = false;
  String? error;
  List<CloudSave> saves = [];
  List<Map<String, dynamic>> recommended = [];
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
    _poll?.cancel();
    _session = value;
    saves = [];
    recommended = [];
    account = null;
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
    if (_current(e)) saves = value;
  });
  Future<void> loadRecommendations() => _run((s, e) async {
    final value = await api.recommendations(s);
    if (_current(e)) recommended = value;
  });
  Future<void> loadProfile() => _run((s, e) async {
    final value = await api.profile(s);
    if (_current(e)) account = value;
  });
  Future<void> saveProfile(Map<String, dynamic> value) => _run((s, e) async {
    await api.updateProfile(s, value);
    if (_current(e)) account = Map.of(value);
  });
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
    _epoch++;
    _poll?.cancel();
    _session = null;
    super.dispose();
  }
}
