#!/usr/bin/env python3
"""Join declared dispatcher coverage to actual validated reports, without pooling runs."""
import argparse
from collections import Counter
import csv
import json
from pathlib import Path

from compare import validate as validate_core
from ui_validate import validate as validate_ui
from computerraria_compare import validate_profile as validate_computer_profile
from computerraria_compare import validate_execution as validate_computer_execution

# Audited exact awaited Workspace.dispatch calls in cloud_actions_test.dart.
# These are local injected HTTP/auth measurements, never live service or frames.
LOCAL_CLOUD_DISPATCHES = {
    'cloud.upload.prepare_snapshot': 'cloudPrepareUpload',
    'cloud.upload.hash_duplicate_multipart_commit': 'cloudUploadPrepared',
    'cloud.download.binary_native_vault_commit': 'cloudRecommendationDownload',
    'cloud.receipt.pending_after_cached_adoption': 'cloudRecommendationDownload',
}

# Exact actions occurring inside these audited production pointer/key workflows.
# The recorded duration remains the ENTIRE macro; it is never divided among
# its actions or relabelled as direct dispatcher duration.
COMPUTER_WORKFLOW_ACTIONS = {
    'computer.choose-world': ('worldCircuitChooseWorld',),
    'computer.reselect-exported-world': ('worldCircuitChooseWorld',),
    'computer.cancel-import': ('worldCircuitImport', 'worldCircuitCancel'),
    'computer.import': ('worldCircuitImport',),
    'computer.reimport-resume': ('worldCircuitImport',),
    'computer.load-pong': ('worldCircuitLoadPong',),
    'computer.load-program': ('worldCircuitLoadProgram',),
    'computer.restore-pong-after-program': ('worldCircuitLoadPong',),
    'computer.refresh-display': ('worldCircuitRefreshDisplay',),
    'computer.enable-optimization': ('worldCircuitOptimization',),
    'computer.idle-mode-roundtrip': ('worldCircuitOptimization',),
    'computer.same-program-input-trace': ('worldCircuitInput', 'worldCircuitStep'),
    'computer.run-physical-program': ('worldCircuitToggle', 'worldCircuitPause'),
    'computer.keyboard-up': ('worldCircuitInput',),
    'computer.keyboard-down': ('worldCircuitInput',),
    'computer.keyboard-left': ('worldCircuitInput',),
    'computer.keyboard-right': ('worldCircuitInput',),
    'computer.touch-hold-down': ('worldCircuitInput',),
    'computer.single-physical-clock': ('worldCircuitStep',),
    'computer.export-world': ('worldCircuitSave',),
    'computer.close-exported': ('worldCircuitClose',),
    'computer.close': ('worldCircuitClose',),
    'computer.reset-original': ('worldCircuitReset',),
}


def read_reports(root):
    reports, failures = [], []
    for path in sorted(Path(root).rglob('*.json')):
        try:
            report = json.loads(path.read_text())
            if not isinstance(report, dict):
                continue
            if (report.get('schema') == 2 and report.get('inputFormat') == 'wld-only'
                    and report.get('buildMode') == 'profile'):
                execution_path = path.with_suffix('.execution.json')
                if not execution_path.is_file():
                    # A standalone mirror is not another independent run.
                    continue
                commit = report['runtime']['commit']
                validate_computer_profile(report, commit, report['cycles'])
                execution = validate_computer_execution(
                    execution_path, path, 'computerraria-ui', commit)
                report = {**report, 'suite': 'computerraria-ui',
                    'schema': 'abc.performance.v1', 'runId': execution['runId'],
                    'tier': 'public-complete-computerraria',
                    'fixtures': [report['fixture']]}
                reports.append((str(path), report))
                continue
            if report.get('schema') != 'abc.performance.v1':
                continue
            if report.get('suite') == 'flutter-ui':
                errors = validate_ui(report)
                if errors:
                    raise ValueError('; '.join(errors))
            else:
                validate_core(report)
            reports.append((str(path), report))
        except (ValueError, AssertionError, KeyError, TypeError, OSError) as error:
            failures.append({'report': str(path), 'reason': str(error)})
    return reports, failures


def memory_summary(report):
    samples = report.get('memory', [])
    keys = {key for sample in samples for key in sample
            if key.endswith('Bytes') or key == 'ownedHandles'}
    return {'scope': 'whole process/cycle; not attributed to this operation',
            'samples': len(samples),
            'observedMax': {key: max(sample[key] for sample in samples
                                     if isinstance(sample.get(key), (int, float)))
                            for key in sorted(keys)
                            if any(isinstance(sample.get(key), (int, float)) for sample in samples)}}


def evidence_row(path, report, operation, kind, **extra):
    runtime = report.get('runtime')
    source = report.get('source', {}) if isinstance(runtime, str) else {
        'commit': runtime.get('commit'), 'worktreeCommit': runtime.get('checkedOutHead'),
        'dirty': runtime.get('workingTreeDirty')}
    return {
        'category': kind, 'controller': None, 'action': None,
        'operation': operation['id'], 'variant': operation.get('variant', {}),
        'suite': report['suite'], 'runtime': runtime,
        'buildMode': report.get('buildMode'), 'tier': report.get('tier'),
        'fixture': operation.get('fixture', 'public-synthetic profile scenario'),
        'phase': operation.get('phase', 'warm'),
        'iterations': operation.get('iterations', operation.get('sampleCount')),
        'warmup': operation.get('warmup', operation.get('warmupSampleCount')),
        'medianMs': operation.get('medianMs'), 'p95Ms': operation.get('p95Ms'),
        'maxMs': operation.get('maxMs'),
        'frames': ({key: operation.get(key) for key in
                    ('frameCount', 'ui', 'raster', 'overBudgetFrames', 'frameBudgetUs')}
                   if 'frameCount' in operation else None),
        'memory': memory_summary(report), 'provenance': report.get('fixtures', []),
        'source': source, 'runId': report.get('runId'), 'report': path,
        'measured': True, 'status': 'measured',
        'evidenceTier': 'clean-source' if source.get('dirty') is False else 'smoke-only',
        'gap': None, **extra,
    }


def build_coverage(inventory, reports, rejected):
    rows, matched, direct_profile, direct_dispatch, profile_workflow = [], set(), set(), set(), set()
    declarations = {}
    actions = {(row['controller'], row['action']): row for row in inventory['actions']}
    for action in inventory['actions']:
        for operation in action['operationIds']:
            declarations.setdefault(operation, []).append(action)
    for path, report in reports:
        is_ui = report['suite'] in ('flutter-ui', 'computerraria-ui')
        for operation in report['operations']:
            if report['suite'] == 'computerraria-ui':
                macro = operation['id'].rsplit('.', 1)[0]
                for name in COMPUTER_WORKFLOW_ACTIONS.get(macro, ()):
                    key = ('Workspace', name)
                    if key not in actions:
                        continue
                    profile_workflow.add(key)
                    rows.append(evidence_row(path, report, operation, 'controller-profile-workflow',
                        controller=key[0], action=key[1],
                        measurementScope='Contains this exact action in a verified full-world UI workflow; duration is the whole macro, not isolated dispatch latency'))
            explicit = (operation.get('controller'), operation.get('action'))
            direct = (report['suite'] == 'public-dispatch-actions'
                      and explicit in actions
                      and operation.get('dispatchEvidence') == 'awaited-production-dispatch'
                      and operation.get('completion') == 'returned-and-state-asserted')
            local_action = (LOCAL_CLOUD_DISPATCHES.get(operation['id'])
                            if report['suite'] == 'cloud-client-local' else None)
            local_key = ('Workspace', local_action)
            if local_key in actions:
                direct_dispatch.add(local_key)
                rows.append(evidence_row(path, report, operation, 'controller-local',
                    controller=local_key[0], action=local_key[1],
                    measurementScope='Production Workspace dispatcher with synthetic HTTP/auth; no live service or frames'))
                continue
            if direct:
                direct_dispatch.add(explicit)
                if operation['id'] in actions[explicit]['operationIds']:
                    matched.add((*explicit, operation['id']))
                rows.append(evidence_row(path, report, operation, 'controller-direct',
                    controller=explicit[0], action=explicit[1],
                    measurementScope='Exact awaited production dispatch; real native codecs, synthetic catalog; cloud uses local injected HTTP/auth; no frames'))
                continue
            declared = declarations.get(operation['id'], []) if not is_ui else []
            if declared:
                for action in declared:
                    key = (action['controller'], action['action'], operation['id'])
                    matched.add(key)
                    rows.append(evidence_row(path, report, operation, 'controller-core',
                                             controller=key[0], action=key[1],
                                             variant={'declaredOperation': key[2]}))
            else:
                category = ('profile-workflow' if is_ui else 'map-core' if 'map' in report['suite']
                            else 'service-core' if report['suite'] in
                            ('cloud-client-local', 'online-resource-actions') else 'core-api')
                rows.append(evidence_row(path, report, operation, category))
        if is_ui:
            for operation in report.get('controllerOperations', []):
                candidates = [key for key in actions if key[1] == operation['action']]
                if len(candidates) != 1:
                    # An unknown/ambiguous name does not establish declared dispatcher coverage.
                    rows.append(evidence_row(path, report, operation, 'unmapped-profile-dispatch',
                                             gap='Controller identity not uniquely mapped to inventory'))
                    continue
                key = candidates[0]
                direct_profile.add(key)
                rows.append(evidence_row(path, report, operation, 'controller-profile',
                                         controller=key[0], action=key[1],
                                         frameScopes=sorted({sample['macroScope'] for sample in
                                                             operation.get('samples', [])
                                                             if sample.get('macroScope')})))
    summary = []
    for key, action in actions.items():
        measured = [operation for operation in action['operationIds'] if (*key, operation) in matched]
        missing = [operation for operation in action['operationIds'] if (*key, operation) not in matched]
        has_profile = key in direct_profile
        has_direct = key in direct_dispatch
        has_workflow = key in profile_workflow
        unavailable = action['availability'] in ('qa-only', 'unsupported-service')
        summary.append({'controller': key[0], 'action': key[1],
                        'availability': action['availability'],
                        'declaredCoreOperations': action['operationIds'],
                        'measuredCoreOperations': measured, 'missingCoreOperations': missing,
                        'profileDispatchMeasured': has_profile,
                        'directDispatchMeasured': has_direct,
                        'profileWorkflowMeasured': has_workflow,
                        'scope': 'Only the recorded fixtures, runtimes and parameter variants count.',
                        'status': ('measured' if measured or has_profile or has_direct or has_workflow else
                                   'not-applicable' if unavailable else 'gap'),
                        'gap': action['reason'] if not measured and not has_profile and not has_direct and not has_workflow else None})
        # Keep missing declared variants even if another variant/action was measured.
        for operation in missing or ([None] if not measured and not has_profile and not has_direct and not has_workflow else []):
            rows.append({'category': 'declared-gap', 'controller': key[0], 'action': key[1],
                         'operation': operation, 'variant': {}, 'measured': False,
                         'status': 'not-applicable' if unavailable else 'declared' if operation else 'gap',
                         'gap': action['reason'], 'report': None})
    return {'schema': 'abc.performance-coverage.v1',
            'status': 'partial' if rejected else 'assembled',
            'note': 'Measured means a passed validated workload, not regression acceptance. '
                    'Core APIs never count as UI dispatcher or actual frame evidence. '
                    'Per-process values remain separate; no outlier/run is removed or pooled.',
            'reportCount': len(reports), 'rejectedReports': rejected,
            'counts': dict(Counter(row['category'] for row in rows)),
            'actions': summary, 'rows': rows}


def write_reports(result, output):
    output.mkdir(parents=True, exist_ok=True)
    (output / 'coverage.json').write_text(json.dumps(result, indent=2) + '\n')
    fields = ['category', 'controller', 'action', 'operation', 'variant', 'suite',
              'runtime', 'buildMode', 'tier', 'fixture', 'phase', 'iterations', 'warmup',
              'medianMs', 'p95Ms', 'maxMs', 'frames', 'frameScopes', 'measurementScope', 'memory', 'provenance',
              'source', 'runId', 'report', 'measured', 'status', 'evidenceTier', 'gap']
    with (output / 'coverage.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        for row in result['rows']:
            writer.writerow({key: json.dumps(value, separators=(',', ':'))
                             if isinstance(value, (dict, list)) else value
                             for key, value in row.items()})
    lines = ['# Actual performance coverage', '', result['note'], '',
             f"Validated reports: {result['reportCount']}; rejected/incomplete: {len(result['rejectedReports'])}.", '',
             '| Controller | Action | Declared operation variants measured/declared | Profile dispatch | Direct/local dispatch | Contains action in profile workflow | Gap |',
             '|---|---|---:|---|---|---|---|']
    for row in result['actions']:
        lines.append(f"| {row['controller']} | {row['action']} | "
                     f"{len(row['measuredCoreOperations'])}/{len(row['declaredCoreOperations'])} | "
                     f"{'measured' if row['profileDispatchMeasured'] else 'unmeasured'} | "
                     f"{'measured' if row['directDispatchMeasured'] else 'unmeasured'} | "
                     f"{'measured macro only' if row['profileWorkflowMeasured'] else 'unmeasured'} | {row['gap'] or ', '.join(row['missingCoreOperations'])} |")
    lines += ['', '## Per-process operation evidence', '',
              'Full memory, frame, source and fixture provenance is in coverage.json/coverage.csv and the linked raw reports.', '',
              '| Kind | Action / operation | Run / runtime | Fixture / phase | N / warmup | Median / p95 / max (ms) | Frames |',
              '|---|---|---|---|---:|---|---:|']
    for row in result['rows']:
        if not row['measured']:
            continue
        runtime = row['runtime'] if isinstance(row['runtime'], str) else row['runtime'].get('platform')
        lines.append(f"| {row['category']} | {row['action'] or ''} / {row['operation']} | "
                     f"{Path(row['report']).name} / {runtime} | {row['fixture']} / {row['phase']} | "
                     f"{row['iterations']} / {row['warmup']} | {row['medianMs']} / {row['p95Ms']} / {row['maxMs']} | "
                     f"{(row['frames'] or {}).get('frameCount', 'unmeasured')} |")
    (output / 'coverage.md').write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reports', required=True, type=Path)
    parser.add_argument('--inventory', default='tool/perf/action_gaps.json', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    reports, failures = read_reports(args.reports)
    result = build_coverage(json.loads(args.inventory.read_text()), reports, failures)
    write_reports(result, args.output)
    print(f"{result['reportCount']} validated reports; {len(failures)} invalid/partial reports retained")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
