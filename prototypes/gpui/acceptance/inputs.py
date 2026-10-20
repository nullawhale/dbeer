"""Pinned fixed source inputs; no request-controlled SQL or source file paths."""
from __future__ import annotations
import os
import re
from pathlib import Path
from core import REPO, Refused, canonical, digest_bytes, native, parse, read, safe

FIXTURES = REPO / 'prototypes/gpui/fixtures/installed-acceptance'


def source_catalog():
    value = parse(read(FIXTURES / 'recipes/source-inputs.json', 1024 * 1024))
    if (set(value) != {'schemaVersion', 'kind', 'sources', 'corpusSha256'}
            or value['schemaVersion'] != 1 or value['kind'] != 'pinned-fixed-source-inputs'
            or not value['sources']):
        raise Refused('Fixed input manifest differs.')
    corpus = read(FIXTURES / 'recipes/input-corpus.json', 1024 * 1024)
    if digest_bytes(corpus) != value['corpusSha256']:
        raise Refused('Fixed corpus changed after source pinning.')
    return value, parse(corpus)


def corpus_inputs():
    _, corpus = source_catalog()
    # No recursive arbitrary JSON pointer interpolation. Only explicitly bounded
    # known strings can enter the native worker over its existing anonymous pipe.
    result = {key: corpus[key] for key in ('editorUnicodeCRLF', 'nullMarker', 'applyCommittedLabel')}
    for engine in ('postgresql', 'mysql'):
        for name, text in corpus['queries'][engine].items():
            if not re.fullmatch('[A-Za-z][A-Za-z0-9]{0,63}', name) or not isinstance(text, str):
                raise Refused('Fixed query key differs.')
            result['queries.' + engine + '.' + name] = text
    for index, item in enumerate(corpus['typedAssignments']):
        if item.get('kind') == 'text':
            result['typedAssignments.' + str(index)] = item['value']
    if any(not isinstance(text, str) or len(text.encode()) > 49152 for text in result.values()):
        raise Refused('Fixed native input exceeds bounded pipe payload.')
    return result


class StagedInputs:
    """Exclusive staged files retained for review, rechecked before chooser use."""
    def __init__(self, root, journal):
        self.root, self.journal = safe(root, directory=True), journal
        self.root_identity = (self.root.stat().st_dev, self.root.stat().st_ino)
        self.manifest, _ = source_catalog()
        self.receipts = {}

    def stage(self, key):
        metadata = safe(self.root, directory=True).stat()
        native.private_path(self.root, directory=True)
        if (metadata.st_dev, metadata.st_ino) != self.root_identity:
            raise Refused('Original staging directory changed before source copy.')
        if key in self.receipts or key not in self.manifest['sources']:
            raise Refused('Source key is unknown or already staged.')
        entry = self.manifest['sources'][key]
        if set(entry) != {'path', 'sha256', 'size', 'filename'}:
            raise Refused('Fixed source descriptor differs.')
        relative = Path(entry['path'])
        if relative.is_absolute() or '..' in relative.parts or '\\' in entry['path']:
            raise Refused('Source manifest escaped repository.')
        source = safe(REPO / relative)
        data = read(source, 2 * 1024 * 1024)
        if len(data) != entry['size'] or digest_bytes(data) != entry['sha256']:
            raise Refused('Fixed source pin changed.')
        name = entry['filename']
        if not re.fullmatch('[a-z0-9][a-z0-9.-]{0,100}', name):
            raise Refused('Fixed staging filename differs.')
        path = self.root / name
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        native.private_path(path)
        metadata = path.stat()
        self.receipts[key] = (path, metadata.st_dev, metadata.st_ino, entry['sha256'], len(data))
        self.journal.append('fixed-input-staged', sourceKey=key, sha256=entry['sha256'], size=len(data))
        return self.path(key)

    def path(self, key):
        if key not in self.receipts:
            raise Refused('Chooser input must be explicitly staged first.')
        path, device, inode, expected, size = self.receipts[key]
        safe(self.root, directory=True)
        parent = self.root.stat()
        if (parent.st_dev, parent.st_ino) != self.root_identity:
            raise Refused('Original staged input directory changed.')
        safe(path)
        native.private_path(path)
        metadata = path.stat()
        if (metadata.st_dev, metadata.st_ino, metadata.st_size) != (device, inode, size):
            raise Refused('Original staged input identity changed.')
        if digest_bytes(read(path, size)) != expected:
            raise Refused('Original staged input bytes changed.')
        return str(path)
