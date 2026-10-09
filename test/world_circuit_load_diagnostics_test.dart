import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

WorldCircuitProgress _progress(Map<String, Object?> diagnostics) =>
    WorldCircuitProgress(
      stage: 'compile',
      phase: 2,
      completed: 6448,
      total: 15200,
      diagnostics: diagnostics,
    );

Future<void> _show(WidgetTester tester, Map<String, Object?> state) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldCircuitPanel(state: state, dispatch: (_, _) async {}),
          ),
        ),
      ),
    );

void main() {
  testWidgets('loading displays reported allocations and WASM capacity', (
    tester,
  ) async {
    await _show(tester, {
      'busy': true,
      'importing': true,
      'loadProgress': _progress({
        'nativeActiveBytes': 2 * 1048576,
        'nativePeakBytes': 3 * 1048576,
        'wasmHeapBytes': 16 * 1048576,
      }),
    });
    expect(find.text('编译真实接线 · 6448 / 15200'), findsOneWidget);
    expect(
      find.text('引擎分配 2.0 MiB · 峰值 3.0 MiB · WASM 容量 16.0 MiB'),
      findsOneWidget,
    );
    expect(find.text('引擎分配/峰值、WASM 容量，非进程内存；容量不等于实际占用。'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing or invalid byte counts are unavailable, never zero', (
    tester,
  ) async {
    for (final invalid in <Object?>[
      null,
      '1048576',
      true,
      -1,
      1.5,
      double.nan,
      double.infinity,
      9007199254740992,
    ]) {
      await _show(tester, {
        'busy': true,
        'importing': true,
        'loadProgress': _progress({
          'nativeActiveBytes': ?invalid,
          'nativePeakBytes': ?invalid,
          'wasmHeapBytes': ?invalid,
        }),
      });
      expect(
        find.text('引擎分配 不可得 · 峰值 不可得 · WASM 容量 不可得'),
        findsOneWidget,
        reason: 'Invalid byte count: $invalid',
      );
      expect(find.textContaining('0.0 MiB'), findsNothing);
    }
    await _show(tester, {
      'busy': true,
      'importing': true,
      'loadProgress': _progress({
        'nativeActiveBytes': 0,
        'wasmHeapBytes': 8388608.0,
      }),
    });
    expect(
      find.text('引擎分配 0.0 MiB · 峰值 不可得 · WASM 容量 8.0 MiB'),
      findsOneWidget,
      reason: 'A reported zero remains distinct from an unavailable field',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed import keeps the last sample until a new attempt', (
    tester,
  ) async {
    await _show(tester, {
      'busy': false,
      'importing': false,
      'loadError': 'worker failed',
      'error': 'worker failed',
      'loadProgress': _progress({'nativePeakBytes': 3 * 1048576}),
      'progress': const WorldCircuitProgress(
        stage: 'closed',
        phase: 0,
        completed: 0,
        total: 0,
        diagnostics: {'nativePeakBytes': 0},
      ),
    });
    expect(find.text('加载失败前的最后有效进度：编译真实接线 · 6448 / 15200'), findsOneWidget);
    expect(find.text('引擎分配 不可得 · 峰值 3.0 MiB · WASM 容量 不可得'), findsOneWidget);
    expect(find.text('worker failed'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await _show(tester, {'busy': true, 'importing': true});
    expect(find.textContaining('加载失败'), findsNothing);
    expect(find.textContaining('6448'), findsNothing);
    expect(find.textContaining('3.0 MiB'), findsNothing);
    expect(find.text('引擎分配 不可得 · 峰值 不可得 · WASM 容量 不可得'), findsOneWidget);
    await _show(tester, {'busy': false, 'importing': false});
    expect(find.textContaining('加载失败'), findsNothing);
    expect(find.textContaining('WASM 容量'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure before the first report does not invent a sample', (
    tester,
  ) async {
    await _show(tester, {'loadError': 'open failed', 'error': 'open failed'});
    expect(find.text('加载失败，未取得有效加载进度。'), findsOneWidget);
    expect(find.text('引擎分配 不可得 · 峰值 不可得 · WASM 容量 不可得'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
