#!/usr/bin/env python3
"""Inventory dispatcher actions without counting core calls as UI coverage.

This is a declared workload inventory, not proof of executed measurements. Join
operation IDs with passed runtime reports to establish actual measured coverage.
"""
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[2]
catalog_path = root / 'tool/perf/action_catalog.json'
catalog = json.loads(catalog_path.read_text())
native = '\n'.join((root / file).read_text() for file in (
    'test/performance/native_actions_test.dart',
    'test/performance/public_dispatch_actions_test.dart'))
declared = {row['id']: row for row in catalog['workspaceActions']}
for operation, action in re.findall(r"await action\(\s*'([^']+)'\s*,\s*'([^']+)'", native):
    variants = [operation.replace('$kind', kind) for kind in ('pixel', 'fusion', 'circuit')] if '$kind' in operation else [operation]
    for variant in variants:
        key = f'workspace.{variant}'
        declared.setdefault(key, {'id': key, 'action': action, 'variant': variant})
declared = {key: row for key, row in declared.items() if '$kind' not in key}
catalog['workspaceActions'] = sorted(declared.values(), key=lambda row: row['id'])
catalog_path.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + '\n')
by_action = {}
for row in declared.values():
    by_action.setdefault(row['action'], []).append(row['id'])
rows = []
for name, file in [('Workspace', 'lib/application/workspace.dart'), ('CircuitRulesWorkspace', 'lib/application/circuit_rules_workspace.dart')]:
    text = (root / file).read_text().split('Future<void> dispatch(', 1)[1]
    if name == 'Workspace':
        text = text.split('TerraCanvas get _fusionCanvas', 1)[0]
    actions = sorted({next(value for value in values if value) for values in re.findall(r"case '([^']+)':|action == '([^']+)'", text)})
    for action in actions:
        measured = by_action.get(action, []) if name == 'Workspace' else []
        if measured:
            reason = 'Declared measured workload; requires a matching operation row in a passed report. Only listed parameter variants count.'
        elif action.startswith('cloud'):
            reason = 'Cloud local protocol/storage suite owned separately; no real network measurement or direct dispatcher coverage claimed here.'
        elif 'Map' in action or action == 'importMap':
            reason = 'MAP codec/generation suite and profile application coverage owned separately; direct dispatcher timing not claimed here.'
        elif action.startswith('rules'):
            reason = 'Core full rules timings exist, but this UI controller lifecycle path is not yet timed directly in the native action suite.'
        elif action in ('activateOnlineResources',):
            reason = 'Online resource service local transport/storage suite owned separately; dispatcher activation needs a matching measured row.'
        elif action == 'generate':
            reason = 'Application explicitly reports no connected generation service; only failure behavior is available, not successful generation latency.'
        elif action == 'openSynthetic':
            reason = 'QA-only asset entry is disabled unless TERRAFORGE_QA is compiled true. This suite imports the same original synthetic files through the real FileGateway; it does not claim timing of this disabled production entry.'
        else:
            reason = 'Direct dispatcher action not yet included in native measured workload; functional tests alone are not performance coverage.'
        rows.append({'controller': name, 'action': action, 'operationIds': measured, 'status': 'declared' if measured else 'gap', 'availability': 'unsupported-service' if action == 'generate' else 'qa-only' if action == 'openSynthetic' else 'available', 'reason': reason})
out = {'schema': 'abc.performance-action-gaps.v1', 'worldCircuitWorkloadId': 'generic-wld-controls-v1', 'note': 'Source-complete dispatcher inventory. Declared is not executed. Join IDs with passed per-runtime reports; preserve gaps and parameter variants.', 'actions': rows}
(root / 'tool/perf/action_gaps.json').write_text(json.dumps(out, indent=2, ensure_ascii=False) + '\n')
print(f"{len(rows)} dispatcher actions; {sum(bool(row['operationIds']) for row in rows)} declared direct paths")
