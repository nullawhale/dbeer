"""Exact raw-byte cross-platform Task30 inputs, shared with candidate provenance.

Every host inventories the same source paths, including all platform branches.
No host-specific hash normalization or native acceptance credit is performed.
Symlink wrappers and generated/cache directories are excluded; original resource
files in assets/ and prototypes/gpui/assets/ are included explicitly.
"""
import hashlib
import os
from pathlib import Path, PurePosixPath
import re

CONTRACT = 'task30-reviewed-source-v1'
ALGORITHM = 'sha256(pathUtf8,NUL,fileSha256Bytes) in POSIX path order'
ROOTS = ('prototypes/gpui/src', 'prototypes/gpui/tests', 'prototypes/gpui/vendor', 'helper', 'protocol',
         'macos/Sources', 'macos/Tests', 'prototypes/gpui/native', 'prototypes/gpui/parity',
         'prototypes/gpui/verification', 'prototypes/gpui/fixtures', 'prototypes/gpui/acceptance',
         'prototypes/gpui/packaging', 'prototypes/gpui/assets', 'macos/Resources', 'assets')
FILES = ('.gitattributes', 'VERSION', 'BUILD_NUMBER', 'prototypes/gpui/Cargo.toml',
         'prototypes/gpui/Cargo.lock', 'prototypes/gpui/build.rs', 'prototypes/gpui/README.md',
         'macos/Package.swift', '.github/workflows/gpui-parity.yml', '.github/workflows/ci.yml')
EXCLUDED = {'build', 'target', '__pycache__', '.cache', '.git', '.agents', '.codex', '.aws'}


def paths(repo):
    repo = Path(repo)
    found = set()
    for relative in ROOTS:
        root = repo / relative
        if not root.is_dir() or root.is_symlink():
            raise ValueError('A reviewed source root is unavailable.')
        for directory, children, filenames in os.walk(root, followlinks=False):
            children[:] = sorted(name for name in children if name not in EXCLUDED
                                 and not (Path(directory) / name).is_symlink())
            found.update(path for name in filenames if (path := Path(directory) / name).is_file()
                         and not path.is_symlink() and path.suffix not in ('.pyc', '.pyo')
                         and name not in {'.DS_Store', '.git'})
    found.update(repo / relative for relative in FILES)
    found.update(path for path in (repo / 'scripts').glob('*')
                 if path.suffix in ('.sh', '.ps1', '.py') and path.is_file() and not path.is_symlink())
    for relative in ('prototypes/gpui/.cargo/config.toml', 'prototypes/gpui/.cargo/config',
                     '.cargo/config.toml', '.cargo/config'):
        if (repo / relative).exists():
            found.add(repo / relative)
    return sorted(found, key=lambda path: path.relative_to(repo).as_posix())


def digest(files):
    result = hashlib.sha256()
    for name, row in sorted(files.items()):
        result.update(name.encode('utf-8'))
        result.update(b'\0')
        result.update(bytes.fromhex(row['sha256']))
    return result.hexdigest()


def validate(value):
    if (not isinstance(value, dict) or set(value) != {'contract', 'digestAlgorithm', 'sourceSha256', 'files'}
            or value['contract'] != CONTRACT or value['digestAlgorithm'] != ALGORITHM
            or not isinstance(value['files'], dict) or not value['files']):
        raise ValueError('The exact reviewed verification source contract is required.')
    for name, row in value['files'].items():
        if (not isinstance(name, str) or '\\' in name or '\0' in name or ':' in name
                or PurePosixPath(name).is_absolute() or any(part in ('', '.', '..') for part in name.split('/'))
                or not isinstance(row, dict) or set(row) != {'sha256', 'size'}
                or not isinstance(row['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', row['sha256'])
                or type(row['size']) is not int or row['size'] < 0):
            raise ValueError('A reviewed source inventory entry is invalid.')
    if value['sourceSha256'] != digest(value['files']):
        raise ValueError('The reviewed source inventory digest differs from its entries.')
    return value


def capture(repo):
    files = {}
    for path in paths(repo):
        if not path.is_file() or path.is_symlink():
            raise ValueError('A reviewed source input changed type.')
        data = path.read_bytes()
        files[path.relative_to(repo).as_posix()] = {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
    return validate({'contract': CONTRACT, 'digestAlgorithm': ALGORITHM,
                     'sourceSha256': digest(files), 'files': files})
