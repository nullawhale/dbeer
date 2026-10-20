"""Fresh fixed destructive persistence cases; never overwrite an existing root."""
from __future__ import annotations
import os
import uuid
from core import Refused, canonical, clean_environment, digest_bytes, native, private_directory, safe
from files import HeldFile

DEFAULTS = {
    'connections': {'version': 2, 'connections': [], 'selectedProfileId': None},
    'workspace': {'version': 1, 'documents': [], 'selectedDocumentID': None, 'history': [], 'historyEnabled': True},
    'appearance': {'version': 1, 'appearanceTheme': 'system', 'applicationColorTheme': 'native', 'editorColorTheme': 'automatic'},
    'themes': {'version': 1, 'themes': []},
    'shortcuts': {'version': 1, 'overrides': []},
}
CASES = {name + '-' + failure: (name, failure) for name in DEFAULTS for failure in ('corrupt', 'future')}


def case_bytes(case):
    if case not in CASES:
        raise Refused('Only fixed corrupt/future persistence cases are authorized.')
    key, failure = CASES[case]
    if failure == 'corrupt':
        return key, b'{"version":1,"synthetic-corrupt":'
    return key, canonical({**DEFAULTS[key], 'version': 4294967295})


class PersistenceCase:
    def __init__(self, fixture, desktop, case, journal):
        key, broken = case_bytes(case)
        parent = fixture / 'persistence-cases'
        safe(fixture, directory=True)
        if not parent.exists():
            private_directory(parent)
        native.private_path(safe(parent, directory=True), directory=True)
        self.root = parent / uuid.uuid4().hex
        private_directory(self.root)
        self.env = clean_environment(self.root, desktop)
        private_directory(self.root / 'inputs')
        private_directory(self.root / 'outputs')
        self.data_root = self.root / ('data/DBeerGPUI' if desktop == 'windows11-x64' else 'config/dbeer-gpui')
        private_directory(self.data_root)
        self.identities = {}
        for name, value in DEFAULTS.items():
            data = broken if name == key else canonical(value)
            path = self.data_root / (name + '.json')
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            native.private_path(path)
            metadata = path.stat()
            self.identities[name] = (metadata.st_dev, metadata.st_ino, digest_bytes(data))
        self.original = HeldFile(self.data_root, key)
        if (*self.original.identity, self.original.expected) != self.identities[key]:
            self.original.close()
            raise Refused('Fresh destructive source was replaced before launch.')
        self.key, self.case = key, case
        journal.append('fresh-persistence-case-created', case=case, fixtureNonce=self.root.name,
                       originalSha256=self.original.expected, sourceContainsCredentials=False,
                       originalDataRootReused=False)

    def close(self):
        self.original.close()
