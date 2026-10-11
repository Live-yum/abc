// Diagnostic-only Linux x86_64 bridge. This never starts a profiler. The
// launcher and native initializer own provider/target identity verification;
// the supervisor independently verifies this hello before allowing WLD IO.
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

typedef _AbiNative = Uint32 Function();
typedef _AbiDart = int Function();
typedef _StatusNative = Int32 Function();
typedef _StatusDart = int Function();
typedef _AfterGaugeNative = Int32 Function(Int32, Uint64);
typedef _AfterGaugeDart = int Function(int, int);
typedef _MetadataNative = Pointer<_QuietMetadata> Function();
typedef _MetadataDart = Pointer<_QuietMetadata> Function();

// Keep field order and natural alignment identical to quiet_dump_bridge.h.
final class _QuietCut extends Struct {
  @Int32()
  external int cycle;
  @Int32()
  external int accepted;
  @Uint64()
  external int gaugeDartUs;
  @Uint64()
  external int enterNs;
  @Uint64()
  external int dumpStartNs;
  @Uint64()
  external int dumpEndNs;
  @Uint64()
  external int ackEndNs;
  @Uint64()
  external int exitNs;
  @Size()
  external int mapsBeforeSize;
  @Size()
  external int mapsAfterSize;
}

final class _QuietMetadata extends Struct {
  @Uint32()
  external int abi;
  @Uint32()
  external int offline;
  @Uint32()
  external int slotsUsed;
  @Uint32()
  external int dumpCount;
  @Uint32()
  external int stopCalls;
  @Int32()
  external int initialized;
  @Int32()
  external int failure;
  @Int32()
  external int stopRequested;
  @Int32()
  external int stopVerified;
  @Int32()
  external int cleanupFailure;
  @Uint64()
  external int observerPreallocatedBytes;
  @Uint64()
  external int stopStartNs;
  @Uint64()
  external int stopEndNs;
  @Uint64()
  external int observerMapsBytes;
  @Uint32()
  external int observerHeldFds;
  @Uint32()
  external int observerClosedFds;
  @Uint32()
  external int observerFdCloseAttempts;
  @Int32()
  external int observerFdCleanupFailure;
  @Array(2)
  external Array<_QuietCut> cuts;
}

class MemoryAllocationStackProbe {
  MemoryAllocationStackProbe._(
    this._library,
    this._initialize,
    this._afterGauge,
    this._stop,
    this._metadata,
    this._arm,
    this._helperPath,
    this._targetPath,
    this._outputPath,
  );

  static const _allocatorPath =
      '/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16';
  final DynamicLibrary _library;
  final _StatusDart _initialize, _stop;
  final _AfterGaugeDart _afterGauge;
  final _MetadataDart _metadata;
  final String _arm, _helperPath, _targetPath, _outputPath;
  // Two fixed Dart slots allocated before native initialization and hello.
  final _gaugeUs = Int64List(2), _enterUs = Int64List(2), _exitUs = Int64List(2);
  final _statuses = Int32List(2);
  Map<String, Object?>? _startup;
  int _attemptedCuts = 0;
  bool _initializationAttempted = false, _stopInvoked = false;

  static MemoryAllocationStackProbe open() {
    if (!Platform.isLinux || Abi.current() != Abi.linuxX64) {
      throw StateError('Stack attribution requires Linux x86_64');
    }
    // Cache these before native code clears profiler variables for children.
    final environment = Platform.environment;
    final arm = environment['ABC_STACK_ARM'];
    final helper = environment['ABC_STACK_HELPER'];
    final output = environment['ABC_STACK_OUTPUT'];
    if ((arm != 'probe-only' && arm != 'product-with-ownership') ||
        arm != environment['MEMORY_OWNER_ARM'] ||
        helper == null ||
        output == null ||
        !helper.startsWith('/') ||
        !output.startsWith('/') ||
        FileSystemEntity.typeSync(helper, followLinks: false) !=
            FileSystemEntityType.file ||
        FileSystemEntity.typeSync(output, followLinks: false) !=
            FileSystemEntityType.directory ||
        File(helper).resolveSymbolicLinksSync() != helper ||
        Directory(output).resolveSymbolicLinksSync() != output) {
      throw StateError('Sealed stack-attribution arm and paths required');
    }
    if (sizeOf<_QuietCut>() != 72 || sizeOf<_QuietMetadata>() != 232) {
      throw StateError('Stack-attribution native structure layout mismatch');
    }
    final library = DynamicLibrary.open(helper);
    final abi = library.lookupFunction<_AbiNative, _AbiDart>('abc_quiet_abi');
    if (abi() != 1) throw StateError('Stack-attribution native ABI mismatch');
    return MemoryAllocationStackProbe._(
      library,
      library.lookupFunction<_StatusNative, _StatusDart>(
        'abc_quiet_initialize',
      ),
      library.lookupFunction<_AfterGaugeNative, _AfterGaugeDart>(
        'abc_quiet_after_gauge',
      ),
      library.lookupFunction<_StatusNative, _StatusDart>('abc_quiet_stop'),
      library.lookupFunction<_MetadataNative, _MetadataDart>(
        'abc_quiet_metadata',
      ),
      arm!,
      helper,
      File('/proc/self/exe').resolveSymbolicLinksSync(),
      output,
    );
  }

  Map<String, Object?> get startup {
    final value = _startup;
    if (value == null) throw StateError('Stack-attribution startup unavailable');
    return value;
  }

  void initialize() {
    if (_initializationAttempted || _stopInvoked) {
      throw StateError('Stack-attribution initialization already consumed');
    }
    _initializationAttempted = true;
    final start = Timeline.now;
    final result = _initialize();
    final end = Timeline.now;
    final native = _nativeMetadata(includeCuts: false);
    final verified = result == 0 &&
        native['abi'] == 1 &&
        native['offline'] == 0 &&
        native['initialized'] == 1 &&
        native['failure'] == 0 &&
        native['slotsUsed'] == 0 &&
        native['dumpCount'] == 0 &&
        native['stopCalls'] == 0 &&
        native['stopRequested'] == 0 &&
        native['stopVerified'] == 0 &&
        native['cleanupFailure'] == 0 &&
        native['observerMapsBytes'] == 2097152 &&
        native['observerHeldFds'] == 3 &&
        native['observerClosedFds'] == 0 &&
        native['observerFdCloseAttempts'] == 0 &&
        native['observerFdCleanupFailure'] == 0;
    _startup = {
      'schema': 'abc.gperftools-application-startup.v1',
      'arm': _arm,
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
        // Derived from successful native initialize, not a later running query.
        'runningVerifiedAtInitialization': verified,
        'native': native,
      },
    };
    if (!verified) {
      throw StateError('Stack-attribution initialization failed: $result');
    }
  }

  // gaugeDartUs is a completion stamp taken immediately after await gauge()
  // returns, including its original write/flush. It is not the sample time.
  void afterGauge(int cycle, int gaugeDartUs) {
    if (!_initializationAttempted ||
        _startup == null ||
        _stopInvoked ||
        _attemptedCuts >= 2 ||
        cycle != (_attemptedCuts == 0 ? 0 : 7)) {
      throw StateError('Stack-attribution cut order or lifetime exceeded');
    }
    final slot = _attemptedCuts++;
    _gaugeUs[slot] = gaugeDartUs;
    _enterUs[slot] = Timeline.now;
    Timeline.startSync('abc.gperftools.released-quiet-end');
    try {
      // Ordinary synchronous FFI: native Dump and ACK may block. Never leaf.
      _statuses[slot] = _afterGauge(cycle, gaugeDartUs);
    } finally {
      Timeline.finishSync();
      _exitUs[slot] = Timeline.now;
    }
    if (_statuses[slot] != 0) {
      throw StateError('Stack-attribution cut failed: ${_statuses[slot]}');
    }
  }

  Map<String, Object?> _nativeMetadata({required bool includeCuts}) {
    final pointer = _metadata();
    if (pointer == nullptr) throw StateError('Native stack metadata unavailable');
    final value = pointer.ref;
    return {
      'abi': value.abi,
      'offline': value.offline,
      'initialized': value.initialized,
      'failure': value.failure,
      'slotsUsed': value.slotsUsed,
      'dumpCount': value.dumpCount,
      'stopCalls': value.stopCalls,
      'stopRequested': value.stopRequested,
      'stopVerified': value.stopVerified,
      'cleanupFailure': value.cleanupFailure,
      'observerPreallocatedBytes': value.observerPreallocatedBytes,
      'stopStartNs': value.stopStartNs,
      'stopEndNs': value.stopEndNs,
      'observerMapsBytes': value.observerMapsBytes,
      'observerHeldFds': value.observerHeldFds,
      'observerClosedFds': value.observerClosedFds,
      'observerFdCloseAttempts': value.observerFdCloseAttempts,
      'observerFdCleanupFailure': value.observerFdCleanupFailure,
      if (includeCuts)
        'cuts': [
          for (var i = 0; i < 2; i++)
            {
              'cycle': value.cuts[i].cycle,
              'accepted': value.cuts[i].accepted,
              'gaugeDartUs': value.cuts[i].gaugeDartUs,
              'enterNs': value.cuts[i].enterNs,
              'dumpStartNs': value.cuts[i].dumpStartNs,
              'dumpEndNs': value.cuts[i].dumpEndNs,
              'ackEndNs': value.cuts[i].ackEndNs,
              'exitNs': value.cuts[i].exitNs,
              'mapsBeforeSize': value.cuts[i].mapsBeforeSize,
              'mapsAfterSize': value.cuts[i].mapsAfterSize,
            },
        ],
    };
  }

  // Called once at the very entry to the original outer finally, on success
  // and failure. Core Stop is idempotent if a failed cut already stopped it.
  void stopAndWriteEvidence() {
    if (_stopInvoked) return;
    _stopInvoked = true;
    final start = Timeline.now;
    final result = _stop();
    final end = Timeline.now;
    final native = _nativeMetadata(includeCuts: true);
    final complete = result == 0 &&
        _attemptedCuts == 2 &&
        native['failure'] == 0 &&
        native['slotsUsed'] == 2 &&
        native['dumpCount'] == 2 &&
        native['stopCalls'] == 1 &&
        native['stopRequested'] == 1 &&
        native['stopVerified'] == 1 &&
        native['cleanupFailure'] == 0 &&
        native['observerHeldFds'] == 0 &&
        native['observerClosedFds'] == 3 &&
        native['observerFdCloseAttempts'] == 3 &&
        native['observerFdCleanupFailure'] == 0 &&
        (native['cuts'] as List).every((cut) => (cut as Map)['accepted'] == 1);
    final evidence = {
      'schema': 'abc.gperftools-dart-probe.v1',
      'arm': _arm,
      'hostPid': pid,
      'status': complete ? 'observed' : 'failed',
      'startup': _startup,
      'stopStatusCode': result,
      'stopStartUs': start,
      'stopEndUs': end,
      'dartClockDomain': 'dart:developer.Timeline.now',
      'nativeClockDomain': 'CLOCK_MONOTONIC nanoseconds',
      'clockDomainsComparable': false,
      'native': native,
      'dartCuts': [
        for (var i = 0; i < _attemptedCuts; i++)
          {
            'cycle': i == 0 ? 0 : 7,
            'gaugeDartUs': _gaugeUs[i],
            'enterUs': _enterUs[i],
            'exitUs': _exitUs[i],
            'statusCode': _statuses[i],
          },
      ],
    };
    // Sidecar stays outside original raw/. Encode only after profiler Stop.
    final file = File('$_outputPath/dart-probe.json');
    file.createSync(exclusive: true);
    file.writeAsStringSync(jsonEncode(evidence), flush: true);
    // Keep the DSO loaded through exit; never unload during the workload.
    assert(_library.providesSymbol('abc_quiet_metadata'));
    if (!complete) {
      throw StateError('Stack-attribution finalization incomplete: $result');
    }
  }
}
