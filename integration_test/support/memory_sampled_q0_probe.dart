// Independent sampled diagnostic bridge. Native owns provider identity, maps,
// receipt/ACK and one sample; Dart adds no observer or poll at the quiet cut.
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:ffi';
import 'dart:io';

typedef _StatusNative = Int32 Function();
typedef _StatusDart = int Function();
typedef _Q0Native = Int32 Function(Uint64);
typedef _Q0Dart = int Function(int);
typedef _MetadataNative = Pointer<Uint8> Function();
typedef _MetadataDart = Pointer<Uint8> Function();

class MemorySampledQ0Probe {
  MemorySampledQ0Probe._(
    this._library,
    this._initialize,
    this._q0,
    this._close,
    this._metadata,
    this._helperPath,
    this._targetPath,
    this._outputPath,
  );

  static const _metadataByteLimit = 16384;
  static const _allocatorPath =
      '/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16';
  final DynamicLibrary _library;
  final _StatusDart _initialize, _close;
  final _Q0Dart _q0;
  final _MetadataDart _metadata;
  final String _helperPath, _targetPath, _outputPath;
  Map<String, Object?>? _startup, _evidence;
  bool _initializationAttempted = false, _initialized = false;
  bool _q0Attempted = false, _closeInvoked = false;
  int? _gaugeUs, _enterUs, _exitUs, _q0Status;

  static MemorySampledQ0Probe open() {
    if (!const bool.fromEnvironment('ABC_SAMPLED_DIAGNOSTIC') ||
        !Platform.isLinux ||
        Abi.current() != Abi.linuxX64) {
      throw StateError('Sampled q0 requires explicit Linux x86_64 opt-in');
    }
    final environment = Platform.environment;
    final helper = environment['ABC_SAMPLED_HELPER'];
    final output = environment['ABC_SAMPLED_OUTPUT'];
    if (environment['ABC_SAMPLED_DIAGNOSTIC'] != '1' ||
        environment['TCMALLOC_SAMPLE_PARAMETER'] != '524288' ||
        environment['MEMORY_OWNER_ARM'] != 'probe-only' ||
        helper == null ||
        output == null ||
        environment['ABC_SAMPLED_HELLO'] != '$output/sampled-hello.json' ||
        environment['ABC_SAMPLED_READY'] != '$output/sampled-ready.json' ||
        !helper.startsWith('/') ||
        !output.startsWith('/') ||
        FileSystemEntity.typeSync(helper, followLinks: false) !=
            FileSystemEntityType.file ||
        FileSystemEntity.typeSync(output, followLinks: false) !=
            FileSystemEntityType.directory ||
        File(helper).resolveSymbolicLinksSync() != helper ||
        Directory(output).resolveSymbolicLinksSync() != output) {
      throw StateError('Sealed sampled q0 arm and paths required');
    }
    final library = DynamicLibrary.open(helper);
    return MemorySampledQ0Probe._(
      library,
      library.lookupFunction<_StatusNative, _StatusDart>(
        'abc_sample_runtime_initialize',
      ),
      library.lookupFunction<_Q0Native, _Q0Dart>('abc_sample_runtime_q0'),
      library.lookupFunction<_StatusNative, _StatusDart>(
        'abc_sample_runtime_close',
      ),
      library.lookupFunction<_MetadataNative, _MetadataDart>(
        'abc_sample_runtime_metadata_json',
      ),
      helper,
      File('/proc/self/exe').resolveSymbolicLinksSync(),
      output,
    );
  }

  Map<String, Object?> get startup {
    final value = _startup;
    if (value == null) throw StateError('Sampled q0 startup unavailable');
    return value;
  }

  Map<String, Object?>? get evidence => _evidence;

  // Read only before the hello gate and after native close. The native ABI
  // returns its own fixed 16 KiB buffer; no heap-sized FFI allocation is made.
  Map<String, Object?> _nativeMetadata() {
    final pointer = _metadata();
    if (pointer == nullptr) throw StateError('Sampled metadata unavailable');
    final buffer = pointer.asTypedList(_metadataByteLimit);
    final length = buffer.indexOf(0);
    if (length <= 0) throw StateError('Sampled metadata exceeds fixed bound');
    final value = jsonDecode(utf8.decode(buffer.sublist(0, length)));
    if (value is! Map ||
        value['schema'] != 'abc.gperftools-sampled-runtime.v1' ||
        value['abi'] != 1 ||
        value['pid'] != pid ||
        value['mode'] != 'sampled' ||
        value['estimationOnly'] != true ||
        value['transportOnly'] != true) {
      throw StateError('Sampled native metadata ABI mismatch');
    }
    return Map<String, Object?>.from(value);
  }

  void initialize() {
    if (_initializationAttempted || _closeInvoked) {
      throw StateError('Sampled initialization already consumed');
    }
    _initializationAttempted = true;
    final start = Timeline.now;
    final result = _initialize();
    final end = Timeline.now;
    final native = _nativeMetadata();
    final provider = native['provider'];
    final target = native['target'];
    final output = native['output'];
    final observer = native['observer'];
    final sample = native['sample'];
    final verified = result == 0 &&
        native['initialized'] == true &&
        native['initializationStatus'] == 0 &&
        native['q0Calls'] == 0 &&
        native['q0TransportAccepted'] == false &&
        native['closeCalls'] == 0 &&
        native['closed'] == false &&
        native['failure'] == 0 &&
        provider is Map &&
        provider['path'] == _allocatorPath &&
        provider['publicInstanceAddressChecked'] == true &&
        provider['allocationOwnershipChecked'] == true &&
        target is Map &&
        target['path'] == _targetPath &&
        output is Map &&
        output['path'] == _outputPath &&
        observer is Map &&
        observer['fdOpened'] == 4 &&
        observer['heldFds'] == 3 &&
        observer['fdCloseAttempts'] == 1 &&
        observer['fdClosed'] == 1 &&
        observer['cleanupErrno'] == 0 &&
        observer['preallocatedMapsBytes'] == 2097152 &&
        sample is Map &&
        sample['api_calls'] == 0;
    _startup = {
      'schema': 'abc.gperftools-sampled-startup.v1',
      'mode': 'sampled',
      'arm': 'probe-only',
      'hostPid': pid,
      'helperPath': _helperPath,
      'targetPath': _targetPath,
      'allocatorPath': _allocatorPath,
      'outputPath': _outputPath,
      'initialization': {
        'statusCode': result,
        'startUs': start,
        'endUs': end,
        'clockDomain': 'dart:developer.Timeline.now',
        'identityVerifiedAtInitialization': verified,
        'native': native,
      },
    };
    _initialized = verified;
    if (!verified) throw StateError('Sampled q0 initialization failed: $result');
  }

  // The argument is the original gauge write/flush completion stamp, not the
  // sample time. A failed call consumes the single slot and never retries.
  void afterQ0Gauge(int gaugeDartUs) {
    if (!_initialized || _q0Attempted || _closeInvoked) {
      throw StateError('Sampled q0 cut order or lifetime exceeded');
    }
    _q0Attempted = true;
    _gaugeUs = gaugeDartUs;
    _enterUs = Timeline.now;
    Timeline.startSync('abc.gperftools.sampled-released-quiet-end');
    try {
      // Ordinary synchronous FFI. The one native sample and ACK can block.
      _q0Status = _q0(gaugeDartUs);
    } finally {
      Timeline.finishSync();
      _exitUs = Timeline.now;
    }
    if (_q0Status != 0) {
      throw StateError('Sampled q0 capture failed: $_q0Status');
    }
  }

  // First operation in outer finally, on every success/failure path. Close is
  // invoked at most once and all evidence is encoded only after native close.
  void closeAndWriteEvidence() {
    if (_closeInvoked) return;
    _closeInvoked = true;
    final start = Timeline.now;
    final result = _close();
    final end = Timeline.now;
    final native = _nativeMetadata();
    final observer = native['observer'];
    final sample = native['sample'];
    final cut = native['cut'];
    final complete = result == 0 &&
        _initialized &&
        _q0Attempted &&
        _q0Status == 0 &&
        native['initialized'] == true &&
        native['initializationStatus'] == 0 &&
        native['q0Calls'] == 1 &&
        native['q0TransportAccepted'] == true &&
        native['closeCalls'] == 1 &&
        native['closed'] == true &&
        native['failure'] == 0 &&
        observer is Map &&
        observer['heldFds'] == 0 &&
        observer['fdOpened'] is int &&
        (observer['fdOpened'] as int) > 0 &&
        observer['fdClosed'] == observer['fdOpened'] &&
        observer['fdCloseAttempts'] == observer['fdOpened'] &&
        observer['cleanupErrno'] == 0 &&
        sample is Map &&
        sample['status'] == 0 &&
        sample['api_calls'] == 1 &&
        sample['accepted'] == 1 &&
        sample['published'] == 1 &&
        sample['cleanup_errno'] == 0 &&
        cut is Map &&
        cut['gaugeDartUs'] == _gaugeUs &&
        cut['receiptPublished'] == true &&
        cut['ackAccepted'] == true;
    final evidence = <String, Object?>{
      'schema': 'abc.gperftools-sampled-dart-q0.v1',
      'mode': 'sampled',
      'arm': 'probe-only',
      'hostPid': pid,
      'status': complete ? 'sampled-q0-captured' : 'failed',
      'startup': _startup,
      'closeStatusCode': result,
      'closeStartUs': start,
      'closeEndUs': end,
      'dartClockDomain': 'dart:developer.Timeline.now',
      'nativeClockDomain': 'CLOCK_MONOTONIC nanoseconds',
      'clockDomainsComparable': false,
      'native': native,
      'q0Attempted': _q0Attempted,
      'dartCut': {
        'cycle': 0,
        'gaugeDartUs': _gaugeUs,
        'enterUs': _enterUs,
        'exitUs': _exitUs,
        'statusCode': _q0Status,
      },
      'originalEightCycleWorkloadCompleted': false,
      'mappingAcceptanceEstablished': false,
      'fullHeapCoverage': false,
      'transportOnly': true,
    };
    _evidence = evidence;
    final file = File('$_outputPath/dart-sampled-q0.json');
    file.createSync(exclusive: true);
    file.writeAsStringSync(jsonEncode(evidence), flush: true);
    // Keep the DSO alive for process lifetime; never unload sampled allocator.
    assert(_library.providesSymbol('abc_sample_runtime_metadata_json'));
    if (!complete) throw StateError('Sampled q0 finalization incomplete: $result');
  }
}

Map<String, Object?> validateSampledQ0Ready(
  Object? value, {
  required String arm,
  required int hostPid,
  required String sourceCommit,
  required String baseProductCommit,
  required int readyReceivedUs,
}) {
  if (value is! Map ||
      value.length != 6 ||
      value['schema'] != 'abc.gperftools-sampled-ready.v1' ||
      value['arm'] != arm ||
      arm != 'probe-only' ||
      value['hostPid'] is! int ||
      value['hostPid'] != hostPid ||
      value['sourceCommit'] != sourceCommit ||
      value['baseProductCommit'] != baseProductCommit ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceCommit) ||
      value['buildSha256'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['buildSha256'] as String)) {
    throw StateError('Sampled q0 startup identity does not match');
  }
  return {
    'schema': value['schema'],
    'arm': arm,
    'hostPid': hostPid,
    'sourceCommit': sourceCommit,
    'baseProductCommit': baseProductCommit,
    'buildSha256': value['buildSha256'],
    'readyReceivedUs': readyReceivedUs,
  };
}

// Same one-time startup gate budget as the original ownership entrypoint.
// The gate is before schedule origin and all gauges, never at the q0 cut.
Future<Map<String, Object?>> waitForSampledQ0Ready(
  File file, {
  required String arm,
  required int hostPid,
  required String sourceCommit,
  required String baseProductCommit,
}) async {
  final deadline = Timeline.now + 60000000;
  while (Timeline.now < deadline) {
    if (file.existsSync()) {
      if (file.lengthSync() > 4096) {
        throw StateError('Sampled q0 startup identity exceeds fixed size');
      }
      final value = jsonDecode(file.readAsStringSync());
      final received = Timeline.now;
      if (received >= deadline) {
        throw StateError(
          'Sampled q0 startup identity timed out after 60 seconds',
        );
      }
      return validateSampledQ0Ready(
        value,
        arm: arm,
        hostPid: hostPid,
        sourceCommit: sourceCommit,
        baseProductCommit: baseProductCommit,
        readyReceivedUs: received,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('Sampled q0 startup identity timed out after 60 seconds');
}
