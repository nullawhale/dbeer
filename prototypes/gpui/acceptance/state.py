"""Independent persisted typed-state checks in the private fixture only."""
from core import Refused, Pending, canonical, digest_bytes, parse, read, safe

PROFILE_KEYS = {'id', 'name', 'engine', 'host', 'port', 'database', 'user', 'sslMode', 'sslRootCert', 'readonly', 'environment'}
WORKSPACE_KEYS = {'version', 'documents', 'selectedDocumentID', 'history', 'historyEnabled'}


def typed_state(root, require_populated=False):
    safe(root, directory=True)
    profiles_path, workspace_path = root / 'connections.json', root / 'workspace.json'
    if not profiles_path.exists() or not workspace_path.exists():
        raise Pending('Application-written profile/workspace state is required.')
    profiles = parse(read(profiles_path, 4 * 1024 * 1024))
    workspace = parse(read(workspace_path, 64 * 1024 * 1024))
    if (set(profiles) != {'version', 'connections', 'selectedProfileId'} or profiles['version'] != 2
            or not isinstance(profiles['connections'], list) or set(workspace) - WORKSPACE_KEYS
            or workspace.get('version') != 1 or not isinstance(workspace.get('documents'), list)
            or not isinstance(workspace.get('history'), list)):
        raise Refused('Persisted fixture state schema mismatch.')
    profile_ids, profile_records = [], []
    for item in profiles['connections']:
        if (not isinstance(item, dict) or set(item) - PROFILE_KEYS or not (PROFILE_KEYS - {'sslRootCert'}).issubset(item)
                or item['id'] in profile_ids or not isinstance(item['readonly'], bool)
                or item['environment'] not in ('unspecified', 'development', 'staging', 'production')
                or item['engine'] not in ('postgresql', 'mysql')
                or type(item['port']) is not int or not 1 <= item['port'] <= 65535
                or any(not isinstance(item[key], str) or not item[key] for key in ('id', 'name', 'host', 'database', 'user', 'sslMode'))):
            raise Refused('Profile metadata contains invalid fields or identities.')
        profile_ids.append(item['id'])
        profile_records.append({'id': item['id'], 'metadataSha256': digest_bytes(canonical(item)),
                                'policyTlsSha256': digest_bytes(canonical({k: item.get(k) for k in ('readonly', 'environment', 'sslMode', 'sslRootCert')}))})
    documents, document_ids = [], []
    for item in workspace['documents']:
        if (not isinstance(item, dict) or set(item) - {'id', 'title', 'text', 'profileID'}
                or not {'id', 'title', 'text'}.issubset(item) or item['id'] in document_ids
                or any(not isinstance(item[key], str) for key in ('id', 'title', 'text'))
                or not item['id'] or item.get('profileID') is not None and not isinstance(item['profileID'], str)):
            raise Refused('Source-only document contains invalid/live state.')
        document_ids.append(item['id'])
        documents.append({'id': item['id'], 'profileID': item.get('profileID'), 'sourceSha256': digest_bytes(item['text'].encode()),
                          'titleSha256': digest_bytes(item['title'].encode())})
    histories = []
    for item in workspace['history']:
        if (not isinstance(item, dict) or set(item) - {'id', 'date', 'documentID', 'profileID', 'sql', 'outcome'}
                or not {'id', 'date', 'sql', 'outcome'}.issubset(item)
                or any(not isinstance(item[key], str) for key in ('id', 'date', 'sql', 'outcome'))):
            raise Refused('History contains invalid/live state.')
        histories.append({'id': item['id'], 'typedSha256': digest_bytes(canonical(item))})
    if profiles['selectedProfileId'] is not None and profiles['selectedProfileId'] not in profile_ids:
        raise Refused('Selected profile is outside the original library.')
    if workspace.get('selectedDocumentID') is not None and workspace['selectedDocumentID'] not in document_ids:
        raise Refused('Selected document is outside the original workspace.')
    if type(workspace.get('historyEnabled')) is not bool:
        raise Refused('History preference must be explicitly persisted.')
    if len({h['id'] for h in histories}) != len(histories):
        raise Refused('History identity duplicated.')
    settings = {}
    for name in ('appearance.json', 'themes.json', 'shortcuts.json'):
        if (root / name).exists():
            value = parse(read(root / name, 16 * 1024 * 1024))
            settings[name] = digest_bytes(canonical(value))
    if require_populated and (len(profile_ids) < 2 or len(documents) < 3 or not histories or len(settings) != 3):
        raise Pending('Upgrade needs UI-created profiles, documents, history and all settings, themes and shortcuts.')
    return {'profileIds': profile_ids, 'selectedProfileId': profiles['selectedProfileId'], 'profiles': profile_records,
            'documents': documents, 'selectedDocumentID': workspace.get('selectedDocumentID'),
            'history': histories, 'historyEnabled': workspace.get('historyEnabled', True), 'settingsSha256': settings}


def assert_same(before, after):
    if before != after:
        raise Refused('Independent typed persistence comparison differs across ordinary update/restart.')
    return {'typedStateSha256': digest_bytes(canonical(after)), 'profileCount': len(after['profiles']),
            'documentCount': len(after['documents']), 'historyCount': len(after['history']),
            'settingsCount': len(after['settingsSha256']), 'exactIdsPolicyTlsSourcesHistorySettingsPreserved': True}


def check_transfer(path):
    """Strict metadata-only transfer allow-list; never inspect credential storage."""
    value = parse(read(path, 2 * 1024 * 1024))
    if (not isinstance(value, dict) or set(value) != {'version', 'profiles'}
            or type(value['version']) is not int or value['version'] not in (1, 2)
            or not isinstance(value['profiles'], list) or not 1 <= len(value['profiles']) <= 1000):
        raise Refused('Unsupported portable profile export.')
    fields = {'name', 'engine', 'host', 'port', 'database', 'user', 'sslMode', 'sslRootCert', 'policy'}
    for item in value['profiles']:
        required = fields - {'sslRootCert', 'policy'}
        if value['version'] == 2:
            required.add('policy')
        if not isinstance(item, dict) or set(item) - fields or not required.issubset(item):
            raise Refused('Transfer includes unknown fields or missing metadata.')
        for field in ('name', 'host', 'database', 'user'):
            text = item[field]
            if not isinstance(text, str) or not text.strip() or '\0' in text or len(text.encode()) > 1024:
                raise Refused('Transfer text metadata is invalid.')
        if type(item['port']) is not int or not 1 <= item['port'] <= 65535:
            raise Refused('Transfer port is invalid.')
        if item['engine'] not in ('postgresql', 'mysql'):
            raise Refused('Transfer engine is invalid.')
        modes = ('disable', 'allow', 'prefer', 'require', 'verify-ca', 'verify-full') if item['engine'] == 'postgresql' else ('disable', 'require', 'verify-ca', 'verify-full')
        if item['sslMode'] not in modes:
            raise Refused('Transfer TLS mode differs from contract.')
        policy = item.get('policy')
        if policy is not None:
            if (not isinstance(policy, dict) or set(policy) != {'environment', 'readOnly'}
                    or policy['environment'] not in ('unspecified', 'development', 'staging', 'production')
                    or type(policy['readOnly']) is not bool):
                raise Refused('Transfer policy is invalid.')
        elif value['version'] == 2:
            raise Refused('Current transfer requires explicit policy.')
        hint = item.get('sslRootCert')
        if hint is not None and (not isinstance(hint, str) or len(hint.encode()) > 4096 or '\0' in hint or 'PRIVATE KEY' in hint):
            raise Refused('Transfer CA hint is invalid.')
    return {'sha256': digest_bytes(canonical(value)), 'profileCount': len(value['profiles']), 'secretFieldsAbsent': True}


def policy_expectation(value, databases):
    """Full independent policy/TLS contract, with only exact-owned CA binding."""
    if (not isinstance(value, dict) or set(value) != {'readonly', 'environment', 'sslMode', 'sslRootCert'}
            or type(value['readonly']) is not bool
            or value['environment'] not in ('unspecified', 'development', 'staging', 'production')
            or value['sslMode'] not in ('disable', 'allow', 'prefer', 'require', 'verify-ca', 'verify-full')):
        raise Refused('Full independently chosen policy/TLS contract is required.')
    result = dict(value)
    ca = value['sslRootCert']
    if ca is not None:
        allowed = {'connection.postgresql.caFile': 'postgresql', 'connection.mysql.caFile': 'mysql'}
        if ca not in allowed:
            raise Refused('Policy CA expectation must bind the exact owned public fixture.')
        result['sslRootCert'] = databases.public_ca_path(allowed[ca], 'caFile')
    return result


def assert_expected(root, expected, resolve_profile, corpus):
    """Exact known persisted subsets/deltas, never an application-output baseline.

    Text expectations are fixed corpus keys. All profile UUID expectations bind
    only original current-epoch UI-created captures. No secret/live state read.
    """
    fields = {'profileOrder', 'selectedProfile', 'profileCount', 'documentCount', 'historyCount',
              'documentSources', 'documentProfiles', 'historyEnabled'}
    if not isinstance(expected, dict) or not expected or set(expected) - fields:
        raise Refused('Exact persisted expectation is empty or unsupported.')
    actual = typed_state(root, require_populated=True)
    checks = {}
    for field, value in expected.items():
        if field in ('profileCount', 'documentCount', 'historyCount'):
            minimum = {'profileCount': 2, 'documentCount': 3, 'historyCount': 1}[field]
            if type(value) is not int or value < minimum:
                raise Refused('Populated independent count expectation required.')
            key = {'profileCount': 'profileIds', 'documentCount': 'documents', 'historyCount': 'history'}[field]
            observed = len(actual[key])
        elif field == 'profileOrder':
            if not isinstance(value, list) or not value:
                raise Refused('Original profile ordering must be nonempty.')
            value = [resolve_profile(ref) for ref in value]
            observed = actual['profileIds']
        elif field == 'selectedProfile':
            value, observed = resolve_profile(value), actual['selectedProfileId']
        elif field == 'documentSources':
            if not isinstance(value, list) or not value or any(key not in corpus for key in value):
                raise Refused('Document sources need fixed independent input keys.')
            value = [digest_bytes(corpus[key].encode()) for key in value]
            observed = [doc['sourceSha256'] for doc in actual['documents']]
        elif field == 'documentProfiles':
            if not isinstance(value, list) or not value:
                raise Refused('Original document/profile binding order required.')
            value = [None if ref is None else resolve_profile(ref) for ref in value]
            observed = [doc['profileID'] for doc in actual['documents']]
        else:
            if type(value) is not bool:
                raise Refused('History state must be explicit.')
            observed = actual['historyEnabled']
        if canonical(observed) != canonical(value):
            raise Refused('Independent persisted expected subset differs.')
        checks[field] = digest_bytes(canonical(value))
    return {'expectedSubsetSha256': digest_bytes(canonical(checks)), 'expectedFieldCount': len(checks),
            'typedStateSha256': digest_bytes(canonical(actual)), 'populated': True}


def assert_settings(root, key):
    from inputs import source_catalog
    _, corpus = source_catalog()
    files = {'independentChoices': 'appearance.json', 'systemFollowing': 'appearance.json',
             'explicitUnbind': 'shortcuts.json'}
    if key not in files:
        raise Pending('Exact imported-library/render/latest-save Settings oracle is still required.')
    expected = corpus['settingsExpected'][key]
    actual = parse(read(root / files[key], 16 * 1024 * 1024))
    if canonical(actual) != canonical(expected):
        raise Refused('Settings differ from the independent fixed DTO expectation.')
    return {'settingsKey': key, 'settingsSha256': digest_bytes(canonical(expected)), 'independentExpectedDTO': True}
