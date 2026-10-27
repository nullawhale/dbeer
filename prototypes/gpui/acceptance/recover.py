#!/usr/bin/env python3
"""Recover only journal-proven reserved credentials. Never reattach to a PID."""
import argparse
import re
import sys
sys.dont_write_bytecode = True
import uuid
from core import OUTPUT, Refused, canonical, native, now, parse, read, safe, write_new
from credentials import BoundedStore, SERVICE
from core import digest_bytes


def recovery_claims(records, nonce):
    """Pure journal ownership chain; absence alone grants no delete authority."""
    created, closed, absent, confirmed, eligible, pending = set(), set(), set(), {}, {}, {}
    for value in records:
        if value.get('runNonce') != nonce:
            raise Refused('Foreign journal nonce refused.')
        event = value.get('event')
        if event == 'exact-child-created':
            created.add(canonical(value['owner']))
        elif event == 'normal-close-completed':
            owner = canonical(value.get('owner'))
            if owner not in created or value.get('exitCode') != 0 or value.get('forcedTermination') is not False:
                raise Refused('Successful exact child Close authority differs.')
            closed.add(owner)
        if value.get('service') != SERVICE:
            continue
        account = value.get('account')
        if not isinstance(account, str) or not re.fullmatch(r'(?:dbeer-acceptance-[0-9a-f]{32}-[a-z0-9-]{1,32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', account):
            raise Refused('Reserved recovery account is invalid.')
        if event == 'credential-absence-proven':
            if value.get('ownerNonce') != nonce or account in absent:
                raise Refused('Original absence reservation differs.')
            absent.add(account)
            confirmed[account], eligible[account] = None, set()
        elif event in ('credential-create-intent', 'credential-update-intent'):
            target, prior = value.get('expectedSha256'), value.get('priorSha256')
            if (account not in absent or account in pending or prior != confirmed.get(account)
                    or target is not None and not re.fullmatch('[0-9a-f]{64}', str(target))
                    or event == 'credential-create-intent' and (prior is not None or not target)):
                raise Refused('Credential intent chain differs from original owned state.')
            pending[account] = (prior, target)
            eligible[account] = {item for item in (prior, target) if item is not None}
        elif event == 'credential-owned':
            target = value.get('valueSha256')
            if pending.get(account) != (None, target):
                raise Refused('Credential create terminal differs.')
            confirmed[account], eligible[account] = target, {target}
            del pending[account]
        elif event == 'credential-ui-terminal':
            prior, attempted = pending.get(account, ('invalid', 'invalid'))
            if prior != value.get('priorSha256') or attempted != value.get('attemptedSha256'):
                raise Refused('Credential UI terminal has no original intent.')
            outcome = value.get('outcome')
            if outcome not in ('written', 'deleted', 'kept', 'rolled-back'):
                raise Refused('Credential UI terminal outcome differs.')
            target = attempted if outcome in ('written', 'deleted') else prior
            if target != value.get('expectedSha256'):
                raise Refused('Credential UI terminal hash differs.')
            confirmed[account], eligible[account] = target, set() if target is None else {target}
            del pending[account]
        elif event == 'credential-cleaned':
            eligible[account] = set()
    if not created or created != closed:
        raise Refused('All retained GUI children require successful common Close before credential recovery.')
    return {account: hashes for account, hashes in eligible.items() if hashes}


def recover(root):
    root = safe(root, directory=True)
    if root.parent != OUTPUT.resolve() or not re.fullmatch('[0-9a-f]{32}', root.name):
        raise Refused('Recovery requires the original private owned run directory.')
    native.private_path(root, directory=True)
    request = parse(read(root / 'request.json', 16384))
    if request.get('runNonce') != root.name:
        raise Refused('Original run nonce differs.')
    records = [parse(read(path, 65536)) for path in sorted(root.glob('journal-*.json'))]
    for value in records:
        if value.get('runNonce') != root.name:
            raise Refused('Foreign recovery journal preserved.')
    expected = recovery_claims(records, root.name)
    import os
    # A credential service is touched only after retained exact GUI lifetimes
    # have successful actual common Close records. Manual PID claims cannot do so.
    env = {key: value for key, value in os.environ.items() if not key.startswith(('DBEER_', 'PG', 'MYSQL', 'LD_', 'DYLD_', 'PYTHON'))}
    store = BoundedStore(env)
    outcomes = []
    for account, allowed_hashes in expected.items():
        try:
            value = store.read(account)
            if value is None:
                outcomes.append({'service': SERVICE, 'account': account, 'absent': True})
                continue
            expected_hash = digest_bytes(value)
            if expected_hash not in allowed_hashes:
                raise Refused('Foreign credential replacement preserved.')
            store.delete_expected(account, expected_hash)
            if store.read(account) is not None:
                raise Refused('Recovery absence unproven.')
            outcomes.append({'service': SERVICE, 'account': account, 'absent': True})
        except Exception:
            outcomes.append({'service': SERVICE, 'account': account, 'refusedForeignOrUnavailable': True})
    proof = {'schemaVersion': 1, 'runNonce': root.name, 'at': now(), 'credentials': outcomes,
             'processesReattachedOrKilled': False, 'filesRemoved': False,
             'manualPrivateFixtureReviewRequired': True}
    write_new(root / ('recovery-' + uuid.uuid4().hex + '.json'), proof)
    return 2 if any(item.get('refusedForeignOrUnavailable') for item in outcomes) else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    args = parser.parse_args()
    try:
        sys.exit(recover(args.root))
    except Exception:
        print('Owned recovery refused; original state retained.', file=sys.stderr)
        sys.exit(2)
