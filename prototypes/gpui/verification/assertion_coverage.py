"""Reviewed behavior/stage join. A completed headless case never accepts a cell."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re


def _read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def validate_coverage(repo, matrix, cases):
    stages = {stage['id']: stage for stage in matrix['rustStages'] + matrix['databaseStages'] + matrix['sharedStages']}
    frozen = matrix['frozenInputs']
    for relative, expected in frozen.items():
        path = repo / relative
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('Frozen reference input differs from its reviewed exact bytes.')
    registry = _read(repo / matrix['nativeAcceptance']['registry'])
    scenarios = _read(repo / matrix['nativeAcceptance']['scenarios'])
    features = {item['id'] for item in registry['features']}
    scenario_features = {item['feature'] for item in scenarios['scenarios']}
    assertions = sum(len(step['assertions']) for item in scenarios['scenarios'] for step in item['steps'])
    cells = [result for item in registry['features'] for result in item['results'].values()]
    if (len(features) != 57 or scenario_features != features or assertions != 190 or len(cells) != 171
            or any(cell['status'] != 'not-run' for cell in cells)
            or set(matrix['featureBindings']) != features):
        raise ValueError('The complete frozen 57-feature/190-assertion/171-cell contract is required.')
    case_ids = {case['id'] for case in cases['cases']}
    if len(case_ids) != len(cases['cases']):
        raise ValueError('Behavior group IDs must be unique.')
    for feature, groups in matrix['featureBindings'].items():
        if not groups or set(groups) - case_ids:
            raise ValueError('Every frozen feature needs reviewed actual behavior groups.')
    for case in cases['cases']:
        bindings = case['executions']
        if (not bindings or {binding['assertion'] for binding in bindings} != set(case['assertions'])
                or len(bindings) != len(case['assertions'])):
            raise ValueError('Every behavior assertion needs exactly one explicit execution binding.')
        for binding in bindings:
            source, symbol = binding['assertion'].split('#', 1)
            text = (repo / source).read_text(encoding='utf-8')
            if source.endswith('.rs') and not re.search(
                    r'#\[(?:[A-Za-z_][A-Za-z0-9_]*::)*test(?:\([^]]*\))?\]\s*(?:#\[[^]]+\]\s*)*(?:async\s+)?fn\s+' + re.escape(symbol) + r'\b', text):
                raise ValueError('Behavior binding is not an actual test assertion.')
            selected = binding['stages']
            if not selected or len(set(selected)) != len(selected) or set(selected) - set(stages):
                raise ValueError('Behavior assertion has no exact selected stage.')
            for stage_id in selected:
                stage = stages[stage_id]
                if set(binding.get('hosts', stage['hosts'])) - set(stage['hosts']):
                    raise ValueError('Behavior assertion cannot widen its original native host scope.')
                required = stage.get('requiredSuffixes', []) + stage.get('requiredTests', [])
                required += [name for names in stage.get('requiredSuffixesByHost', {}).values() for name in names]
                if not any(name == symbol or name.endswith('::' + symbol) or name.endswith('/' + symbol) for name in required):
                    raise ValueError('Behavior assertion is not mandatory in its declared stage.')
    if set(matrix['f57Requirements']) != {'nativeRust', 'databaseVersionsAndTls', 'sharedGo', 'macosSwiftUI', 'nativeDesktops', 'installedUpdate', 'physicalLostAck', 'ownershipAndCleanup'}:
        raise ValueError('All F57 proof layers must remain explicit.')


def behavior_evidence(matrix, cases, ledger):
    declared = {stage['id']: stage for stage in matrix['rustStages'] + matrix['databaseStages'] + matrix['sharedStages']}
    actual = {stage['id']: stage for stage in ledger['stages']}
    host = ledger['host']['os']
    result = []
    for case in cases['cases']:
        assertions = []
        for binding in case['executions']:
            symbol = binding['assertion'].split('#', 1)[1]
            evidence = []
            for stage_id in binding['stages']:
                stage, observed = declared[stage_id], actual.get(stage_id)
                status = 'pending'
                if host not in stage['hosts'] or host not in binding.get('hosts', stage['hosts']):
                    status = 'host-not-applicable'
                elif observed:
                    names = [row['id'] for run in observed.get('runs', [observed.get('proof', {})]) for row in run.get('tests', []) if row['outcome'] == 'ok']
                    count = sum(name == symbol or name.endswith('::' + symbol) or name.endswith('/' + symbol) for name in names)
                    ignored = [name for run in observed.get('runs', [observed.get('proof', {})]) for name in run.get('ignored', [])]
                    critical_skipped = any(name == symbol or name.endswith('::' + symbol) or name.endswith('/' + symbol) for name in ignored)
                    status = 'passed-in-declared-layer' if observed['status'] == 'passed' and count == 1 and not critical_skipped else 'failed'
                evidence.append({'stage': stage_id, 'status': status})
            assertions.append({'assertion': binding['assertion'], 'stages': evidence})
        result.append({'id': case['id'], 'assertions': assertions, 'nativeAcceptanceEstablished': False,
                       'remainingNative': case['remainingNative']})
    return {'cases': result, 'frozenFeatures': 57, 'frozenAssertions': 190, 'nativeCells': 171,
            'nativeAcceptanceEstablished': False, 'f57Complete': False,
            'f57Requirements': matrix['f57Requirements']}
