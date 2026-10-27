"""Frozen-row mapping and non-overclaiming installed evidence ledger."""
from core import REPO, TARGETS, Refused, Pending, canonical, digest_bytes, parse, read

REGISTRY = REPO / 'prototypes/gpui/parity/registry.json'
CATALOG = REPO / 'prototypes/gpui/fixtures/installed-acceptance/scenarios.json'


def catalog():
    registry_bytes = read(REGISTRY, 2 * 1024 * 1024)
    frozen = parse(registry_bytes)
    value = parse(read(CATALOG, 2 * 1024 * 1024))
    if value.get('registrySha256') != digest_bytes(registry_bytes):
        raise Refused('Frozen registry mapping changed.')
    expected = {row['id'] for row in frozen['features']}
    if (expected != {'F%02d' % i for i in range(1, 58)} or len(value['scenarios']) != 57
            or {row['feature'] for row in value['scenarios']} != expected
            or any(row['id'] != 'INSTALLED-' + row['feature'] for row in value['scenarios'])):
        raise Refused('Installed catalog must map all 57 exact frozen features.')
    return value


def new_ledger(nonce, started_at):
    value = catalog()
    return {'schemaVersion': 1, 'kind': 'installed-acceptance-evidence', 'runNonce': nonce,
            'startedAt': started_at, 'registrySha256': value['registrySha256'],
            'frozenRegistryModified': False, 'headlessCanAccept': False,
            'targets': list(TARGETS), 'cells': [
                {'feature': row['feature'], 'scenarioId': row['id'], 'target': target,
                 'status': 'not-run', 'reason': 'native-stand-artifacts-and-completed-procedure-required', 'evidence': []}
                for row in value['scenarios'] for target in TARGETS]}


def record(ledger, feature, target, status, proofs=(), reason=None):
    if status not in ('not-run', 'pending', 'failed', 'passed-scenario'):
        raise Refused('Unsupported installed evidence status.')
    rows = [r for r in ledger['cells'] if r['feature'] == feature and r['target'] == target]
    if len(rows) != 1:
        raise Refused('Unknown frozen native cell.')
    requirements = next(r['proofKinds'] for r in catalog()['scenarios'] if r['feature'] == feature)
    if status == 'passed-scenario':
        if not set(requirements).issubset({p['kind'] for p in proofs}):
            raise Refused('A UI success label cannot replace independent required evidence.')
        scenario = next(r for r in catalog()['scenarios'] if r['feature'] == feature)
        if 'independent-physical-database-observer' in requirements:
            observed = {p.get('engine') for p in proofs if p['kind'] == 'independent-physical-database-observer'}
            if observed != {'postgresql', 'mysql'}:
                raise Refused('Both actual database families require independent observer proof.')
        # A single pair cannot close the F57 engine-version/TLS/fault matrix.
        # That row remains pending until Task30 completed native proof joins it.
        if feature == 'F57':
            raise Pending('Complete target-native version/TLS/fault evidence must be joined before F57 acceptance.')
    rows[0].update(status=status, reason=reason, evidence=list(proofs))
