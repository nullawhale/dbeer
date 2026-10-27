"""Prepared stdlib unit cases. Do not execute before final integration freeze."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from core import Refused, Pending, Artifact, archive_name, canonical, identity, parse
from credentials import OwnedCredential, SERVICE
from scenarios import catalog, new_ledger, record
from state import assert_same


def marked_identity():
    return {'schemaVersion': 1, 'productId': 'app.dbeer.DBeer', 'version': '0.2.0', 'buildNumber': '1',
            'target': 'linux-x86_64-gnu', 'protocolVersion': 3,
            'contractRevision': 'gpui-v3-captured-export-v1', 'sourceSha256': 'a' * 64,
            'capabilities': ['capturedExportV1']}


class FakeJournal:
    nonce = 'a' * 32
    def __init__(self):
        self.events = []
    def append(self, event, **value):
        self.events.append((event, value))


class FakeStore:
    def __init__(self):
        self.entries = {}
    def read(self, account):
        return self.entries.get(account)
    def write(self, account, value):
        self.entries[account] = value
    def delete(self, account):
        del self.entries[account]


class StrictMetadataTests(unittest.TestCase):
    def test_duplicate_identity_never_silently_wins(self):
        with self.assertRaises(Refused):
            parse(b'{"version":1,"version":2}')

    def test_unknown_target_protocol_capability_or_product_is_refused(self):
        valid = marked_identity()
        self.assertEqual(identity(valid, valid['target']), valid)
        for key, replacement in [('target', 'linux-aarch64-gnu'), ('protocolVersion', True),
                                 ('schemaVersion', True), ('productId', 'dev.dbeer.app'),
                                 ('capabilities', []), ('contractRevision', 'v3')]:
            invalid = dict(valid, **{key: replacement})
            with self.subTest(key=key), self.assertRaises(Refused):
                identity(invalid, valid['target'])

    def test_archive_paths_refuse_escape_alias_windows_streams_and_controls(self):
        for path in ('../dbeer-gpui', '/tmp/app', 'a//b', 'a/./b', 'a\\b', 'C:app', 'a\nb', ''):
            with self.subTest(path=path), self.assertRaises(Refused):
                archive_name(path)

    def test_untrusted_provenance_refuses_before_any_execution(self):
        value = {'archive': '/unavailable', 'checksumFile': '/unavailable.sha256',
                 'archiveSha256': 'a' * 64, 'identitySha256': 'a' * 64,
                 'manifestSha256': 'a' * 64, 'provenance': 'candidate-copied-as-previous'}
        with patch('core.subprocess.Popen') as spawn:
            with self.assertRaises(Pending):
                Artifact(value, 'ubuntu2404-x64-wayland')
            spawn.assert_not_called()


class CredentialOwnershipTests(unittest.TestCase):
    def make(self):
        store, journal = FakeStore(), FakeJournal()
        account = 'dbeer-acceptance-' + journal.nonce + '-empty'
        return store, journal, account

    def test_absent_empty_and_nonempty_remain_distinct(self):
        store, journal, account = self.make()
        credential = OwnedCredential(store, journal.nonce, account, journal)
        self.assertTrue(credential.verify()['absent'])
        credential.create(b'')
        self.assertFalse(credential.verify()['absent'])
        self.assertTrue(credential.verify()['empty'])
        credential.remove()
        self.assertIsNone(store.read(account))

    def test_collision_is_preserved_and_never_deleted(self):
        store, journal, account = self.make()
        store.entries[account] = b'preexisting synthetic collision'
        with self.assertRaises(Refused):
            OwnedCredential(store, journal.nonce, account, journal)
        self.assertIn(account, store.entries)

    def test_foreign_replacement_is_preserved(self):
        store, journal, account = self.make()
        credential = OwnedCredential(store, journal.nonce, account, journal)
        credential.create(b'owned synthetic random')
        store.entries[account] = b'foreign synthetic replacement'
        with self.assertRaises(Refused):
            credential.remove()
        self.assertEqual(store.entries[account], b'foreign synthetic replacement')
        self.assertNotIn('owned synthetic random', json.dumps(journal.events))

    def test_account_outside_owned_fixture_is_refused(self):
        with self.assertRaises(Refused):
            OwnedCredential(FakeStore(), 'a' * 32, 'production-account', FakeJournal())


class EvidenceTests(unittest.TestCase):
    def test_exact_57_by_three_separate_cells_start_not_run(self):
        result = new_ledger('a' * 32, 'synthetic')
        self.assertEqual(len(result['cells']), 171)
        self.assertEqual({c['status'] for c in result['cells']}, {'not-run'})
        self.assertFalse(result['headlessCanAccept'])

    def test_missing_independent_proof_cannot_pass(self):
        result = new_ledger('a' * 32, 'synthetic')
        with self.assertRaises(Refused):
            record(result, 'F56', 'ubuntu2404-x64-wayland', 'passed-scenario',
                   [{'kind': 'exact-owned-native-actions', 'successLabel': True}])

    def test_state_comparison_detects_identity_policy_source_and_settings_changes(self):
        before = {'profileIds': ['id'], 'profiles': [{'id': 'id', 'metadataSha256': 'a'}],
                  'documents': [{'id': 'doc', 'sourceSha256': 'a'}], 'history': [{'id': 'history', 'typedSha256': 'a'}], 'settingsSha256': {'appearance': 'a'}}
        for key in before:
            after = copy.deepcopy(before)
            after[key] = []
            with self.subTest(key=key), self.assertRaises(Refused):
                assert_same(before, after)


if __name__ == '__main__':
    unittest.main()
