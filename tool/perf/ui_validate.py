#!/usr/bin/env python3
"""Reject absent/debug/partial UI evidence without inventing speed thresholds."""
import argparse
import json
import math
from pathlib import Path

HEAP_MEASUREMENT_METHOD = 'vm-service-isolate-groups-v1'

REQUIRED = {
    'ui.workspace.mount', 'ui.workspace.close', 'ui.wld.import',
    'ui.wld.reopen', 'ui.wld.pan-zoom', 'ui.wld.overlay-controls',
    'ui.wld.header-edit', 'ui.wld.undo', 'ui.wld.redo', 'ui.wld.export-reopen',
    'ui.chest.slot-edit', 'ui.chest.organize', 'ui.chest.clear',
    'ui.world-rules.preview', 'ui.world-rules.apply',
    'ui.plr.create', 'ui.plr.inventory-edit', 'ui.plr.export-reopen',
    'ui.pixel.draw', 'ui.region.load', 'ui.region.pan-zoom',
    'ui.circuit.copy', 'ui.circuit.paste', 'ui.circuit.route-commit',
    'ui.circuit.tick', 'ui.circuit.run-pause', 'ui.circuit.reopen',
    'ui.tcw.open', 'ui.tcw.viewport', 'ui.tcw.trigger', 'ui.tcw.tick',
    'ui.tcw.run-pause', 'ui.tcw.reset', 'ui.tcw.reopen', 'ui.tcw.close',
    'ui.rules.open', 'ui.rules.copy', 'ui.rules.paste',
    'ui.rules.route-commit', 'ui.rules.pan-zoom', 'ui.rules.tick60',
    'ui.rules.run-pause', 'ui.rules.reset', 'ui.rules.reopen',
    'ui.resources.cancel', 'ui.resources.corrupt-failure',
    'ui.resources.retry-install', 'ui.import-dialog.cancel',
    'ui.resources.check-version', 'ui.resources.atomic-failure',
    'ui.resources.atomic-retry', 'ui.resources.offline-restore',
    'ui.picker.cancel', 'ui.wld.failed-import', 'ui.export.cancel',
    'ui.map.legacy.import', 'ui.map.legacy.pan-zoom', 'ui.map.legacy.edit',
    'ui.map.legacy.undo', 'ui.map.legacy.redo', 'ui.map.legacy.export-reopen',
    'ui.map.chunked.import', 'ui.map.chunked.pan-zoom', 'ui.map.chunked.edit',
    'ui.map.chunked.undo', 'ui.map.chunked.redo', 'ui.map.chunked.export-reopen',
    'ui.map.generate-from-wld', 'ui.map.picker-cancel',
}
REQUIRED_DISPATCHES = {
    'rulesOpen', 'rulesNew', 'rulesDemo', 'rulesEdit', 'rulesPreviewRoute',
    'rulesPreviewNetwork', 'rulesCommitPreview', 'rulesCancelPreview',
    'rulesSimulate', 'rulesReset', 'rulesImport', 'rulesExport',
    'rulesToggleRun', 'rulesPause', 'rulesDebug', 'rulesClose', 'rulesRecover',
    'importMap', 'editMapRect', 'undoMap', 'redoMap', 'exportMap', 'closeMap',
    'generateMapFromWorld', 'activateOnlineResources',
}


def validate(report):
    errors = []
    if report.get('schema') != 'abc.performance.v1':
        errors.append('Wrong report schema')
    if report.get('suite') != 'flutter-ui' or report.get('buildMode') != 'profile':
        errors.append('Actual Flutter profile UI report required')
    if report.get('status') != 'passed':
        errors.append('Run failed or was only a debug smoke test')
    if not report.get('runId'):
        errors.append('Missing independent process run ID')
    runtime = report.get('runtime', {})
    for field in ('platform', 'osVersion', 'dartVersion', 'flutterVersion', 'commit', 'checkedOutHead', 'runner', 'renderer'):
        if runtime.get(field) in (None, '', 'unspecified'):
            errors.append(f'Missing environment metadata: {field}')
    if runtime.get('workingTreeDirty') is not False:
        errors.append('Profile acceptance requires a verified clean Git snapshot')
    for field in ('physicalWidth', 'physicalHeight', 'devicePixelRatio'):
        value = runtime.get(field)
        if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            errors.append(f'Invalid viewport metadata: {field}')
    operations = {row['id']: row for row in report.get('operations', [])}
    errors.extend('Missing operation: ' + op for op in sorted(REQUIRED - operations.keys()))
    for op, row in operations.items():
        if row.get('status') != 'passed':
            errors.append(f'{op}: incomplete operation')
        if row.get('iterations') != report.get('iterations'):
            errors.append(f'{op}: incomplete repetitions')
        if row.get('frameCount', 0) < 1:
            errors.append(f'{op}: no real engine frame timings')
        if not row.get('samples') or not all(s.get('success') for s in row['samples']):
            errors.append(f'{op}: failed/missing raw samples')
        for sample in row.get('samples', []):
            ui, raster = sample.get('uiUs', []), sample.get('rasterUs', [])
            if not ui or len(ui) != len(raster):
                errors.append(f'{op}: iteration without matching UI/raster frame samples')
            if any(not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0 for v in ui + raster):
                errors.append(f'{op}: invalid frame duration')
    controllers = report.get('controllerOperations', [])
    actions = {row.get('action') for row in controllers}
    errors.extend('Missing direct controller dispatch: ' + action
                  for action in sorted(REQUIRED_DISPATCHES - actions))
    for row in controllers:
        if not row.get('sampleCount') or not row.get('samples'):
            errors.append(f"{row.get('id')}: missing controller latency samples")
        for sample in row.get('samples', []):
            value = sample.get('durationMs')
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                errors.append(f"{row.get('id')}: invalid dispatch latency")
    memory = report.get('memory', [])
    if len(memory) != report.get('iterations', 0) + report.get('warmup', 0):
        errors.append('Missing lifecycle memory snapshots')
    if report.get('runtime', {}).get('platform') != 'web':
        if runtime.get('heapMeasurementMethod') != HEAP_MEASUREMENT_METHOD:
            errors.append('Native heap evidence must count unique isolate groups')
        for row in memory:
            groups, isolates = row.get('sampledIsolateGroups'), row.get('sampledIsolates')
            if (row.get('heapMeasurementMethod') != HEAP_MEASUREMENT_METHOD or
                    row.get('gc') != 'requested-all-isolate-groups' or
                    not isinstance(groups, int) or not isinstance(isolates, int) or
                    groups < 1 or isolates < groups):
                errors.append('Invalid unique isolate-group heap sample')
        if any(row.get('rssBytes') is None or row.get('heapUsedBytes') is None for row in memory):
            errors.append('Missing native RSS/VM heap evidence')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    errors = validate(json.loads(args.report.read_text()))
    for error in errors:
        print(error)
    if errors:
        raise SystemExit(1)
    print('Profile UI evidence complete. Speed and memory stability remain baseline-dependent.')


if __name__ == '__main__':
    main()
