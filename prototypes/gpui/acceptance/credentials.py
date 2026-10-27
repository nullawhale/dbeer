"""Exact reserved native credential ownership; secrets remain in memory."""
from __future__ import annotations
import ctypes
import os
import re
from core import Refused, Pending, digest_bytes

SERVICE = 'dev.dbeer.gpui-prototype'


class WindowsStore:
    def __init__(self):
        class Credential(ctypes.Structure):
            _fields_ = [('Flags', ctypes.c_uint32), ('Type', ctypes.c_uint32), ('TargetName', ctypes.c_wchar_p),
                        ('Comment', ctypes.c_wchar_p), ('LastWritten', ctypes.c_uint64),
                        ('CredentialBlobSize', ctypes.c_uint32), ('CredentialBlob', ctypes.c_void_p),
                        ('Persist', ctypes.c_uint32), ('AttributeCount', ctypes.c_uint32),
                        ('Attributes', ctypes.c_void_p), ('TargetAlias', ctypes.c_wchar_p), ('UserName', ctypes.c_wchar_p)]
        self.Credential = Credential
        self.api = ctypes.WinDLL('advapi32', use_last_error=True)
        self.api.CredReadW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.POINTER(Credential))]
        self.api.CredWriteW.argtypes = [ctypes.POINTER(Credential), ctypes.c_uint32]
        self.api.CredDeleteW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32]
        self.api.CredFree.argtypes = [ctypes.c_void_p]

    def target(self, account):
        # Verified against the locked keyring 3.6.3 windows-native adapter.
        return account + '.' + SERVICE

    def exists(self, account):
        pointer = ctypes.POINTER(self.Credential)()
        if not self.api.CredReadW(self.target(account), 1, 0, ctypes.byref(pointer)):
            if ctypes.get_last_error() == 1168:
                return False
            raise Refused('Native credential lookup failed; absence is unproven.')
        self.api.CredFree(pointer)
        return True

    def read(self, account):
        pointer = ctypes.POINTER(self.Credential)()
        if not self.api.CredReadW(self.target(account), 1, 0, ctypes.byref(pointer)):
            if ctypes.get_last_error() == 1168:
                return None
            raise Refused('Native credential lookup failed; absence is unproven.')
        try:
            value = pointer.contents
            if value.TargetName != self.target(account) or value.UserName != account:
                raise Refused('Native credential identity differs.')
            blob = ctypes.string_at(value.CredentialBlob, value.CredentialBlobSize)
            return blob.decode('utf-16-le').encode('utf-8')
        finally:
            self.api.CredFree(pointer)

    def write(self, account, secret):
        blob = ctypes.create_string_buffer(secret.decode('utf-8').encode('utf-16-le'))
        value = self.Credential()
        value.Type, value.TargetName, value.UserName = 1, self.target(account), account
        value.Comment, value.Persist = 'DBeer disposable installed acceptance', 3
        value.CredentialBlobSize = len(blob.raw) - 1
        value.CredentialBlob = ctypes.cast(blob, ctypes.c_void_p)
        try:
            if not self.api.CredWriteW(ctypes.byref(value), 0):
                raise Refused('Native credential write failed.')
        finally:
            ctypes.memset(blob, 0, len(blob))

    def delete(self, account):
        if not self.api.CredDeleteW(self.target(account), 1, 0):
            raise Refused('Native credential removal failed.')


class SecretServiceStore:
    def __init__(self):
        # Test-only dependency; no installation, unlock or default keyring change.
        try:
            import secretstorage
            self.module = secretstorage
            self.bus = secretstorage.dbus_init()
            self.collection = secretstorage.get_default_collection(self.bus)
            if self.collection.is_locked():
                raise Pending('Native Secret Service is locked.')
        except ImportError:
            raise Pending('Test-only python3-secretstorage is unavailable.') from None

    def matches(self, account):
        # Search exact service+account across collections also catches legacy entries
        # lacking target; any collision refuses before creation, even if locked.
        items = list(self.module.search_items(self.bus, {'service': SERVICE, 'username': account}))
        if len(items) > 1:
            raise Refused('Ambiguous reserved credential collision.')
        return items

    def exists(self, account):
        return bool(self.matches(account))

    def read(self, account):
        items = self.matches(account)
        if not items:
            return None
        item = items[0]
        if item.is_locked():
            raise Pending('Exact reserved credential is locked; absence is unproven.')
        attributes = item.get_attributes()
        if attributes.get('target', 'default') != 'default':
            raise Refused('Foreign credential target collision.')
        return bytes(item.get_secret())

    def write(self, account, secret):
        self.collection.create_item('DBeer disposable installed acceptance',
                                    {'service': SERVICE, 'username': account, 'target': 'default', 'application': 'rust-keyring'},
                                    secret, replace=False, content_type='text/plain; charset=utf8')

    def delete(self, account):
        items = self.matches(account)
        if len(items) != 1 or items[0].is_locked():
            raise Refused('Exact owned credential unavailable for cleanup.')
        items[0].delete()


class OwnedCredential:
    def __init__(self, store, nonce, account, journal, owned_profile_ids=()):
        if not re.fullmatch('[0-9a-f]{32}', nonce):
            raise Refused('Reserved credential owner nonce invalid.')
        if account not in owned_profile_ids and not re.fullmatch('dbeer-acceptance-' + nonce + '-[a-z0-9-]{1,32}', account):
            raise Refused('Credential account is not an owned synthetic profile.')
        self.store, self.account, self.journal = store, account, journal
        self.expected = None
        self.pending = None
        exists = store.exists(account) if hasattr(store, 'exists') else store.read(account) is not None
        if exists:
            journal.append('credential-collision', service=SERVICE, account=account, collision=True)
            raise Refused('Reserved credential already exists; preserve collision.')
        self.absent_proven = True
        journal.append('credential-absence-proven', service=SERVICE, account=account, ownerNonce=nonce)

    def create(self, value):
        if self.pending is not None or self.expected is not None or (self.store.exists(self.account) if hasattr(self.store, 'exists') else self.store.read(self.account) is not None):
            raise Refused('Credential collision before creation.')
        if not isinstance(value, bytes) or len(value) > 2048:
            raise Refused('Synthetic credential exceeds bounds.')
        expected = digest_bytes(value)
        # Intent precedes write for crash recovery; never serialize the value.
        self.journal.append('credential-create-intent', service=SERVICE, account=self.account, expectedSha256=expected)
        self.expected = expected
        self.store.write(self.account, value)
        if self.store.read(self.account) != value:
            raise Refused('Native credential readback differs.')
        self.journal.append('credential-owned', service=SERVICE, account=self.account, valueSha256=expected,
                            state='empty' if not value else 'nonempty')

    def arm_ui_write(self, value):
        if self.expected is not None or self.pending is not None:
            raise Refused('First UI write requires the original reserved absence.')
        self._arm(value, first=True)

    def arm_ui_update(self, value):
        if self.expected is None or self.pending is not None:
            raise Refused('UI update requires a confirmed owned current value.')
        self._arm(value)

    def arm_ui_delete(self):
        if self.expected is None or self.pending is not None:
            raise Refused('UI deletion requires a confirmed owned current value.')
        self._arm(None)

    def _arm(self, value, first=False):
        if value is not None and (not isinstance(value, bytes) or len(value) > 2048):
            raise Refused('Synthetic credential exceeds bounds.')
        self.verify()
        target = None if value is None else digest_bytes(value)
        self.journal.append('credential-create-intent' if first else 'credential-update-intent',
                            service=SERVICE, account=self.account, priorSha256=self.expected,
                            expectedSha256=target, owner='actual-ui-profile-save')
        self.pending = {'prior': self.expected, 'target': target}

    def verify(self, outcome=None):
        if self.pending is not None:
            if outcome not in ('written', 'deleted', 'kept', 'rolled-back'):
                raise Refused('Pending credential intent needs an explicit terminal outcome.')
            target = self.pending['target'] if outcome in ('written', 'deleted') else self.pending['prior']
            if (outcome == 'deleted') != (self.pending['target'] is None) and outcome in ('written', 'deleted'):
                raise Refused('Credential terminal outcome differs from the armed intent.')
        else:
            if outcome is not None:
                raise Refused('Credential terminal has no armed original intent.')
            target = self.expected
        value = self.store.read(self.account)
        actual = None if value is None else digest_bytes(value)
        if actual != target:
            raise Refused('Owned credential absent/value hash differs; preserve foreign replacement.')
        if self.pending is not None:
            self.journal.append('credential-ui-terminal', service=SERVICE, account=self.account,
                                priorSha256=self.pending['prior'], attemptedSha256=self.pending['target'],
                                expectedSha256=target, outcome=outcome, absent=value is None)
            self.expected, self.pending = target, None
        return {'absent': value is None, 'empty': value == b'', 'valueSha256': target}

    def remove(self):
        if self.pending is not None:
            raise Refused('Unresolved UI credential intent cannot authorize cleanup.')
        value = self.store.read(self.account)
        if value is None:
            return
        if self.expected is None or digest_bytes(value) != self.expected:
            self.journal.append('credential-cleanup-refused', service=SERVICE, account=self.account, foreignReplacement=True)
            raise Refused('Foreign credential replacement preserved.')
        if hasattr(self.store, 'delete_expected'):
            self.store.delete_expected(self.account, self.expected)
        else:
            self.store.delete(self.account)
        if self.store.read(self.account) is not None:
            raise Refused('Credential absence after cleanup unproven.')
        self.journal.append('credential-cleaned', service=SERVICE, account=self.account, absent=True)


def native_store():
    return WindowsStore() if os.name == 'nt' else SecretServiceStore()


class BoundedStore:
    """A blocked/locked native service cannot hang the fixture owner indefinitely."""
    def __init__(self, env):
        import sys
        from pathlib import Path
        self.env = env
        python = sys.executable if os.name == 'nt' else '/usr/bin/python3'
        self.command = [python, str(Path(__file__).with_name('credential_driver.py'))]

    def call(self, operation, account, **fields):
        from core import bounded_call, canonical, parse
        value = parse(bounded_call(self.command, self.env, canonical({'operation': operation, 'account': account, **fields}), limit=16384, timeout=15))
        if value.get('refused'):
            raise Refused('Native credential operation refused.')
        return value

    def exists(self, account):
        return self.call('exists', account)['present']

    def read(self, account):
        import base64
        result = self.call('read', account)
        return None if result['absent'] else base64.b64decode(result['valueBase64'], validate=True)

    def write(self, account, secret):
        import base64
        self.call('create', account, valueBase64=base64.b64encode(secret).decode())

    def delete_expected(self, account, expected_sha):
        self.call('delete', account, expectedSha256=expected_sha)
