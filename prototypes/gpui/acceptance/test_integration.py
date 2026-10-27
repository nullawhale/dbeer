"""Prepared ownership/coverage integration cases. Runtime execution is deferred."""
from __future__ import annotations
import copy
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from core import Pending, Refused, canonical, digest_bytes
from credentials import OwnedCredential, SERVICE
from plan import required_plan, validate_action, validate_scenario
from scenarios import catalog
from run import Workflow, normal_close
from recover import recovery_claims
from proof_join import completed_run, task30_summary, MatrixJoin
from recipes.oracle import assert_script_receipts, script_receipts, snapshot

FIRST = '00000000-0000-4000-8000-000000000001'
SECOND = '00000000-0000-4000-8000-000000000002'


class Journal:
    nonce = 'a' * 32
    def __init__(self):
        self.events = []
    def append(self, event, **value):
        self.events.append({'event': event, 'runNonce': self.nonce, **value})


class Store:
    def __init__(self):
        self.entries = {}
    def exists(self, account):
        return account in self.entries
    def read(self, account):
        return self.entries.get(account)
    def write(self, account, value):
        self.entries[account] = value
    def delete(self, account):
        del self.entries[account]


def workflow():
    value = Workflow.__new__(Workflow)
    value.root, value.data_root = Path('/private/synthetic'), Path('/private/synthetic/data')
    value.epoch, value.captures, value.capture_epochs, value.profile_receipts = 0, {}, {}, {}
    value.observers = {}
    value.credentials, value.files, value.coverage, value.assertions, value.proofs = {}, {}, set(), set(), []
    value.journal, value.verify_root = Journal(), Mock()
    process = Mock(pid=123, returncode=0)
    process.poll.return_value = None
    child = Mock(process=process, normal_exit=False)
    child.identity.return_value = {'pid': 123, 'startTime': 'creation', 'sha256': 'a' * 64, 'executable': '/private/gui'}
    value.driver = Mock(child=child, artifact=Mock(), desktop='ubuntu2404-x64-wayland')
    value.driver.action.return_value = {'ownedPid': 123, 'windowKey': 'new-window', 'binding': 'original-binding'}
    return value


class StrictPlanTests(unittest.TestCase):
    def pending(self, feature):
        required = required_plan(catalog())
        row, actions = required[feature], []
        engines = {family for family in ('postgresql', 'mysql')
                   if any(engine.startswith(family) for engine in row['requiredEngines'])} or {None}
        for assertion in row['assertions']:
            for requirement in assertion['requires']:
                for engine in engines:
                    item = {'op': 'capability-required', 'capability': requirement, 'requirement': requirement,
                            'assertion': assertion['id']}
                    if engine:
                        item['engine'] = engine
                    actions.append(item)
        return actions, required

    def test_full_explicit_pending_coverage_is_prepared_not_accepted(self):
        actions, required = self.pending('F01')
        self.assertGreater(validate_scenario('F01', actions, required)['actionCount'], 0)
        value = workflow()
        with self.assertRaises(Pending):
            value.execute(actions)
        self.assertFalse(value.assertions)
        value.driver.action.assert_not_called()

    def test_missing_assertion_engine_requirement_or_zero_actions_refuses(self):
        actions, required = self.pending('F01')
        for changed in ([], actions[:-1], [item for item in actions if item.get('engine') != 'mysql']):
            with self.subTest(count=len(changed)), self.assertRaises(ValueError):
                validate_scenario('F01', changed, required)
        invalid = copy.deepcopy(actions)
        invalid[0]['engine'] = 'sqlite'
        with self.assertRaises(ValueError):
            validate_scenario('F01', invalid, required)

    def test_click_raw_actual_columns_or_unknown_operation_cannot_prove_behavior(self):
        invalid = [
            {'op': 'native', 'action': 'invoke', 'selector': 'save', 'assertion': 'F01-S01-A01'},
            {'op': 'assert-observer-rows', 'engine': 'mysql', 'query': 'values-head', 'rows': [['1']], 'assertion': 'F01-S01-A01'},
            {'op': 'native', 'action': 'invoke', 'selector': 'quit', 'expectExit': True},
            {'op': 'fault-backdoor', 'sql': 'synthetic'},
        ]
        for item in invalid:
            with self.subTest(operation=item['op']), self.assertRaises(ValueError):
                validate_action(item)


class CapturedUuidTests(unittest.TestCase):
    def test_literal_and_stale_epoch_refuse_before_policy_or_credential_access(self):
        value = workflow()
        value.remember('profile', FIRST, 'profile-id')
        value.profile_receipts[FIRST] = 0
        value.profiles = Mock(return_value=[{'id': FIRST}])
        self.assertEqual(value.profile_id('capture.profile'), FIRST)
        for reference in (FIRST, 'capture.missing'):
            with self.assertRaises(Refused):
                value.profile_id(reference)
        value.epoch = 1
        with self.assertRaises(Refused):
            value.profile_id('capture.profile')
        value.epoch = 0
        value.profiles.return_value = [{'id': SECOND}]
        with self.assertRaises(Refused):
            value.profile_id('capture.profile')

    def test_capture_key_cannot_rebind_original_owner(self):
        value = workflow()
        value.remember('profile', FIRST, 'profile-id')
        with self.assertRaises(Refused):
            value.remember('profile', SECOND, 'profile-id')


class CredentialUpdateTests(unittest.TestCase):
    def test_update_keep_rollback_empty_delete_and_foreign_collision(self):
        journal, store = Journal(), Store()
        credential = OwnedCredential(store, journal.nonce, FIRST, journal, [FIRST])
        credential.arm_ui_write(b'first fixed secret')
        with self.assertRaises(Refused):
            credential.verify()
        store.entries[FIRST] = b'first fixed secret'
        credential.verify('written')
        credential.arm_ui_update(b'')
        credential.verify('rolled-back')
        credential.arm_ui_update(b'')
        store.entries[FIRST] = b''
        self.assertTrue(credential.verify('written')['empty'])
        credential.arm_ui_update(b'next fixed secret')
        credential.verify('kept')
        store.entries[FIRST] = b'foreign'
        before = len(journal.events)
        with self.assertRaises(Refused):
            credential.arm_ui_update(b'attempt')
        self.assertEqual(len(journal.events), before)
        self.assertEqual(store.entries[FIRST], b'foreign')
        store.entries[FIRST] = b''
        credential.arm_ui_delete()
        del store.entries[FIRST]
        self.assertTrue(credential.verify('deleted')['absent'])
        self.assertNotIn('first fixed secret', canonical(journal.events).decode())

    def test_pending_or_foreign_credential_never_authorizes_cleanup(self):
        journal, store = Journal(), Store()
        credential = OwnedCredential(store, journal.nonce, FIRST, journal, [FIRST])
        credential.arm_ui_write(b'known')
        store.entries[FIRST] = b'known'
        with self.assertRaises(Refused):
            credential.remove()
        credential.verify('written')
        store.entries[FIRST] = b'foreign'
        with self.assertRaises(Refused):
            credential.remove()
        self.assertEqual(store.entries[FIRST], b'foreign')

    def test_recovery_requires_all_original_common_close_records(self):
        journal, store = Journal(), Store()
        owner = {'pid': 123, 'startTime': 'retained-creation'}
        journal.append('exact-child-created', owner=owner)
        credential = OwnedCredential(store, journal.nonce, FIRST, journal, [FIRST])
        credential.create(b'known')
        credential.arm_ui_update(b'new-known')
        with self.assertRaises(Refused):
            recovery_claims(journal.events, journal.nonce)
        journal.append('normal-close-completed', owner=owner, exitCode=0, forcedTermination=False)
        expected = recovery_claims(journal.events, journal.nonce)
        self.assertEqual(expected[FIRST], {digest_bytes(b'known'), digest_bytes(b'new-known')})
        changed = copy.deepcopy(journal.events)
        changed[-1]['owner'] = dict(changed[-1]['owner'], startTime='foreign-creation')
        with self.assertRaises(Refused):
            recovery_claims(changed, journal.nonce)


class LifecycleTests(unittest.TestCase):
    def test_normal_close_observes_retained_child_success_and_rejects_replay(self):
        value = workflow()
        actions = [{'op': 'native', 'action': 'invoke', 'selector': 'workspace.quit', 'expectExit': True}]
        normal_close(value, actions, value.journal)
        value.driver.child.process.wait.assert_called_once_with(timeout=30)
        self.assertTrue(value.driver.child.normal_exit)
        value.driver.action.assert_called_once()
        self.assertTrue(value.driver.action.call_args.kwargs['allow_exit'])
        with self.assertRaises(Refused):
            normal_close(value, actions, value.journal)

    def test_nonzero_exit_is_not_normal_close_or_rollback(self):
        value = workflow()
        value.driver.child.process.returncode = 1
        with self.assertRaises(Refused):
            normal_close(value, [{'op': 'native', 'action': 'invoke', 'selector': 'quit', 'expectExit': True}], value.journal)
        self.assertFalse(value.driver.child.normal_exit)

    def test_restart_binds_fresh_driver_and_renews_only_preserved_created_ids(self):
        value = workflow()
        old = value.driver
        value.remember('profile', FIRST, 'profile-id')
        value.profile_receipts[FIRST], value.profile_receipts[SECOND] = 0, 0
        state = {'profileIds': [FIRST], 'profiles': [{'id': FIRST}], 'documents': [{}, {}, {}],
                 'history': [{}], 'settingsSha256': {'appearance': 'a', 'themes': 'b', 'shortcuts': 'c'}}
        new = Mock(child=Mock(normal_exit=False), window_keys={'main': 'fresh'}, bindings={})
        def close(current):
            current.driver.child.normal_exit = True
        value.lifecycle = SimpleNamespace(close=Mock(side_effect=close), relaunch=Mock(return_value=new))
        value.observers = {engine: Mock() for engine in ('postgresql', 'mysql')}
        for observer in value.observers.values():
            observer.wait_scalar.return_value = {'count': 0}
        with patch('run.typed_state', return_value=state):
            value.restart()
        self.assertIs(value.driver, new)
        self.assertIsNot(value.driver, old)
        self.assertEqual(value.profile_receipts, {FIRST: 1})
        self.assertEqual(value.capture_epochs['profile'], (1, 'profile-id'))
        for observer in value.observers.values():
            observer.wait_scalar.assert_called_once()


class IndependentProofTests(unittest.TestCase):
    def test_script_exact_receipts_reject_skipped_duplicate_and_changed_metadata(self):
        for engine in ('postgresql', 'mysql'):
            for case in ('script-success', 'script-first-error', 'script-middle-error'):
                expected = script_receipts(engine, case)
                assert_script_receipts(expected, engine, case)
                for mutation in ('missing', 'extra', 'metadata'):
                    changed = copy.deepcopy(expected)
                    if mutation == 'missing':
                        changed['rows'].pop()
                    elif mutation == 'extra':
                        changed['rows'].append(['script-success', '3', '33'])
                    else:
                        changed['columns'][0]['nativeType'] = 'FLOAT'
                    with self.assertRaises(ValueError):
                        assert_script_receipts(changed, engine, case)

    def test_zero_test_skipped_headless_and_missing_matrix_proofs_refuse(self):
        with self.assertRaises(Refused):
            completed_run({'completed': True, 'exitCode': 0, 'timedOut': False, 'summaries': []})
        with self.assertRaises(Refused):
            task30_summary({'schemaVersion': 1, 'status': 'passed', 'stages': []}, 'windows11-x64', {})
        with self.assertRaises(Pending):
            MatrixJoin([], 'windows11-x64', {})


class OwnedEffectsBoundaryTests(unittest.TestCase):
    def test_copied_foreign_receipt_cannot_reach_docker_or_source_reads(self):
        import sys
        from core import REPO, load_module
        fake_run = SimpleNamespace(REPO=REPO, now=Mock(), private_directory=Mock(),
                                   require_go_assertions=Mock(), strict_json=Mock(),
                                   verify_private=Mock(), write_json=Mock())
        with patch.dict(sys.modules, {'run': fake_run}):
            module = load_module('dbeer_owned_effects_test', REPO / 'prototypes/gpui/verification/owned_databases.py')
        owner = module.OwnedDatabases.__new__(module.OwnedDatabases)
        receipt = {'engine': 'postgres', 'containerId': 'a' * 64, 'syntheticCorpusInstalled': True}
        owner.records, owner.acceptance_receipts = [receipt], {id(receipt): {}}
        with patch.object(module, 'quiet') as command:
            with self.assertRaises(ValueError):
                owner.setup_acceptance_effects(dict(receipt))
            command.assert_not_called()
        fake_run.require_go_assertions.assert_not_called()
        fake_run.verify_private.assert_not_called()

    def test_failed_unknown_effects_setup_is_not_replayed(self):
        import sys
        from core import REPO, load_module
        fake_run = SimpleNamespace(REPO=REPO, now=Mock(), private_directory=Mock(),
                                   require_go_assertions=Mock(), strict_json=Mock(),
                                   verify_private=Mock(), write_json=Mock())
        with patch.dict(sys.modules, {'run': fake_run}):
            module = load_module('dbeer_owned_effects_retry_test', REPO / 'prototypes/gpui/verification/owned_databases.py')
        owner = module.OwnedDatabases.__new__(module.OwnedDatabases)
        receipt = {'engine': 'mysql', 'syntheticCorpusInstalled': True, 'acceptanceEffectsState': 'failed-unknown'}
        owner.records, owner.acceptance_receipts = [receipt], {id(receipt): {}}
        with patch.object(module, 'quiet') as command:
            with self.assertRaises(ValueError):
                owner.setup_acceptance_effects(receipt)
            command.assert_not_called()
        fake_run.require_go_assertions.assert_not_called()
        fake_run.verify_private.assert_not_called()


class HeldFileBoundaryTests(unittest.TestCase):
    def test_same_bytes_foreign_inode_is_preserved(self):
        import tempfile
        from files import HeldFile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'connections.json'
            original.write_bytes(b'{"synthetic":true}')
            with patch('files.native.private_path'):
                held = HeldFile(root, 'connections')
                replacement = root / 'replacement.json'
                replacement.write_bytes(original.read_bytes())
                try:
                    try:
                        replacement.replace(original)
                    except PermissionError:
                        # Native Windows may correctly refuse replacing a held
                        # file. This does not establish the replacement branch.
                        self.assertEqual(held.assert_same()['sha256'], digest_bytes(original.read_bytes()))
                        return
                    with self.assertRaises(Refused):
                        held.assert_same()
                    self.assertTrue(original.exists())
                    self.assertEqual(original.read_bytes(), b'{"synthetic":true}')
                finally:
                    held.close()
