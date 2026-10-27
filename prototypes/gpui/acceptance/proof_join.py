"""Consume existing completed Task30 summaries, never headless-derived UI proof.

Physical lost-ACK/native manual producers are still absent. Their missing join
is an explicit Pending boundary even after valid version/TLS summaries exist.
"""
from core import REPO, Pending, Refused, canonical, digest_bytes, load_module, parse, read, safe

SOURCE = load_module('dbeer_acceptance_verification_source', REPO / 'prototypes/gpui/verification/source_contract.py')
MAC = load_module('dbeer_acceptance_macos_coverage', REPO / 'prototypes/gpui/verification/macos_coverage.py')

DATABASE_MATRIX = REPO / 'prototypes/gpui/verification/matrix.json'


def completed_run(proof):
    if (not isinstance(proof, dict) or proof.get('completed') is not True
            or type(proof.get('exitCode')) is not int or proof['exitCode'] != 0 or proof.get('timedOut') is not False
            or not isinstance(proof.get('summaries'), list) or not proof['summaries']):
        raise Refused('Nonempty completed exact test summary required.')
    if any(not isinstance(row, dict) or row.get('result') not in ('ok', None) or row.get('failed', 0) != 0
           or any(key in row and type(row[key]) is not int for key in ('passed', 'failed', 'ignored', 'filtered'))
           for row in proof['summaries']):
        raise Refused('Failed/incomplete test summary cannot join acceptance.')
    go_packages = [row['package'] for row in proof['summaries'] if isinstance(row.get('package'), str)]
    if (not any(type(row.get('passed')) is int and row['passed'] > 0 for row in proof['summaries'])
            and not go_packages):
        raise Refused('Zero executed tests cannot join acceptance.')
    if not proof.get('finishedAt') or proof.get('truncatedLines') != 0:
        raise Refused('Truncated or missing terminal test evidence cannot join acceptance.')
    tests = proof.get('tests')
    if (not isinstance(tests, list) or not tests or any(set(row) != {'id', 'outcome'} for row in tests)
            or len({row['id'] for row in tests}) != len(tests)
            or any(row['outcome'] not in ('ok', 'ignored') for row in tests)):
        raise Refused('Unique nonempty actual test rows are required.')
    if go_packages and (len(set(go_packages)) != len(go_packages) or proof.get('missingPackages')
                        or any(row.get('result') != 'ok' for row in proof['summaries'] if 'package' in row)
                        or not any(row['outcome'] == 'ok' for row in tests)
                        or any(row['id'].rsplit('/', 1)[0] not in go_packages for row in tests)):
        raise Refused('Go test rows require their exact unique completed packages.')
    rust = [row for row in proof['summaries'] if 'filtered' in row]
    if rust:
        if (len(rust) != 1 or len(proof['summaries']) != 1
                or rust[0]['passed'] != sum(row['outcome'] == 'ok' for row in tests)
                or rust[0]['ignored'] != sum(row['outcome'] == 'ignored' for row in tests)):
            raise Refused('Rust completed summary counts differ from its exact actual test rows.')


def source_stable(value, expected_source):
    try:
        SOURCE.validate(expected_source)
    except (ValueError, TypeError, KeyError):
        raise Refused('An exact candidate-bound reviewed verification source inventory is required.') from None
    if (type(value.get('schemaVersion')) is not int or value['schemaVersion'] != 1
            or value.get('status') != 'passed' or value.get('proofInvalidated')
            or not value.get('finishedAt') or value.get('sourceSha256') != value.get('sourceSha256After')
            or value.get('sourceSha256') != expected_source['sourceSha256']
            or value.get('sourceInventory') != expected_source or value.get('sourceInventoryAfter') != expected_source
            or not isinstance(value.get('stages'), list) or not value['stages']
            or len({stage.get('id') for stage in value['stages']}) != len(value['stages'])):
        raise Refused('Exact source-stable completed summary with unique stages required.')


def native_host(value, desktop):
    host = value.get('host', {})
    expected_os = 'Windows' if desktop == 'windows11-x64' else 'Linux'
    if (host.get('os') != expected_os or host.get('machine', '').lower() not in ('amd64', 'x86_64')
            or host.get('container') is not False or host.get('pythonBits') != 64):
        raise Refused('Actual native OS/x64 summary outside containers is required.')
    if expected_os == 'Linux' and (host.get('distribution'), host.get('distributionVersion')) != ('ubuntu', '24.04'):
        raise Refused('Native Ubuntu 24.04 proof is required.')
    return expected_os


def task30_rust_summary(value, desktop, expected_source):
    source_stable(value, expected_source)
    expected_os = native_host(value, desktop)
    if value.get('buildMode') != 'unmarked-development-tests':
        raise Refused('Native test evidence must preserve its separate development build mode.')
    faults = parse(read(REPO / 'prototypes/gpui/fixtures/parity-matrix/fault-plan.json', 1024 * 1024))['portablePeer']['requiredTests']
    if len(faults) != 13 or len(set(faults)) != 13:
        raise Refused('Exact reviewed thirteen-test portable fault contract required.')
    stages = {stage['id']: stage for stage in value['stages']}
    for identifier in ('default', 'native-smoke'):
        stage = stages.get(identifier, {})
        if (stage.get('status') != 'passed' or stage.get('buildMode') != 'unmarked-development-tests'
                or stage.get('portableFaultAssertionsExpected') != 13 or stage.get('portableFaultAssertionsObserved') != 13
                or stage.get('requiredAssertionsExpected', 0) < 13
                or stage.get('requiredAssertionsObserved') != stage.get('requiredAssertionsExpected')
                or stage.get('missingRequiredAssertions') or not stage.get('runs')):
            raise Refused('Both native Rust modes need all exact completed critical fault assertions.')
        observed = []
        for run in stage['runs']:
            completed_run(run)
            observed.extend(row['id'] for row in run['tests'] if row['outcome'] == 'ok')
        if any(observed.count(name) != 1 for name in faults):
            raise Refused('Missing/duplicate portable fault test cannot join native Rust evidence.')
    return {'nativeOs': expected_os, 'summarySha256': digest_bytes(canonical(value)),
            'completedModes': ['default', 'native-smoke'], 'portableFaultAssertionsPerMode': 13,
            'installedNativeCoverageEstablished': False}


def task30_summary(value, desktop, expected_source):
    source_stable(value, expected_source)
    expected_os = native_host(value, desktop)
    fixtures = value.get('databaseFixtures', {})
    if (fixtures.get('postgres') not in ('16', '17', '18') or fixtures.get('mysql') not in ('8.0', '8.4')
            or fixtures.get('cleanupCompleted') is not True):
        raise Refused('Exact versioned database fixture cleanup is incomplete.')
    matrix = parse(read(DATABASE_MATRIX, 2 * 1024 * 1024))
    contracts = {stage['id']: stage for stage in matrix['databaseStages']}
    shared = [stage for stage in matrix['sharedStages'] if stage['id'] == 'shared-go-owned-db-race']
    if (len(contracts) != 7 or len(shared) != 1 or len(shared[0]['requiredTests']) != 10
            or not {'postgres_real_helper_death_awaits_original_exit_and_physical_session_loss',
                    'mysql_real_helper_death_awaits_original_exit_and_physical_session_loss'}
            <= set(contracts.get('db-live', {}).get('requiredSuffixes', []))):
        raise Refused('Reviewed seven-stage database and ten-assertion shared Go contract required.')
    contracts[shared[0]['id']] = shared[0]
    stages = {stage['id']: stage for stage in value['stages'] if stage.get('id') in contracts}
    if set(stages) != set(contracts):
        raise Refused('Every database/TLS stage is mandatory for the versioned pair.')
    for identifier, stage in stages.items():
        contract = contracts[identifier]
        exact = contract.get('requiredTests', [])
        suffixes = contract.get('requiredSuffixes', [])
        required = len(exact) + len(suffixes)
        runs = [stage.get('proof')] if identifier == shared[0]['id'] else stage.get('runs')
        if (stage.get('status') != 'passed' or not runs or any(not isinstance(run, dict) for run in runs)
                or type(stage.get('requiredAssertionsExpected')) is not int
                or stage['requiredAssertionsExpected'] != required
                or type(stage.get('requiredAssertionsObserved')) is not int
                or stage['requiredAssertionsObserved'] != required or stage.get('missingRequiredAssertions')):
            raise Refused('Database/TLS stage has no completed cases.')
        names = []
        for run in runs:
            completed_run(run)
            names.extend(row['id'] for row in run['tests'] if row['outcome'] == 'ok')
        if (any(names.count(name) != 1 for name in exact)
                or any(sum(name == suffix or name.endswith('::' + suffix) for name in names) != 1 for suffix in suffixes)):
            raise Refused('Every exact database/Go assertion must complete once; a passed stage flag is insufficient.')
        if identifier == shared[0]['id']:
            proof = runs[0]
            if (proof.get('command') != ['bash', './scripts/test-go.sh', '--require-postgres']
                    or not all(any(row.get('package') == name.rsplit('/', 1)[0] for row in proof['summaries']) for name in exact)
                    or any(name in proof.get('ignored', []) for name in exact)
                    or proof.get('requiredAssertionsExpected') != 10 or proof.get('requiredAssertionsObserved') != 10
                    or proof.get('missingRequiredAssertions')):
                raise Refused('Supported shared Go runner and ten exact non-skipped assertions are mandatory.')
    return {'postgresql': fixtures['postgres'], 'mysql': fixtures['mysql'],
            'summarySha256': digest_bytes(canonical(value)), 'nativeOs': expected_os,
            'completedDatabaseStages': sorted(stages)}


def macos_summary(value, expected_source):
    source_stable(value, expected_source)
    if value.get('host', {}).get('os') != 'Darwin' or value.get('host', {}).get('container') is not False:
        raise Refused('Actual completed macOS SwiftUI/AppKit summary required.')
    stages = [stage for stage in value['stages'] if stage['id'] == 'swiftui-regressions']
    if len(stages) != 1 or stages[0].get('status') != 'passed':
        raise Refused('Required completed SwiftUI/AppKit regression stage absent.')
    proof = stages[0].get('proof')
    completed_run(proof)
    try:
        coverage = MAC.coverage(proof)
    except (ValueError, TypeError):
        raise Refused('Exact supported Mac skip coverage is required.') from None
    if (proof.get('command') != ['./scripts/test.sh', '--all'] or proof.get('missingPackages')
            or coverage['unapprovedSkips'] or proof.get('coverage') != coverage
            or stages[0].get('conditionalSkips') != coverage['uncoveredDatabaseRoots'] or not any(row.get('framework') == 'Swift Testing' and row.get('passed', 0) > 0 for row in proof['summaries'])):
        raise Refused('Supported complete Mac runner/Swift Testing/shared Go summary is required.')
    return {'swiftUIAppKitCompleted': True, 'summarySha256': digest_bytes(canonical(value)),
            'coverage': coverage}


class MatrixJoin:
    def __init__(self, descriptors, desktop, expected_source):
        if not isinstance(descriptors, list) or not descriptors or len(descriptors) > 64:
            raise Pending('Pinned nonempty completed version/TLS/fault/native/Mac summaries are required.')
        try:
            SOURCE.validate(expected_source)
            if SOURCE.capture(REPO) != expected_source:
                raise ValueError('Current reviewed source differs.')
        except (ValueError, TypeError, KeyError):
            raise Refused('Candidate-bound current verification source contract differs.') from None
        self.descriptors, self.desktop, self.expected_source = descriptors, desktop, expected_source

    def require_complete(self):
        pairs, hashes, rust, mac = [], set(), [], []
        for descriptor in self.descriptors:
            if (not isinstance(descriptor, dict) or set(descriptor) != {'kind', 'path', 'sha256'}
                    or descriptor['kind'] not in ('task30-databases', 'task30-native-rust', 'macos-regressions', 'installed-native', 'physical-native-faults')):
                raise Refused('Completed proof descriptor is unsupported.')
            data = read(safe(descriptor['path']), 16 * 1024 * 1024)
            digest = digest_bytes(data)
            if digest != descriptor['sha256'] or digest in hashes:
                raise Refused('Completed proof pin differs or duplicates another proof.')
            hashes.add(digest)
            value = parse(data)
            if descriptor['kind'] == 'task30-databases':
                pairs.append(task30_summary(value, self.desktop, self.expected_source))
            elif descriptor['kind'] == 'task30-native-rust':
                rust.append(task30_rust_summary(value, self.desktop, self.expected_source))
            elif descriptor['kind'] == 'macos-regressions':
                mac.append(macos_summary(value, self.expected_source))
            else:
                # No existing trusted producer exposes complete installed-native
                # manual or physical lost-COMMIT-ACK receipts. Do not invent one
                # or accept a caller-written passed flag as server evidence.
                raise Pending('Reviewed physical/native/manual completed-proof adapter is required.')
        if ({pair['postgresql'] for pair in pairs} != {'16', '17', '18'}
                or {pair['mysql'] for pair in pairs} != {'8.0', '8.4'}):
            raise Pending('All required PostgreSQL/MySQL version and TLS completed summaries are required.')
        if not rust or len(mac) != 1:
            raise Pending('Both native Rust modes/faults and one actual supported Mac completed summary are required.')
        raise Pending('All 171 native cells, physical lost-ACK and Mac/native manual joins remain mandatory.')
