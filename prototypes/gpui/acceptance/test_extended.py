"""Prepared real mechanism/safety assertions. Do not run before global freeze."""
from __future__ import annotations
import copy
import importlib.util
import io
import json
import sys
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from core import REPO, Refused, Pending, Artifact, canonical, digest_bytes, parse, read
from db_relay import OwnedRelay, BOUND, require_sequential_apply_source
from files import HeldFile, ReplacementBarrier
from persistence_cases import CASES, DEFAULTS, case_bytes
from plan import validate_action
from settings_contract import discover_imported, expect, imported_theme
from text_contract import assert_semantics, assert_text, codepoint_offset, expected_text
from test_integration import Journal, workflow
from proof_join import task30_summary, task30_rust_summary, macos_summary, MatrixJoin, SOURCE, MAC
from recipes.oracle import effect_baseline, effect_snapshot, assert_effect_snapshot, assert_apply_committed, snapshot

THEME = 'imported-00000000-0000-4000-8000-000000000001'
# Parser-only source inventory; never emitted as execution evidence.
PARSER_FILES = {'synthetic/parser-fixture.rs': {'sha256': digest_bytes(b'owned parser fixture'), 'size': 20}}
PARSER_SOURCE = SOURCE.validate({'contract': SOURCE.CONTRACT, 'digestAlgorithm': SOURCE.ALGORITHM,
                                 'sourceSha256': SOURCE.digest(PARSER_FILES), 'files': PARSER_FILES})


def recv_exact(stream, size):
    result = bytearray()
    while len(result) < size:
        block = stream.recv(size - len(result))
        if not block:
            raise AssertionError('Owned synthetic peer closed an incomplete reply.')
        result.extend(block)
    return bytes(result)


class NativeRangeContractTests(unittest.TestCase):
    def test_utf16_nonbmp_combining_crlf_exact_ranges(self):
        text = 'a\U0001f600e\u0301\r\nZ'
        expected = expected_text(text, 1, 5)
        self.assertEqual(expected['selections'][0]['textSha256'], digest_bytes('\U0001f600e\u0301'.encode()))
        self.assertEqual(codepoint_offset(text, 3), 2)
        self.assertTrue(assert_text(expected, expected)['nativeUTF16RangeVerified'])
        for start, end in ((2, 3), (1, 2), (9, 9), (4, 3)):
            with self.subTest(start=start, end=end), self.assertRaises(Refused):
                expected_text(text, start, end)

    def test_actual_output_cannot_supply_missing_or_changed_expected_source(self):
        expected = expected_text('SELECT 1\r\n', 0, 6)
        for key, value in [('utf16Length', 9), ('textSha256', 'a' * 64), ('selections', [])]:
            changed = copy.deepcopy(expected)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(Refused):
                assert_text(changed, expected)

    def test_typed_semantics_reject_text_null_alias_boolean_ordinals_and_absence(self):
        expected = {'descriptionSha256': digest_bytes(b'SQL NULL'), 'column': 0, 'readOnly': True}
        assert_semantics(expected, expected)
        for changed in ({**expected, 'descriptionSha256': digest_bytes(b'Text NULL')},
                        {**expected, 'column': False}, {'column': 0}):
            with self.assertRaises(Refused):
                assert_semantics(changed, expected)


class SettingsAuthorityTests(unittest.TestCase):
    def test_import_discovery_checks_all_normalized_colors_scopes_and_old_library(self):
        before = {'version': 1, 'themes': []}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            value = {'version': 1, 'themes': [imported_theme(THEME)]}
            (root / 'themes.json').write_bytes(canonical(value))
            self.assertEqual(discover_imported(before, root), THEME)
            for mutate in ('alpha', 'scope', 'clear-style', 'second'):
                changed = copy.deepcopy(value)
                if mutate == 'alpha':
                    changed['themes'][0]['colors']['editor.selectionBackground']['alpha'] = 1.0
                elif mutate == 'scope':
                    changed['themes'][0]['tokenRules'][0]['scopes'] = ['source.sql']
                elif mutate == 'clear-style':
                    changed['themes'][0]['tokenRules'][1]['style']['fontStyle'] = None
                else:
                    changed['themes'].append(imported_theme('imported-00000000-0000-4000-8000-000000000002'))
                (root / 'themes.json').write_bytes(canonical(changed))
                with self.subTest(mutate=mutate), self.assertRaises(Refused):
                    discover_imported(before, root)

    def test_latest_full_preference_preserves_newer_unrelated_choice_after_remove(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = {**DEFAULTS['appearance'], 'appearanceTheme': 'light', 'editorColorTheme': 'solarized-light'}
            (root / 'appearance.json').write_bytes(canonical(current))
            expect(root, 'unrelatedChoiceAfterRemoved')
            with self.assertRaises(Refused):
                expect(root, 'afterRemoved')
            (root / 'themes.json').write_bytes(canonical({'version': 1, 'themes': [imported_theme(THEME)]}))
            expect(root, 'libraryImported', THEME)
            with self.assertRaises(Refused):
                expect(root, 'libraryEmpty')


class FreshPersistenceTests(unittest.TestCase):
    def test_all_fixed_corrupt_future_inputs_are_bounded_and_no_profiles_or_secrets_are_copied(self):
        self.assertEqual(len(CASES), 10)
        for case in CASES:
            key, data = case_bytes(case)
            self.assertIn(key, DEFAULTS)
            self.assertLess(len(data), 1024)
            self.assertNotIn(b'password', data)
            self.assertNotIn(b'profileID', data)
        for case in ('../connections', 'foreign-root', 'connections-delete'):
            with self.assertRaises(Refused):
                case_bytes(case)

    def test_nested_destructive_procedure_cannot_connect_or_touch_credentials(self):
        base = {'op': 'persistence-case', 'case': 'themes-future', 'assertion': 'F47-S01-A01',
                'actions': [{'op': 'file-assert-same', 'capture': 'original', 'assertion': 'F47-S01-A01'}]}
        validate_action(base)
        for action in ({'op': 'effects-setup', 'engine': 'mysql'},
                       {'op': 'credential-create', 'capture': 'account', 'value': 'empty'},
                       {'op': 'file-assert-same', 'capture': 'foreign', 'assertion': 'F47-S01-A01'}):
            changed = copy.deepcopy(base)
            changed['actions'].append(action)
            with self.assertRaises(ValueError):
                validate_action(changed)

    def test_new_backup_requires_original_bytes_distinct_identity_and_new_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'themes.json'
            original.write_bytes(b'{broken fixture')
            preexisting = root / 'themes-recovery-00000000-0000-4000-8000-000000000001.json'
            preexisting.write_bytes(original.read_bytes())
            with patch('files.native.private_path'):
                held = HeldFile(root, 'themes')
                try:
                    with self.assertRaises(Refused):
                        held.discover_backup()
                    added = root / 'themes-recovery-00000000-0000-4000-8000-000000000002.json'
                    added.write_bytes(original.read_bytes())
                    self.assertTrue(held.discover_backup()['freshRecoveryBackupVerified'])
                    added.write_bytes(b'foreign bytes')
                    with self.assertRaises(Refused):
                        held.discover_backup()
                    self.assertEqual(added.read_bytes(), b'foreign bytes')
                finally:
                    held.close()

    @unittest.skipUnless(os.name == 'nt', 'Native Windows deny-sharing mechanism only.')
    def test_native_deny_share_lock_prevents_replacement_then_releases_exact_handle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original, replacement = root / 'appearance.json', root / 'new.json'
            original.write_bytes(b'original owned bytes')
            replacement.write_bytes(b'owned replacement')
            with patch('files.native.private_path'):
                held = HeldFile(root, 'appearance')
                barrier = ReplacementBarrier(held)
                try:
                    with self.assertRaises(OSError):
                        replacement.replace(original)
                    self.assertTrue(barrier.verify()['nativeDenyWriteDeleteSharingHeld'])
                    barrier.close()
                    replacement.replace(original)
                    with self.assertRaises(Refused):
                        held.assert_same()
                    self.assertEqual(original.read_bytes(), b'owned replacement')
                finally:
                    barrier.close()
                    held.close()


class RelayMechanismTests(unittest.TestCase):
    """Opaque socket mechanism only; no simulated marker is physical DB proof."""
    def test_reverse_hold_precedes_exact_drop_and_never_credits_fake_effect(self):
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        sent, done = threading.Event(), threading.Event()
        def server():
            stream, _ = listener.accept()
            try:
                stream.settimeout(3)
                if recv_exact(stream, 5) == b'hello':
                    stream.sendall(b'ready')
                if recv_exact(stream, 13) == b'one-operation':
                    stream.sendall(b'opaque-reply')
                    sent.set()
                done.wait(timeout=3)
            finally:
                stream.close()
        peer = threading.Thread(target=server, daemon=True)
        peer.start()
        databases = Mock()
        databases.relay_receipt.return_value = {'loopbackPort': listener.getsockname()[1], 'nonce': 'original-owner'}
        relay, client = OwnedRelay(databases, 'postgresql', Journal()), None
        try:
            client = socket.create_connection(('127.0.0.1', relay.port), timeout=3)
            client.sendall(b'hello')
            self.assertEqual(recv_exact(client, 5), b'ready')
            acknowledged = relay.arm()
            self.assertTrue(acknowledged['reverseHoldAcknowledged'])
            with self.assertRaises(Refused):
                relay.arm()
            client.sendall(b'one-operation')
            self.assertTrue(sent.wait(timeout=3))
            client.settimeout(0.2)
            with self.assertRaises(socket.timeout):
                client.recv(16)
            self.assertLessEqual(len(relay.reverse), BOUND)
            relay.drop_held()
            self.assertEqual(client.recv(16), b'')
            # No real observer/Unknown outcome was verified, so cleanup cannot
            # turn this synthetic mechanism test into completed native proof.
            with self.assertRaises(Refused):
                relay.close()
            self.assertFalse(relay.verified_loss)
        finally:
            done.set()
            if client:
                client.close()
            try:
                relay.close()
            except Refused:
                pass
            listener.close()
            peer.join(timeout=4)

    def test_changed_owner_and_arbitrary_relay_target_are_never_adopted(self):
        databases = Mock()
        databases.relay_receipt.return_value = {'loopbackPort': 1, 'nonce': 'original'}
        relay = OwnedRelay(databases, 'mysql', Journal())
        try:
            for field in ('password', 'target', 'sql'):
                with self.assertRaises(Refused):
                    relay.endpoint(field)
            databases.relay_receipt.return_value = {'loopbackPort': 2, 'nonce': 'foreign'}
            with self.assertRaises(Refused):
                relay.verify()
        finally:
            with self.assertRaises(Refused):
                relay.close()

    def test_two_leases_gate_only_apply_chunks_and_preserve_original_catalog(self):
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(2)
        done = threading.Event()
        workers = []
        def upstream():
            for index in range(2):
                stream, _ = listener.accept()
                def serve(connection, role):
                    try:
                        connection.settimeout(4)
                        while not done.is_set():
                            block = connection.recv(1)
                            if not block:
                                break
                            connection.sendall(b'catalog-reply' if role == 0 else b'opaque-reply')
                    except OSError:
                        pass
                    finally:
                        connection.close()
                worker = threading.Thread(target=serve, args=(stream, index), daemon=True)
                workers.append(worker)
                worker.start()
        peer = threading.Thread(target=upstream, daemon=True)
        peer.start()
        databases = Mock()
        databases.relay_receipt.return_value = {'loopbackPort': listener.getsockname()[1], 'nonce': 'original'}
        relay = OwnedRelay(databases, 'postgresql', Journal())
        catalog = apply = None
        try:
            catalog = socket.create_connection(('127.0.0.1', relay.port), timeout=3)
            catalog.sendall(b'C')
            self.assertEqual(recv_exact(catalog, 13), b'catalog-reply')
            relay.pin_catalog()
            relay.admit_second()
            apply = socket.create_connection(('127.0.0.1', relay.port), timeout=3)
            second = relay.second_lease()
            apply.sendall(b'P')
            self.assertEqual(recv_exact(apply, 12), b'opaque-reply')
            second.arm(chunks=True)
            apply.sendall(b'A')
            response = bytearray()
            first = None
            while len(response) < 12:
                first = second.next_chunk(timeout=3)
                second.release_chunk(first)
                block = apply.recv(12 - len(response))
                self.assertTrue(block)
                response.extend(block)
            self.assertEqual(bytes(response), b'opaque-reply')
            with self.assertRaises(Refused):
                second.release_chunk(first)
            apply.sendall(b'B')
            final = second.next_chunk(timeout=3)
            self.assertNotEqual(first, final)
            catalog.sendall(b'C')
            self.assertEqual(recv_exact(catalog, 13), b'catalog-reply')
            apply.settimeout(0.2)
            with self.assertRaises(socket.timeout):
                apply.recv(32)
            with self.assertRaises(Refused):
                second.drop_held(first)
            second.drop_held(final)
            catalog.sendall(b'C')
            self.assertEqual(recv_exact(catalog, 13), b'catalog-reply')
            self.assertFalse(second.verified_loss)
            with socket.create_connection(('127.0.0.1', relay.port), timeout=3):
                with relay.condition:
                    self.assertTrue(relay.condition.wait_for(lambda: relay.failed, timeout=3))
            listener.settimeout(0.2)
            with self.assertRaises(socket.timeout):
                listener.accept()
        finally:
            done.set()
            for stream in (catalog, apply):
                if stream is not None:
                    stream.close()
            try:
                relay.close()
            except Refused:
                pass
            listener.close()
            peer.join(timeout=4)
            for worker in workers:
                worker.join(timeout=4)

    def test_unadmitted_second_connection_is_rejected_without_a_foreign_upstream(self):
        upstream = socket.socket()
        upstream.bind(('127.0.0.1', 0))
        upstream.listen(2)
        databases = Mock()
        databases.relay_receipt.return_value = {'loopbackPort': upstream.getsockname()[1], 'nonce': 'original'}
        relay = OwnedRelay(databases, 'mysql', Journal())
        first = extra = server = None
        try:
            first = socket.create_connection(('127.0.0.1', relay.port), timeout=3)
            server, _ = upstream.accept()
            self.assertTrue(relay.connected.wait(timeout=3))
            extra = socket.create_connection(('127.0.0.1', relay.port), timeout=3)
            with relay.condition:
                self.assertTrue(relay.condition.wait_for(lambda: relay.failed, timeout=3))
            with self.assertRaises(Refused):
                relay.verify()
            upstream.settimeout(0.2)
            with self.assertRaises(socket.timeout):
                upstream.accept()
        finally:
            for stream in (first, extra, server):
                if stream is not None:
                    stream.close()
            try:
                relay.close()
            except Refused:
                pass
            upstream.close()


class PhysicalApplyContractTests(unittest.TestCase):
    def test_separate_original_fixed_cases_accumulate_without_reset_or_replay(self):
        for engine in ('postgresql', 'mysql'):
            first = effect_snapshot(engine, 'sql-commit')
            self.assertEqual(first, effect_baseline(engine, {'sql-commit'}))
            second = effect_snapshot(engine, 'apply-commit', completed={'sql-commit'})
            assert_effect_snapshot(second, engine, 'apply-commit', completed={'sql-commit'})
            with self.assertRaises(ValueError):
                effect_snapshot(engine, 'sql-commit', completed={'sql-commit'})
            changed = copy.deepcopy(second)
            changed['rows'][0][1] = '2'
            with self.assertRaises(ValueError):
                assert_effect_snapshot(changed, engine, 'apply-commit', completed={'sql-commit'})

    def test_exact_apply_rows_include_generated_value_and_unchanged_other_row(self):
        for engine in ('postgresql', 'mysql'):
            value = snapshot(engine, 'acceptance-apply')
            value['rows'][0][1], value['rows'][0][4] = 'applied', '7'
            assert_apply_committed(value, engine)
            for row, column, replacement in ((0, 4, '6'), (1, 1, 'foreign'), (0, 2, '1')):
                changed = copy.deepcopy(value)
                changed['rows'][row][column] = replacement
                with self.assertRaises(ValueError):
                    assert_apply_committed(changed, engine)

    def test_missing_exact_provenance_or_stale_review_cannot_arm_or_invoke_apply(self):
        from core import Artifact
        artifact = Artifact.__new__(Artifact)
        artifact.verify, artifact.members = Mock(), {}
        with self.assertRaises(Pending):
            artifact.require_reviewed_source({'helper/internal/postgres/changes.go': 'a' * 64})
        value = workflow()
        relay = Mock(engine='postgresql')
        second = relay.second_lease.return_value
        value.relays, value.relay_catalog = {'original': relay}, {'original': {'epoch': 0}}
        value.relay_apply = {'original': {'epoch': 1, 'connectionGeneration': second.generation}}
        value.effect_cases = {'postgresql': set(), 'mysql': set()}
        with patch('run.require_sequential_apply_source'):
            with self.assertRaises(Refused):
                value.lost_apply_ack({'capture': 'original', 'engine': 'postgresql'})
        second.arm.assert_not_called()
        second.drop_held.assert_not_called()
        value.driver.action.assert_not_called()

    def test_changed_reviewed_sequential_source_refuses(self):
        with patch('db_relay.read', return_value=b'changed source'):
            with self.assertRaises(Refused):
                require_sequential_apply_source()


class OwnedTLSReceiptTests(unittest.TestCase):
    def test_public_ca_requires_producer_identity_and_same_byte_replacement_is_preserved(self):
        from observer import DatabasePair
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            public = root / 'postgres'
            public.mkdir()
            data = {'ca.crt': b'synthetic public CA', 'server.crt': b'synthetic server certificate',
                    'untrusted.crt': b'synthetic unrelated public CA',
                    'server.ext': b'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n'}
            for name, value in data.items():
                (public / name).write_bytes(value)
            def receipt(path):
                metadata = path.stat()
                return {'device': metadata.st_dev, 'inode': metadata.st_ino,
                        'size': metadata.st_size, 'sha256': digest_bytes(path.read_bytes())}
            record = {}
            pair = DatabasePair.__new__(DatabasePair)
            pair.connections = {'postgresql': (record, public)}
            pair.private_identity, pair.quiet, pair.tls_verified = receipt, Mock(), set()
            pair.owner = SimpleNamespace(directory=root,
                                         acceptance_root_identity=(root.stat().st_dev, root.stat().st_ino),
                                         acceptance_directories={id(record): (public.stat().st_dev, public.stat().st_ino)},
                                         private_files={'postgres/' + name: receipt(public / name) for name in data})
            # Only receipt/command wiring is mocked, never actual certificate
            # trust or a native TLS pass. That separate native connection remains
            # explicitly required in the returned mechanism receipt.
            self.assertTrue(pair.tls_receipt('postgresql')['realNativeTLSConnectionStillRequired'])
            pair.quiet.assert_called_once()
            replacement = public / 'replacement.crt'
            replacement.write_bytes(data['ca.crt'])
            replacement.replace(public / 'ca.crt')
            with self.assertRaises(Refused):
                pair.public_ca_path('postgresql', 'caFile')
            self.assertEqual((public / 'ca.crt').read_bytes(), data['ca.crt'])
            pair.quiet.assert_called_once()


class CompletedNativeProofTests(unittest.TestCase):
    @staticmethod
    def synthetic_database_summary():
        """Validator-only sample; never written as native/DB evidence."""
        matrix = parse(read(REPO / 'prototypes/gpui/verification/matrix.json', 2 * 1024 * 1024))
        stages = []
        for contract in matrix['databaseStages'] + [row for row in matrix['sharedStages'] if row['id'] == 'shared-go-owned-db-race']:
            shared = contract['id'] == 'shared-go-owned-db-race'
            names = contract.get('requiredTests', []) + ['sample::' + name for name in contract.get('requiredSuffixes', [])]
            proof = {'completed': True, 'exitCode': 0, 'timedOut': False, 'finishedAt': 'sample-only', 'truncatedLines': 0,
                     'tests': [{'id': name, 'outcome': 'ok'} for name in names],
                     'summaries': [{'result': 'ok', 'passed': len(names), 'failed': 0, 'ignored': 0, 'filtered': 0}]}
            stage = {'id': contract['id'], 'status': 'passed', 'requiredAssertionsExpected': len(names),
                     'requiredAssertionsObserved': len(names), 'missingRequiredAssertions': []}
            if shared:
                proof.update(command=['bash', './scripts/test-go.sh', '--require-postgres'], ignored=[], missingPackages=[],
                             summaries=[{'result': 'ok', 'package': package} for package in sorted({name.rsplit('/', 1)[0] for name in names})],
                             requiredAssertionsExpected=len(names), requiredAssertionsObserved=len(names), missingRequiredAssertions=[])
                stage['proof'] = proof
            else:
                stage['runs'] = [proof]
            stages.append(stage)
        return {'schemaVersion': 1, 'status': 'passed', 'finishedAt': 'sample-only', 'sourceSha256': PARSER_SOURCE['sourceSha256'],
                'sourceSha256After': PARSER_SOURCE['sourceSha256'],
                'sourceInventory': PARSER_SOURCE, 'sourceInventoryAfter': PARSER_SOURCE,
                'host': {'os': 'Windows', 'machine': 'AMD64', 'container': False, 'pythonBits': 64},
                'databaseFixtures': {'postgres': '16', 'mysql': '8.4', 'cleanupCompleted': True}, 'stages': stages}

    def test_database_join_requires_all_seven_rust_stages_and_exact_original_helper_death_rows(self):
        sample = self.synthetic_database_summary()
        self.assertEqual(len(task30_summary(sample, 'windows11-x64', PARSER_SOURCE)['completedDatabaseStages']), 8)
        for missing in ('db-catalog-observer', 'db-signature-metadata', 'shared-go-owned-db-race'):
            changed = copy.deepcopy(sample)
            changed['stages'] = [stage for stage in changed['stages'] if stage['id'] != missing]
            with self.subTest(missing=missing), self.assertRaises(Refused):
                task30_summary(changed, 'windows11-x64', PARSER_SOURCE)
        changed = copy.deepcopy(sample)
        proof = next(stage for stage in changed['stages'] if stage['id'] == 'db-live')['runs'][0]
        proof['tests'] = [row for row in proof['tests'] if 'postgres_real_helper_death_' not in row['id']]
        proof['summaries'][0]['passed'] -= 1
        with self.assertRaises(Refused):
            task30_summary(changed, 'windows11-x64', PARSER_SOURCE)

    def test_shared_go_passed_flag_cannot_replace_exact_non_skipped_tests_and_package_completion(self):
        sample = self.synthetic_database_summary()
        for mutation in ('missing-test', 'skipped-test', 'failed-package', 'runner', 'zero-test'):
            changed = copy.deepcopy(sample)
            proof = next(stage for stage in changed['stages'] if stage['id'] == 'shared-go-owned-db-race')['proof']
            if mutation == 'missing-test':
                proof['tests'].pop()
            elif mutation == 'skipped-test':
                proof['ignored'] = [proof['tests'][0]['id']]
            elif mutation == 'failed-package':
                proof['summaries'][0]['result'] = 'FAIL'
            elif mutation == 'runner':
                proof['command'] = ['go', 'test', './...']
            else:
                proof['tests'] = []
            with self.subTest(mutation=mutation), self.assertRaises(Refused):
                task30_summary(changed, 'windows11-x64', PARSER_SOURCE)

    def test_old_stable_database_proof_refuses_changed_production_helper_or_fixture_bytes(self):
        with tempfile.TemporaryDirectory(dir=REPO / 'build', prefix='proof-source-parser-only-') as directory:
            root = Path(directory)
            for name in SOURCE.ROOTS:
                (root / name).mkdir(parents=True, exist_ok=True)
            for name in SOURCE.FILES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'owned synthetic reviewed input')
            (root / 'scripts').mkdir()
            changed_inputs = ['prototypes/gpui/src/synthetic.rs', 'helper/synthetic.go', 'protocol/fixtures/synthetic.json']
            for name in changed_inputs:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'owned original parser fixture')
            expected = SOURCE.capture(root)
            sample = self.synthetic_database_summary()
            sample.update(sourceInventory=expected, sourceInventoryAfter=expected,
                          sourceSha256=expected['sourceSha256'], sourceSha256After=expected['sourceSha256'])
            self.assertEqual(task30_summary(sample, 'windows11-x64', expected)['postgresql'], '16')
            for name in changed_inputs:
                path = root / name
                original = path.read_bytes()
                path.write_bytes(b'changed same named reviewed parser fixture')
                with self.subTest(input=name), self.assertRaises(Refused):
                    task30_summary(sample, 'windows11-x64', SOURCE.capture(root))
                path.write_bytes(original)

    def test_candidate_verification_source_joins_each_file_proof_not_unrelated_aggregate_hashes(self):
        from types import SimpleNamespace
        artifact = Artifact.__new__(Artifact)
        provenance = {'files': copy.deepcopy(PARSER_SOURCE['files'])}
        artifact.members = {'SOURCE-PROVENANCE.json': canonical(provenance)}
        artifact.require_reviewed_source = Mock()
        with patch('core.load_module', return_value=SimpleNamespace(capture=lambda repo: PARSER_SOURCE)):
            self.assertEqual(artifact.require_verification_source(), PARSER_SOURCE)
            artifact.require_reviewed_source.assert_called_once_with({})
            provenance['files']['synthetic/parser-fixture.rs']['sha256'] = 'b' * 64
            artifact.members['SOURCE-PROVENANCE.json'] = canonical(provenance)
            with self.assertRaises(Refused):
                artifact.require_verification_source()

    def test_each_adapter_rejects_different_stable_revision_and_matrix_does_not_combine_it(self):
        expected = copy.deepcopy(PARSER_SOURCE)
        changed_files = copy.deepcopy(expected['files'])
        changed_files['synthetic/parser-fixture.rs']['sha256'] = digest_bytes(b'changed parser fixture')
        stale = SOURCE.validate(dict(expected, files=changed_files, sourceSha256=SOURCE.digest(changed_files)))
        sample = self.synthetic_database_summary()
        sample.update(sourceInventory=stale, sourceInventoryAfter=stale,
                      sourceSha256=stale['sourceSha256'], sourceSha256After=stale['sourceSha256'])
        for adapter, args in ((task30_summary, ('windows11-x64', expected)),
                              (task30_rust_summary, ('windows11-x64', expected)),
                              (macos_summary, (expected,))):
            with self.subTest(adapter=adapter.__name__), self.assertRaises(Refused):
                adapter(sample, *args)
        with tempfile.TemporaryDirectory(dir=REPO / 'build', prefix='matrix-parser-only-') as directory:
            descriptors = []
            for index, value in enumerate((self.synthetic_database_summary(), sample)):
                path = Path(directory) / ('parser-only-summary-' + str(index) + '.json')
                data = canonical(value)
                path.write_bytes(data)
                descriptors.append({'kind': 'task30-databases', 'path': str(path), 'sha256': digest_bytes(data)})
            with patch('proof_join.SOURCE.capture', return_value=expected), self.assertRaises(Refused):
                MatrixJoin(descriptors, 'windows11-x64', expected).require_complete()

    def test_matching_rust_source_keeps_native_host_and_exact_fault_row_guards(self):
        faults = parse(read(REPO / 'prototypes/gpui/fixtures/parity-matrix/fault-plan.json'))['portablePeer']['requiredTests']
        proof = {'completed': True, 'exitCode': 0, 'timedOut': False, 'finishedAt': 'parser-only', 'truncatedLines': 0,
                 'tests': [{'id': name, 'outcome': 'ok'} for name in faults],
                 'summaries': [{'result': 'ok', 'passed': 13, 'failed': 0, 'ignored': 0, 'filtered': 0}]}
        sample = {'schemaVersion': 1, 'status': 'passed', 'finishedAt': 'parser-only',
                  'sourceSha256': PARSER_SOURCE['sourceSha256'], 'sourceSha256After': PARSER_SOURCE['sourceSha256'],
                  'sourceInventory': PARSER_SOURCE, 'sourceInventoryAfter': PARSER_SOURCE,
                  'host': {'os': 'Windows', 'machine': 'AMD64', 'container': False, 'pythonBits': 64},
                  'buildMode': 'unmarked-development-tests',
                  'stages': [{'id': identifier, 'status': 'passed', 'buildMode': 'unmarked-development-tests',
                              'portableFaultAssertionsExpected': 13, 'portableFaultAssertionsObserved': 13,
                              'requiredAssertionsExpected': 13, 'requiredAssertionsObserved': 13,
                              'missingRequiredAssertions': [], 'runs': [copy.deepcopy(proof)]}
                             for identifier in ('default', 'native-smoke')]}
        self.assertEqual(task30_rust_summary(sample, 'windows11-x64', PARSER_SOURCE)['nativeOs'], 'Windows')
        for mutation in ('mac-host', 'container', 'missing-fault'):
            changed = copy.deepcopy(sample)
            if mutation == 'mac-host':
                changed['host']['os'] = 'Darwin'
            elif mutation == 'container':
                changed['host']['container'] = True
            else:
                changed['stages'][0]['runs'][0]['tests'].pop()
            with self.subTest(mutation=mutation), self.assertRaises(Refused):
                task30_rust_summary(changed, 'windows11-x64', PARSER_SOURCE)

    def test_headless_and_mac_pass_flags_without_actual_terminal_rows_refuse(self):
        for function, args in ((task30_rust_summary, ({'status': 'passed'}, 'windows11-x64', PARSER_SOURCE)),
                               (macos_summary, ({'status': 'passed', 'host': {'os': 'Darwin'}}, PARSER_SOURCE))):
            with self.assertRaises(Refused):
                function(*args)


class MacProducerConsumerProofTests(unittest.TestCase):
    """Actual-format parser streams only; these never create execution proof."""
    @staticmethod
    def collect_stream(extra=b''):
        directory = str(REPO / 'prototypes/gpui/verification')
        sys.path.insert(0, directory)
        try:
            spec = importlib.util.spec_from_file_location('dbeer_mac_parser_collector', Path(directory) / 'run.py')
            collector = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(collector)
        finally:
            sys.path.remove(directory)
        messages = []
        for package in sorted(collector.expected_go_packages()):
            messages += [{'Action': 'start', 'Package': package},
                         {'Action': 'pass', 'Package': package, 'Test': 'TestSyntheticSharedParserFixture'}]
            messages += [{'Action': 'skip', 'Package': package, 'Test': name.rsplit('/', 1)[1]}
                         for name in sorted(MAC.UNAVAILABLE_DATABASE_ROOTS) if name.rsplit('/', 1)[0] == package]
            messages.append({'Action': 'pass', 'Package': package})
        output = ('\n'.join(json.dumps(message) for message in messages) + '\nTest run with 42 tests passed after 1 second.\n').encode() + extra
        process = Mock(pid=12345, stdout=io.BytesIO(output))
        process.poll.return_value = 0
        process.wait.return_value = 0
        with patch.object(collector.subprocess, 'Popen', return_value=process):
            proof = collector.collect(['./scripts/test.sh', '--all'], {}, 10, kind='swift')
        proof['coverage'] = collector.macos_coverage(proof)
        proof['completed'] = proof['completed'] and not proof['coverage']['unapprovedSkips']
        stage = {'id': 'swiftui-regressions', 'status': 'passed' if proof['completed'] else 'failed',
                 'proof': proof, 'conditionalSkips': proof['coverage']['uncoveredDatabaseRoots']}
        return {'schemaVersion': 1, 'status': 'passed', 'finishedAt': 'parser-only',
                'sourceSha256': PARSER_SOURCE['sourceSha256'], 'sourceSha256After': PARSER_SOURCE['sourceSha256'],
                'sourceInventory': PARSER_SOURCE, 'sourceInventoryAfter': PARSER_SOURCE,
                'host': {'os': 'Darwin', 'container': False}, 'stages': [stage]}

    def test_real_collect_to_mac_consumer_allows_only_reviewed_unavailable_database_roots(self):
        sample = self.collect_stream()
        receipt = macos_summary(sample, PARSER_SOURCE)
        self.assertEqual(set(receipt['coverage']['uncoveredDatabaseRoots']), MAC.UNAVAILABLE_DATABASE_ROOTS)
        self.assertTrue(receipt['coverage']['separateCompletedDatabaseTLSLayersRequired'])
        self.assertFalse(receipt['coverage']['nativeWindowsLinuxCoverageEstablished'])
        with self.assertRaises(Refused):
            task30_rust_summary(sample, 'windows11-x64', PARSER_SOURCE)

    def test_unapproved_shared_go_or_swift_skip_refuses_both_producer_scope_and_consumer(self):
        for extra in (b'{"Action":"skip","Package":"dbeer/helper/internal/protocol","Test":"TestUnapprovedSharedContract"}\n',
                      b'Test unapprovedNativeSwiftContract() skipped after 0.001 seconds.\n'):
            sample = self.collect_stream(extra)
            proof = sample['stages'][0]['proof']
            self.assertFalse(proof['completed'])
            self.assertTrue(proof['coverage']['unapprovedSkips'])
            with self.assertRaises(Refused):
                macos_summary(sample, PARSER_SOURCE)
            # Forged passed flags still cannot erase retained skip evidence.
            proof['completed'], sample['stages'][0]['status'] = True, 'passed'
            with self.assertRaises(Refused):
                macos_summary(sample, PARSER_SOURCE)


if __name__ == '__main__':
    unittest.main(verbosity=2)
