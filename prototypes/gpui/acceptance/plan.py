"""Strict concrete plan/coverage contract. Source fragments cannot self-accept."""
from __future__ import annotations
import re
from recipes.coverage import build
from recipes.fragments import catalog as fragments

ENGINES = {'postgresql', 'mysql'}
KEY = re.compile(r'[a-z][a-z0-9-]{0,63}\Z')
SHA = re.compile(r'[0-9a-f]{64}\Z')
# Each tuple is (required fields, optional fields). Unknown fields always refuse.
SCHEMAS = {
    'native': ({'action', 'selector'}, {'input', 'readValue', 'expectedSha256', 'nativeAction', 'pin', 'expectExit', 'window'}),
    'wait-native': ({'selector'}, {'expectedSha256', 'focused', 'timeout', 'window'}),
    'native-text-select': ({'selector', 'input', 'start', 'end', 'pin'}, {'window'}),
    'native-text-assert': ({'selector', 'input', 'start', 'end', 'pin', 'assertion'}, {'window'}),
    'native-semantic-assert': ({'selector', 'expected', 'pin', 'assertion'}, {'window'}),
    'capture-state': ({'capture'}, {'populated'}),
    'assert-state-same': ({'capture', 'assertion'}, {'populated'}),
    'assert-state-expected': ({'expected', 'assertion'}, set()),
    'assert-settings-expected': ({'expected', 'assertion'}, {'theme'}),
    'capture-theme-set': ({'capture'}, set()),
    'capture-imported-theme': ({'capture', 'before', 'source'}, set()),
    'capture-recovered-theme': ({'capture', 'source'}, set()),
    'settings-close-restart': ({'expected', 'assertion'}, {'theme'}),
    'capture-profile-set': ({'capture'}, set()),
    'capture-profile-id': ({'capture', 'engine', 'before', 'nameInput'}, set()),
    'assert-profile-policy': ({'profileId', 'expected', 'assertion'}, set()),
    'observer-capture': ({'capture', 'engine', 'query'}, set()),
    'capture-physical-sessions': ({'capture', 'engine'}, set()),
    'assert-physical-sessions': ({'capture', 'engine', 'added', 'removed', 'assertion'}, {'postgresTransaction'}),
    'assert-observer-same': ({'capture', 'engine', 'query', 'assertion'}, set()),
    'assert-observer-rows': ({'engine', 'query', 'rows', 'columns', 'assertion'}, set()),
    'assert-observer-oracle': ({'engine', 'query', 'oracle', 'assertion'}, {'case', 'suffix'}),
    'wait-server-count': ({'engine', 'query', 'equals', 'assertion'}, {'timeout'}),
    'transfer-check': ({'path', 'assertion'}, {'expectedSource'}),
    'export-check': ({'path', 'engine', 'oracle', 'assertion'}, set()),
    'stage-input': ({'source'}, set()),
    'credential-reserve': ({'profileId', 'capture'}, set()),
    'credential-create': ({'capture', 'value'}, set()),
    'credential-arm-ui-write': ({'capture', 'value'}, set()),
    'credential-arm-ui-update': ({'capture', 'value'}, set()),
    'credential-arm-ui-delete': ({'capture'}, set()),
    'credential-verify': ({'capture', 'absent', 'empty', 'assertion'}, {'outcome'}),
    'file-capture': ({'capture', 'file'}, set()),
    'file-assert-same': ({'capture', 'assertion'}, set()),
    'file-backup-check': ({'capture', 'file', 'assertion'}, set()),
    'file-backup-discover': ({'capture', 'assertion'}, set()),
    'file-block-replacement': ({'capture', 'barrier'}, set()),
    'file-check-barrier': ({'barrier', 'assertion'}, set()),
    'file-release-barrier': ({'barrier'}, set()),
    'persistence-case': ({'case', 'actions', 'assertion'}, set()),
    'normal-close': (set(), set()),
    'restart': (set(), {'assertion'}),
    'effects-setup': ({'engine'}, set()),
    'relay-start': ({'engine', 'capture'}, set()),
    'relay-pin-catalog': ({'engine', 'capture', 'profileId', 'selector', 'expectedSha256', 'pin'}, set()),
    'relay-prepare-apply': ({'engine', 'capture', 'prepareSelector', 'preparePin', 'reviewSelector', 'reviewExpectedSha256', 'reviewPin'}, set()),
    'relay-lost-apply-ack': ({'engine', 'capture', 'applySelector', 'applyPin',
                            'unknownSelector', 'unknownExpectedSha256', 'unknownPin', 'retrySelector', 'retryPin', 'assertion'}, set()),
    'relay-lost-commit-ack': ({'engine', 'capture', 'idleSelector', 'idleExpectedSha256', 'idlePin',
                               'transactionSelector', 'transactionExpectedSha256', 'transactionPin',
                               'editorSelector', 'editorPin',
                               'commitSelector', 'commitPin', 'stopSelector', 'stopPin',
                               'unknownSelector', 'unknownExpectedSha256', 'unknownPin', 'retrySelector', 'retryPin', 'assertion'}, set()),
    'join-completed-matrix': ({'assertion'}, set()),
    # Pending gates are executable refusals, never a generic manual pass flag.
    'capability-required': ({'capability', 'assertion'}, set()),
    'manual-required': ({'reason'}, set()),
}
# Partial checks are deliberately narrow. A complete assertion may need multiple
# actions and explicit pending gates for requirements not implemented by the DSL.
SUPPORTS = {
    'native': {'native-bindings'},
    'native-text-assert': {'text-range', 'native-bindings'},
    'native-semantic-assert': {'typed-grid', 'native-bindings'},
    'assert-profile-policy': {'captured-uuid'},
    'assert-state-expected': {'source-state'},
    'assert-settings-expected': {'settings-oracle'},
    'settings-close-restart': {'settings-oracle', 'lifecycle'},
    'relay-lost-commit-ack': {'fault-boundary', 'owned-effects'},
    'relay-lost-apply-ack': {'fault-boundary', 'owned-effects'},
    'assert-observer-oracle': {'expected-metadata', 'owned-effects'},
    'assert-physical-sessions': {'session-observer'},
    'assert-observer-rows': {'expected-metadata'},
    'credential-verify': {'credential-update'},
    'file-assert-same': {'file-fault'},
    'file-backup-check': {'file-fault'},
    'file-backup-discover': {'file-fault'},
    'file-check-barrier': {'file-fault'},
    'persistence-case': {'file-fault', 'lifecycle'},
    'restart': {'lifecycle'},
    'transfer-check': {'fixed-inputs'},
    'export-check': {'expected-metadata'},
    'join-completed-matrix': {'matrix-join'},
}


def validate_action(item):
    if not isinstance(item, dict) or item.get('op') not in SCHEMAS:
        raise ValueError('Unknown concrete workflow operation.')
    required, optional = SCHEMAS[item['op']]
    if not required.issubset(item) or set(item) - required - optional - {'op', 'assertion', 'requirement', 'engine'}:
        raise ValueError('Workflow operation schema differs.')
    if 'engine' in item and item['engine'] not in ENGINES:
        raise ValueError('Exact supported engine family required.')
    for field in ('capture', 'before', 'pin', 'barrier', 'commitPin', 'stopPin', 'retryPin', 'idlePin', 'transactionPin', 'unknownPin', 'editorPin', 'preparePin', 'reviewPin', 'applyPin'):
        if field in item and (not isinstance(item[field], str) or not KEY.fullmatch(item[field])):
            raise ValueError('Capture keys must be bounded semantic keys.')
    if 'expectedSha256' in item and not SHA.fullmatch(str(item['expectedSha256'])):
        raise ValueError('Independent expected hash is invalid.')
    if any(key.endswith('Sha256') and not SHA.fullmatch(str(value)) for key, value in item.items()):
        raise ValueError('Independent expected native hash is invalid.')
    for field in ('populated', 'readValue', 'expectExit', 'absent', 'empty', 'focused'):
        if field in item and type(item[field]) is not bool:
            raise ValueError('Workflow boolean must be explicit.')
    if 'timeout' in item and (type(item['timeout']) not in (int, float) or not 0 < item['timeout'] <= 60):
        raise ValueError('Workflow timeout exceeds bound.')
    if item['op'] == 'native':
        if item['action'] not in {'inspect', 'assert', 'focus', 'invoke', 'select', 'scroll', 'set-text'}:
            raise ValueError('Unsupported native action.')
        if item.get('expectExit'):
            raise ValueError('Common Close is owned by the lifecycle controller.')
        if 'assertion' in item and (item['action'] != 'assert' or not item.get('expectedSha256')):
            raise ValueError('Clicks cannot satisfy frozen assertions.')
        if item['action'] == 'set-text' and 'input' not in item:
            raise ValueError('Native text must come from a fixed input.')
    if item['op'] == 'capture-profile-id' and not item['nameInput'].startswith('synthetic.'):
        raise ValueError('Profile discovery needs a fixed synthetic name.')
    if item['op'] == 'wait-native' and not {'expectedSha256', 'focused'} & set(item):
        raise ValueError('Wait needs an independently expected condition.')
    if item['op'] == 'wait-server-count' and (type(item['equals']) is not int or item['equals'] < 0):
        raise ValueError('Server count must be an exact nonnegative integer.')
    if item['op'] == 'assert-observer-rows' and (not item['columns'] or not item['rows']):
        raise ValueError('Independent typed metadata and nonempty expected rows required.')
    if item['op'] in ('native-text-select', 'native-text-assert'):
        if (any(type(item[key]) is not int for key in ('start', 'end'))
                or not 0 <= item['start'] <= item['end'] <= 65536
                or not isinstance(item['input'], str) or not item['input'].startswith(('corpus.', 'synthetic.'))):
            raise ValueError('Native range needs bounded independent fixed-source UTF-16 offsets.')
    if item['op'] in ('capture-imported-theme', 'capture-recovered-theme') and item['source'] != 'shared-32':
        raise ValueError('Only independently normalized fixed library-preview import is supported.')
    if item['op'] == 'assert-physical-sessions':
        if any(type(item[key]) is not int or not 0 <= item[key] <= 8 for key in ('added', 'removed')):
            raise ValueError('Physical session delta must be independently chosen and bounded.')
        if 'postgresTransaction' in item and (item['engine'] != 'postgresql' or item['postgresTransaction'] not in ('open', 'idle', 'failed')):
            raise ValueError('Only PostgreSQL exposes this independent physical transaction-state contract.')
    if item['op'] == 'settings-close-restart' and (not isinstance(item['expected'], list) or not item['expected']
            or len(item['expected']) > 3 or len(set(item['expected'])) != len(item['expected'])):
        raise ValueError('Latest Settings close needs explicit independent complete expected DTO keys.')
    if item['op'] == 'persistence-case':
        # Keep the schema/data module independent of core/native imports.
        cases = {name + '-' + failure for name in ('connections', 'workspace', 'appearance', 'themes', 'shortcuts')
                 for failure in ('corrupt', 'future')}
        permitted = {'native', 'wait-native', 'stage-input', 'file-assert-same', 'file-backup-discover',
                     'assert-settings-expected', 'capture-theme-set', 'capture-imported-theme', 'capture-recovered-theme',
                     'native-semantic-assert'}
        actions = item['actions']
        if item['case'] not in cases or not isinstance(actions, list) or not 1 <= len(actions) <= 128:
            raise ValueError('Fresh fixed persistence case and bounded procedure are required.')
        if not any(action.get('op') in ('file-assert-same', 'file-backup-discover') for action in actions):
            raise ValueError('Destructive case needs independent original preservation/backup proof.')
        for action in actions:
            if action.get('op') not in permitted or action.get('assertion', item['assertion']) != item['assertion']:
                raise ValueError('Destructive subfixture cannot connect, mutate credentials or substitute assertions.')
            if action.get('op', '').startswith('file-') and action.get('capture') != 'original':
                raise ValueError('Destructive case can inspect only its original fixed held file.')
            if action.get('op') in ('native', 'wait-native', 'native-semantic-assert'):
                selector = action.get('selector', '')
                if not selector.startswith(('settings.', 'appearance.', 'themes.', 'shortcuts.', 'persistence.', 'chooser.')):
                    raise ValueError('Destructive fixture native actions are limited to Settings/recovery surfaces.')
                if selector.startswith('chooser.') and action.get('input', 'fixture.source.shared-32') != 'fixture.source.shared-32':
                    raise ValueError('Destructive fixture chooser accepts only the fixed normalized theme source.')
            if action.get('op') == 'stage-input' and action.get('source') != 'shared-32':
                raise ValueError('Destructive fixture can stage only the fixed normalized theme source.')
            validate_action(action)
    return item


def required_plan(catalog):
    value = build(catalog, fragments())
    return {row['feature']: row for row in value['scenarios']}


def validate_scenario(feature, actions, required):
    if not isinstance(actions, list) or not 1 <= len(actions) <= 4096:
        raise ValueError('Concrete scenario must contain bounded nonzero actions.')
    row = required[feature]
    assertions = {entry['id']: entry for entry in row['assertions']}
    families = {engine for engine in ENGINES if any(name.startswith(engine) for name in row['requiredEngines'])}
    covered = set()
    for item in actions:
        validate_action(item)
        identifier = item.get('assertion')
        if identifier is None:
            continue
        if identifier not in assertions:
            raise ValueError('Assertion is not in the exact frozen scenario.')
        requirement = item.get('requirement')
        if requirement not in assertions[identifier]['requires']:
            raise ValueError('Every assertion action needs its exact coverage requirement.')
        if item['op'] == 'capability-required':
            if item['capability'] != requirement:
                raise ValueError('Pending capability must match its mandatory requirement.')
        elif requirement not in SUPPORTS.get(item['op'], set()):
            raise ValueError('Operation cannot establish declared coverage requirement.')
        if item['op'] != 'capability-required' and requirement == 'owned-effects' and (item.get('oracle') != 'effect-once' or not item.get('case')):
            raise ValueError('Exactly-once evidence needs the independent fixed effect oracle.')
        scopes = {item['engine']} if 'engine' in item else {'native'}
        covered.update((identifier, requirement, scope) for scope in scopes)
    missing = []
    for identifier, assertion in assertions.items():
        for requirement in assertion['requires']:
            # A DB scenario must explicitly cover BOTH engines for each check.
            for scope in families or {'native'}:
                if (identifier, requirement, scope) not in covered:
                    missing.append((identifier, requirement, scope))
    if missing:
        raise ValueError('Frozen assertion/requirement/engine coverage is incomplete.')
    return {'assertionCount': len(assertions), 'actionCount': len(actions), 'requiredEngineFamilies': sorted(families)}


def validate_plan(value, catalog, desktop):
    allowed = {'schemaVersion', 'selectorIntegrationReviewed', 'desktop', 'preparation', 'normalClose', 'scenarios'}
    if (not isinstance(value, dict) or set(value) != allowed or type(value['schemaVersion']) is not int
            or value['schemaVersion'] != 2 or value['desktop'] != desktop
            or value['selectorIntegrationReviewed'] is not True):
        raise ValueError('Reviewed concrete plan schema version 2 required.')
    if not isinstance(value['preparation'], list) or not value['preparation']:
        raise ValueError('Populated previous-artifact preparation cannot be empty.')
    for item in value['preparation']:
        validate_action(item)
    close = value['normalClose']
    if (not isinstance(close, list) or not close or len(close) > 32
            or close[-1].get('op') != 'native' or close[-1].get('action') != 'invoke'
            or close[-1].get('expectExit') is not True):
        raise ValueError('Exact reviewed common Close sequence required.')
    for index, item in enumerate(close):
        item = dict(item)
        expect_exit = item.pop('expectExit', False)
        validate_action(item)
        if 'assertion' in item or (expect_exit and index != len(close) - 1) or item['op'] != 'native':
            raise ValueError('Close sequence permits only exact owned native actions.')
    required = required_plan(catalog)
    if not isinstance(value['scenarios'], dict) or set(value['scenarios']) != set(required):
        raise ValueError('All 57 frozen scenarios require explicit coverage, including pending gates.')
    for feature, actions in value['scenarios'].items():
        validate_scenario(feature, actions, required)
    return value
