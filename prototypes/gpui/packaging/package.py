#!/usr/bin/env python3
"""Native, fail-closed development/candidate archive preparation. No installation/publication."""
import argparse
import ctypes
import gzip
import hashlib
import html
import io
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import queue
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zipfile

if sys.version_info < (3, 11):
    print('DBeer packaging requires Python 3.11 or later.', file=sys.stderr)
    sys.exit(2)
import tomllib

ROOT = Path(__file__).resolve().parents[3]
LINUX_OS_RELEASE = Path('/etc/os-release')
APP_ID = 'app.dbeer.DBeer'
CAPABILITY = 'capturedExportV1'
CONTRACT = 'gpui-v3-captured-export-v1'
TARGETS = {'linux-x86_64-gnu': 'x86_64-unknown-linux-gnu',
           'windows-x86_64-msvc': 'x86_64-pc-windows-msvc'}
THEMES = ['dbeer-light.json', 'dbeer-dark.json', 'light_plus.json', 'light_vs.json',
          'dark_plus.json', 'dark_vs.json', 'solarized-light-color-theme.json',
          'solarized-dark-color-theme.json', 'jetbrains-default.icls', 'jetbrains-darcula.icls',
          'NOTICE.txt', 'LICENSE-vscode.txt', 'NOTICE-jetbrains.txt', 'LICENSE-jetbrains.txt', 'PROVENANCE.md']


class Refused(Exception):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def same_identity(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def owned_cleanup(path, identity, entries=None):
    """Remove only an unchanged exact stage inventory; foreign entries survive."""
    if not path.exists() or path.is_symlink():
        return
    if not same_identity(identity, path.stat(follow_symlinks=False)):
        return
    expected = entries or {}
    actual = {str(item.relative_to(path)): item.lstat() for item in path.rglob('*')}
    if set(actual) != set(expected) or any(not same_identity(actual[name], original)
                                         or stat.S_IFMT(actual[name].st_mode) != stat.S_IFMT(original.st_mode)
                                         for name, original in expected.items()):
        return
    for name in sorted(actual, key=lambda name: (len(Path(name).parts), name), reverse=True):
        item = path / name
        if not same_identity(expected[name], item.lstat()):
            return
        if stat.S_ISDIR(expected[name].st_mode):
            item.rmdir()
        elif stat.S_ISREG(expected[name].st_mode):
            item.unlink()
        else:
            return
    if same_identity(identity, path.lstat()):
        path.rmdir()


class StageOwner:
    def __init__(self, root):
        self.root, self.entries = root, {}

    def remember(self, path):
        for item in reversed([path, *path.parents]):
            if item == self.root or not item.is_relative_to(self.root):
                continue
            name, identity = str(item.relative_to(self.root)), item.lstat()
            if name in self.entries and not same_identity(self.entries[name], identity):
                raise Refused('An owned stage entry was replaced.')
            self.entries[name] = identity

    def moved(self, source, destination=None):
        prefix = str(source.relative_to(self.root))
        moved = {name: original for name, original in self.entries.items()
                 if name == prefix or name.startswith(prefix + os.sep)}
        for name in moved:
            del self.entries[name]
        if destination is not None:
            replacement = str(destination.relative_to(self.root))
            for name, original in moved.items():
                self.entries[replacement + name[len(prefix):]] = original


def publish_directory(source, destination):
    """Atomic no-replace publication, including an existing empty destination."""
    if os.name == 'nt':
        os.rename(source, destination)  # Windows rename refuses an existing path.
        return
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'linux':
        function = library.renameat2
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = function(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    elif sys.platform == 'darwin':
        function = library.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = function(os.fsencode(source), os.fsencode(destination), 4)
    else:
        raise Refused('Atomic no-replace publication is unavailable.')
    if result != 0:
        raise Refused('Atomic no-replace publication refused an existing or unsupported destination.')


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise Refused('Duplicate metadata field.')
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs)
    except (ValueError, UnicodeError):
        raise Refused('Invalid metadata.') from None


def safe(path, *, directory=False, missing=False):
    path = Path(os.path.abspath(path))
    if any(c in str(path) for c in '\0\r\n'):
        raise Refused('Unsupported input path.')
    for item in [*reversed(path.parents), path]:
        try:
            entry = item.lstat()
        except FileNotFoundError:
            if missing:
                continue
            raise Refused('Required input is missing.') from None
        # Windows symlink/junction/mount reparse points must also refuse.
        if (stat.S_ISLNK(entry.st_mode)
                or getattr(entry, 'st_file_attributes', 0) & 0x400):
            raise Refused('Symlinks and reparse points are not package inputs.')
        if item != path and not stat.S_ISDIR(entry.st_mode):
            raise Refused('An input parent is not a directory.')
    if path.exists() and (directory != path.is_dir() or (not directory and not path.is_file())):
        raise Refused('Unexpected input type.')
    return path


def bounded(path, limit=16 * 1024 * 1024):
    path = safe(path)
    with path.open('rb') as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise Refused('An input exceeds its size limit.')
    return data


def shared_version():
    version = bounded(ROOT / 'VERSION', 64).decode('ascii').strip()
    build = bounded(ROOT / 'BUILD_NUMBER', 64).decode('ascii').strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise Refused('Invalid shared release metadata.')
    return version, build


def verification_contract():
    path = ROOT / 'prototypes/gpui/verification/source_contract.py'
    spec = importlib.util.spec_from_file_location('dbeer_package_verification_source', path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def source_files():
    # Candidate provenance must contain every actual Task30 producer input.
    # The package digest and Task30 digest remain deliberately distinct; their
    # join compares per-file raw-byte proofs, never unrelated aggregate hashes.
    files = set(verification_contract().paths(ROOT))
    for relative in ['prototypes/gpui/src', 'prototypes/gpui/vendor', 'prototypes/gpui/assets',
                     'prototypes/gpui/packaging', 'prototypes/gpui/fixtures', 'helper', 'protocol']:
        root = safe(ROOT / relative, directory=True)
        # Older tools may have placed ignored outputs below helper/. Never let
        # local caches, binaries or private Git metadata enter source identity.
        for directory, names, filenames in os.walk(root, followlinks=False):
            names[:] = sorted(name for name in names
                              if name not in {'build', 'target', '.cache', '.git', '__pycache__'})
            for name in names:
                safe(Path(directory) / name, directory=True)
            for name in filenames:
                path = Path(directory) / name
                if path.suffix == '.pyc' or name in {'.DS_Store', '.git'}:
                    continue
                files.add(safe(path))
    for relative in ['VERSION', 'BUILD_NUMBER', 'CHANGELOG.md', 'macos/Resources/AppIcon.svg',
                     'macos/Resources/AppIcon.png', 'prototypes/gpui/Cargo.toml',
                     'prototypes/gpui/Cargo.lock', 'scripts/gpui-prototype.sh',
                     'scripts/build-gpui-client.sh', 'scripts/build-gpui-client.ps1',
                     'scripts/package-gpui-client.sh', 'scripts/package-gpui-client.ps1']:
        files.add(safe(ROOT / relative))
    for relative in ['.gitattributes', 'prototypes/gpui/build.rs', 'prototypes/gpui/.cargo/config.toml',
                     'prototypes/gpui/.cargo/config', '.cargo/config.toml', '.cargo/config']:
        if (ROOT / relative).exists() or (ROOT / relative).is_symlink():
            files.add(safe(ROOT / relative))
    return sorted(files, key=lambda path: path.relative_to(ROOT).as_posix())


def source_digest():
    digest = hashlib.sha256()
    for path in source_files():
        name = path.relative_to(ROOT).as_posix().encode()
        data = bounded(path, 64 * 1024 * 1024)
        digest.update(len(name).to_bytes(8, 'big'))
        digest.update(name)
        digest.update(len(data).to_bytes(8, 'big'))
        digest.update(data)
    return digest.hexdigest()


def new_identity(target):
    version, build = shared_version()
    return validate_identity({'schemaVersion': 1, 'productId': APP_ID, 'version': version, 'buildNumber': build,
                              'target': target, 'protocolVersion': 3, 'contractRevision': CONTRACT,
                              'sourceSha256': source_digest(), 'capabilities': [CAPABILITY]}, target)


def validate_identity(value, target):
    required = {'schemaVersion', 'productId', 'version', 'buildNumber', 'target',
                'protocolVersion', 'contractRevision', 'sourceSha256', 'capabilities'}
    if (target not in TARGETS or not isinstance(value, dict) or set(value) != required or value['schemaVersion'] != 1
            or type(value['schemaVersion']) is not int or value['productId'] != APP_ID
            or value['target'] != target or value['protocolVersion'] != 3
            or type(value['protocolVersion']) is not int or value['contractRevision'] != CONTRACT
            or value['capabilities'] != [CAPABILITY]
            or not isinstance(value['sourceSha256'], str)
            or not re.fullmatch('[0-9a-f]{64}', value['sourceSha256'])):
        raise Refused('Unsupported product build metadata.')
    if (not isinstance(value['version'], str) or len(value['version']) > 32
            or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value['version'])
            or not isinstance(value['buildNumber'], str) or len(value['buildNumber']) > 20
            or not re.fullmatch('[1-9][0-9]*', value['buildNumber'])):
        raise Refused('Invalid product version/build metadata.')
    return value


def canonical_identity(data, target):
    value = validate_identity(strict_json(data), target)
    if len(data) > 4096 or data != json_bytes(value):
        raise Refused('Build identity files require exact canonical bytes and one final newline.')
    return value


def source_snapshot(identity):
    retained = {path.relative_to(ROOT).as_posix(): bounded(path, 64 * 1024 * 1024)
                for path in source_files()}
    digest = hashlib.sha256()
    for name, data in retained.items():
        encoded = name.encode()
        digest.update(len(encoded).to_bytes(8, 'big'))
        digest.update(encoded)
        digest.update(len(data).to_bytes(8, 'big'))
        digest.update(data)
    if digest.hexdigest() != identity['sourceSha256'] or identity != new_identity(identity['target']):
        raise Refused('Source provenance changed after the paired build.')
    return ({'schemaVersion': 1, 'identity': identity,
             'digestAlgorithm': 'sha256(pathLengthU64BE,pathUtf8,dataLengthU64BE,data) in path order',
             'files': {name: {'sha256': sha(data), 'size': len(data)} for name, data in retained.items()}}, retained)


def source_provenance(identity):
    return source_snapshot(identity)[0]


def native(target):
    if platform.machine().lower() not in {'x86_64', 'amd64'} or struct.calcsize('P') != 8:
        raise Refused('Only native x64 candidate packaging is supported.')
    if any(os.environ.get(name) for name in ['CARGO_BUILD_TARGET', 'GOOS', 'GOARCH']):
        raise Refused('Cross-build environment overrides are not package inputs.')
    if target == 'linux-x86_64-gnu':
        if sys.platform != 'linux':
            raise Refused('Ubuntu packages must be prepared on Ubuntu.')
        values = {}
        # OS metadata commonly links to /usr/lib/os-release. Resolve this one
        # fixed system path; package inputs still reject symlinks in safe().
        for line in bounded(LINUX_OS_RELEASE.resolve(), 8192).decode('utf-8').splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                values[key] = value.strip('"')
        if values.get('ID') != 'ubuntu' or values.get('VERSION_ID') != '24.04':
            raise Refused('The Ubuntu 24.04 glibc baseline requires its native builder.')
    elif target == 'windows-x86_64-msvc':
        if sys.platform != 'win32':
            raise Refused('Windows packages must be prepared on Windows.')
    else:
        raise Refused('Unsupported product target.')


def binary_header(path, target):
    data = bounded(path, 512 * 1024 * 1024)
    if target == 'linux-x86_64-gnu':
        if (len(data) < 64 or data[:6] != b'\x7fELF\x02\x01'
                or struct.unpack_from('<H', data, 18)[0] != 62):
            raise Refused('Expected an ELF64 x86-64 native binary.')
    else:
        if len(data) < 64 or data[:2] != b'MZ':
            raise Refused('Expected a Windows x64 native binary.')
        offset = struct.unpack_from('<I', data, 60)[0]
        if (offset + 26 > len(data) or data[offset:offset+4] != b'PE\0\0'
                or struct.unpack_from('<H', data, offset+4)[0] != 0x8664
                or struct.unpack_from('<H', data, offset+24)[0] != 0x20b):
            raise Refused('Expected a PE32+ AMD64 native binary.')
    return data


def checked_output(command, *, limit, timeout, environment=None):
    """Bound output in memory while retaining only the exact owned child."""
    deadline = time.monotonic()+timeout
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=environment)
    result = queue.Queue(maxsize=1)
    def read():
        try:
            value = bytearray()
            while len(value) <= limit:
                chunk = process.stdout.read1(min(65536, limit+1-len(value)))
                if not chunk:
                    break
                value.extend(chunk)
            result.put(bytes(value))
        except OSError:
            result.put(None)
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        value = result.get(timeout=timeout)
        if value is None or len(value) > limit:
            raise Refused('Native metadata exceeded its bound.')
        if process.wait(timeout=max(0.01, deadline-time.monotonic())) != 0:
            raise Refused('Native metadata inspection failed.')
        return value
    except (queue.Empty, subprocess.SubprocessError):
        raise Refused('Native metadata inspection timed out.') from None
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        if not reader.is_alive():
            process.stdout.close()


def reported_build(path, component, expected):
    # Runs only when an operator explicitly packages exact native build inputs.
    # The integrated --build-info mode must exit before GUI/data/helper startup.
    environment = dict(os.environ)
    for name in list(environment):
        if name.startswith(('DBEER_', 'PG', 'MYSQL')):
            del environment[name]
    try:
        output = checked_output([str(path), '--build-info'], limit=8192, timeout=10, environment=environment)
    except (OSError, subprocess.SubprocessError):
        raise Refused('Native build metadata could not be verified.') from None
    value = strict_json(output)
    if (not isinstance(value, dict) or set(value) != {'component', 'identity'}
            or value['component'] != component or value['identity'] != expected):
        raise Refused('GUI and helper must report the exact expected product build.')


def native_dependencies(path, target):
    if target.startswith('linux'):
        command = ['readelf', '--dynamic', '--version-info', str(path)]
    else:
        command = ['dumpbin', '/NOLOGO', '/DEPENDENTS', str(path)]
    try:
        output = checked_output(command, limit=4*1024*1024, timeout=30)
    except (OSError, subprocess.SubprocessError):
        raise Refused('Native static import inspection is required; use the native build environment.') from None
    text = output.decode('utf-8', errors='replace')
    if target.startswith('linux'):
        needed = sorted(set(re.findall(r'\(NEEDED\).*?\[([A-Za-z0-9_.+-]+)\]', text)))
        versions = sorted(set(re.findall(r'\bGLIBC_([0-9]+\.[0-9]+(?:\.[0-9]+)?)\b', text)),
                          key=lambda value: tuple(map(int, value.split('.'))))
        if any(tuple(map(int, version.split('.'))) > (2, 39) for version in versions):
            raise Refused('A binary requires a glibc newer than Ubuntu 24.04.')
        return {'needed': needed, 'glibcVersions': versions,
                'note': 'Static imports omit dynamically loaded graphics/platform libraries.'}
    imports = sorted(set(value.lower() for value in re.findall(r'^\s+([A-Za-z0-9_.+-]+\.dll)\s*$', text, re.MULTILINE | re.IGNORECASE)))
    if not imports:
        raise Refused('Expected a Windows static DLL import inventory.')
    return {'imports': imports, 'note': 'Windows system DLLs and dynamically loaded modules are not bundled.'}


def archive_name(name):
    value = PurePosixPath(name)
    if (not name or '\\' in name or '\0' in name or '\r' in name or '\n' in name
            or value.is_absolute() or any(part in {'', '.', '..'} for part in name.split('/'))
            or any(':' in part for part in value.parts)):
        raise Refused('Unsafe archive member name.')
    return name


def put(directory, name, data, mode=0o644, *, owner=None):
    archive_name(name)
    path = directory / name
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open('xb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    path.chmod(mode)
    if owner is not None:
        owner.remember(path)


def regular_tree(root):
    root = safe(root, directory=True)
    result = []
    for path in root.rglob('*'):
        safe(path, directory=path.is_dir())
        if path.is_file():
            result.append((archive_name(path.relative_to(root).as_posix()), path))
    return sorted(result)


def notice_snapshot(directory):
    return {name: bounded(path) for name, path in regular_tree(directory)}


def verify_notices(directory, snapshot=None):
    snapshot = notice_snapshot(directory) if snapshot is None else snapshot
    if len(snapshot.get('INDEX.json', b'')) > 4 * 1024 * 1024:
        raise Refused('The dependency notice index exceeds its size limit.')
    index = strict_json(snapshot.get('INDEX.json', b''))
    if (not isinstance(index, dict) or set(index) != {'version', 'cargoLockSha256', 'goSumSha256', 'files', 'packages'}
            or index['version'] != 1 or not isinstance(index['files'], dict)
            or not isinstance(index['packages'], list) or not index['packages']
            or index['cargoLockSha256'] != sha(bounded(ROOT / 'prototypes/gpui/Cargo.lock'))
            or index['goSumSha256'] != sha(bounded(ROOT / 'helper/go.sum'))):
        raise Refused('Current dependency notices and lock provenance are required.')
    actual = {name: sha(data) for name, data in snapshot.items() if name != 'INDEX.json'}
    if actual != index['files'] or not actual:
        raise Refused('Missing, changed or unexpected dependency notice content.')
    locked = tomllib.loads(bounded(ROOT / 'prototypes/gpui/Cargo.lock').decode('utf-8'))
    required_rust = {(value['name'], value['version']) for value in locked['package'] if value['name'] != 'dbeer-gpui'}
    recorded_rust = {(value['name'], value['version']) for value in index['packages'] if value['ecosystem'] == 'rust'}
    required_go = set(re.findall(r'^\s*([\w./-]+)\s+(v[^\s]+)', bounded(ROOT / 'helper/go.mod').decode(), re.MULTILINE))
    recorded_go = {(value['name'], value['version']) for value in index['packages'] if value['ecosystem'] == 'go'}
    if required_rust != recorded_rust or not required_go.issubset(recorded_go):
        raise Refused('The dependency notice inventory is incomplete or stale.')
    expected_notices, identities = set(), set()
    for value in index['packages']:
        if (not isinstance(value, dict) or set(value) != {'ecosystem', 'name', 'version', 'license', 'upstream', 'notices'}
            or value['ecosystem'] not in {'rust', 'go', 'runtime'} or not isinstance(value['notices'], list)):
            raise Refused('Invalid dependency notice inventory.')
        identity = (value['ecosystem'], value['name'], value['version'])
        if identity in identities:
            raise Refused('Duplicate dependency notice identity.')
        identities.add(identity)
        key = value['ecosystem']+'/'+value['name'].replace('/', '_')+'-'+value['version']+'/'
        if not value['notices'] or any(key+archive_name(name) not in actual for name in value['notices']):
            raise Refused('A dependency lacks its original collected notices.')
        for name in value['notices']:
            runtime_license = (value['ecosystem'] == 'runtime' and PurePosixPath(name).parent.as_posix() == 'licenses'
                               and re.fullmatch(r'[A-Za-z0-9_.+-]+\.txt', PurePosixPath(name).name))
            if not runtime_license and not re.match(r'(?i)^(license|licence|notice|copying|copyright|patents|unlicense|ofl)([._-]|$)', PurePosixPath(name).name):
                raise Refused('Unexpected dependency notice content.')
            expected_notices.add(key+name)
    if expected_notices != set(actual):
        raise Refused('Unowned files cannot enter the dependency notice bundle.')
    if {value['name'] for value in index['packages'] if value['ecosystem'] == 'runtime'} != {'go-standard-library', 'rust-standard-library'}:
        raise Refused('Original Go and Rust standard-library runtime notices are required.')
    return index


def package(args):
    native(args.target)
    identity = canonical_identity(bounded(args.identity, 4096), args.target)
    if identity != new_identity(args.target):
        raise Refused('Metadata is stale or does not match current shared sources.')
    gui, helper = safe(args.gui), safe(args.helper)
    if gui == helper or gui.samefile(helper):
        raise Refused('GUI and helper must be distinct exact inputs.')
    gui_bytes, helper_bytes = binary_header(gui, args.target), binary_header(helper, args.target)
    marker = json_bytes(identity).strip()
    if marker not in gui_bytes or marker not in helper_bytes:
        # A previous binary may ignore --build-info and start a real workspace.
        # Never launch it speculatively. Both native build hooks must retain the
        # exact canonical embedded JSON before this bounded mode can be invoked.
        raise Refused('Both inputs must embed the expected canonical product identity.')
    resource_files = None
    if args.target.startswith('windows'):
        spec = importlib.util.spec_from_file_location('dbeer_candidate_resources',
                                                     Path(__file__).parent / 'native-resources/generate.py')
        resources = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(resources)
        resource_files = resources.render_resources(json_bytes(identity))
        resources.verify_native_pe(gui, 'gui', resource_files)
    reported_build(gui, 'gui', identity)
    reported_build(helper, 'helper', identity)
    dependencies = {'gui': native_dependencies(gui, args.target),
                    'helper': native_dependencies(helper, args.target)}
    # Reject an input changed between reading and its metadata report.
    if sha(bounded(gui, 512*1024*1024)) != sha(gui_bytes) or sha(bounded(helper, 512*1024*1024)) != sha(helper_bytes):
        raise Refused('A native input changed during validation.')
    notices = safe(args.notices, directory=True)
    notice_bytes = notice_snapshot(notices)
    verify_notices(notices, notice_bytes)
    output = safe(args.output or ROOT / 'build/gpui/candidates', directory=True, missing=True)
    if not output.is_relative_to(ROOT / 'build'):
        raise Refused('Candidate outputs belong under ignored build/.')
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    safe(output, directory=True)
    suffix = 'windows-x86_64' if args.target.startswith('windows') else 'linux-x86_64'
    name = f"DBeer-{identity['version']}-{identity['buildNumber']}-{suffix}"
    extension = '.zip' if args.target.startswith('windows') else '.tar.gz'
    destination = output / (name + '.candidate')
    if destination.exists() or destination.is_symlink():
        raise Refused('An existing candidate is never overwritten.')
    # One exclusive claim serializes same-name publishers; a stale claim refuses,
    # rather than authorizing deletion by age/PID. No existing archive is touched.
    claim = output / (name + '.claim')
    claim_fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    claim_identity = os.fstat(claim_fd)
    os.close(claim_fd)
    stage = Path(tempfile.mkdtemp(prefix='.dbeer-package-', dir=output))
    stage.chmod(0o700)
    stage_identity = stage.stat(follow_symlinks=False)
    owner = StageOwner(stage)
    try:
        content = stage / name
        content.mkdir(mode=0o700)
        owner.remember(content)
        provenance, source_bytes = source_snapshot(identity)
        def original(relative):
            try:
                return source_bytes[relative]
            except KeyError:
                raise Refused('A package payload lacks its exact source proof.') from None
        def stage_put(directory, name, data, mode=0o644):
            put(directory, name, data, mode, owner=owner)
        executable_suffix = '.exe' if args.target.startswith('windows') else ''
        stage_put(content, 'dbeer-gpui' + executable_suffix, gui_bytes, 0o755)
        stage_put(content, 'dbeer-core' + executable_suffix, helper_bytes, 0o755)
        stage_put(content, 'BUILD-IDENTITY.json', json_bytes(identity))
        stage_put(content, 'SOURCE-PROVENANCE.json', json_bytes(provenance))
        stage_put(content, 'NATIVE-DEPENDENCIES.json', json_bytes(dependencies))
        stage_put(content, 'VERSION', (identity['version'] + '\n').encode())
        stage_put(content, 'BUILD_NUMBER', (identity['buildNumber'] + '\n').encode())
        for relative in ['CHANGELOG.md']:
            stage_put(content, relative, original(relative))
        stage_put(content, 'INSTALL.md', original('prototypes/gpui/packaging/INSTALL.md'))
        stage_put(content, 'RUNTIME.md', original('prototypes/gpui/packaging/RUNTIME.md'))
        stage_put(content, 'NOTICES.md', original('prototypes/gpui/packaging/notices/NOTICES.md'))
        stage_put(content, f'icons/{APP_ID}.svg', original('macos/Resources/AppIcon.svg'))
        stage_put(content, f'icons/{APP_ID}.png', original('macos/Resources/AppIcon.png'))
        if args.target.startswith('linux'):
            stage_put(content, 'integrate-linux.py', original('prototypes/gpui/packaging/linux/integrate-linux.py'), 0o755)
        else:
            stage_put(content, 'WINDOWS-SIGNING.md', original('prototypes/gpui/packaging/windows/SIGNING.md'))
            stage_put(content, f'icons/{APP_ID}.ico', resource_files['dbeer.ico'])
            stage_put(content, 'NATIVE-RESOURCES.json', resource_files['NATIVE-RESOURCES.json'])
        for asset in THEMES:
            stage_put(content, 'themes/' + asset, original('prototypes/gpui/assets/themes/' + asset))
        for vendor in ['gpui-pre-linux', 'gpui-pre', 'gpui-component', 'gpui-base']:
            names = ['LICENSE-APACHE', 'README.md'] if vendor == 'gpui-pre-linux' else [
                'LICENSE-APACHE', 'DBEER-PATCH.md', 'UPSTREAM.sha256', 'LOCAL-CHANGES.json']
            if vendor == 'gpui-pre':
                names.append('README.md')
            elif vendor != 'gpui-pre-linux':
                names.append('.cargo_vcs_info.json')
            if vendor == 'gpui-component':
                names.append('LICENSE-LUCIDE')
            for filename in names:
                stage_put(content, f'notices/maintained/{vendor}/{filename}', original('prototypes/gpui/vendor/' + vendor + '/' + filename))
        upstream = 'prototypes/gpui/packaging/notices/upstream/'
        for relative, data in source_bytes.items():
            if relative.startswith(upstream):
                stage_put(content, 'notices/pinned-upstream/' + relative[len(upstream):], data)
        for relative, data in notice_bytes.items():
            stage_put(content, 'notices/dependencies/' + relative, data)
        verify_notices(content / 'notices/dependencies')
        manifest = {'schemaVersion': 1, 'productId': APP_ID, 'identity': identity,
                    'status': 'unsigned-development-candidate',
                    'files': {relative: {'sha256': sha(bounded(path, 512*1024*1024)),
                                         'size': path.stat().st_size,
                                         'executable': relative in {'dbeer-gpui'+executable_suffix, 'dbeer-core'+executable_suffix, 'integrate-linux.py'}}
                              for relative, path in regular_tree(content)}}
        stage_put(content, 'MANIFEST.json', json_bytes(manifest))
        archive = stage / (name + extension)
        write_archive(archive, content, name, args.target)
        archive.chmod(0o600)
        owner.remember(archive)
        checksum = sha(bounded(archive, 1024*1024*1024))
        stage_put(stage, archive.name + '.sha256', f'{checksum}  {archive.name}\n'.encode())
        stage_put(stage, 'BUILD-IDENTITY.json', json_bytes(identity))
        # Publish the archive/checksum/identity together as one new directory.
        # The same-name claim prevents cooperating publishers from racing rename.
        bundle = stage / 'bundle'
        bundle.mkdir(mode=0o700)
        owner.remember(bundle)
        for path in [archive, stage / (archive.name+'.sha256'), stage / 'BUILD-IDENTITY.json']:
            path.rename(bundle / path.name)
            owner.moved(path, bundle / path.name)
        if destination.exists() or destination.is_symlink():
            raise Refused('An existing candidate is never overwritten.')
        # Both direct wrappers and the paired driver must refuse BEFORE any
        # immutable candidate becomes visible. Stage bytes came only from the
        # verified snapshots; changed original legal inputs also refuse.
        if identity != new_identity(args.target) or notice_snapshot(notices) != notice_bytes:
            raise Refused('Source or dependency notices changed before candidate publication.')
        publish_directory(bundle, destination)
        owner.moved(bundle)
        if os.name != 'nt':
            descriptor = os.open(output, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        print('Prepared unsigned development candidate: ' + str(destination))
    finally:
        # mkdtemp is private and owned by this invocation. Never recurse into any
        # caller-provided input, pre-existing output or installed user directory.
        owned_cleanup(stage, stage_identity, owner.entries)
        if claim.exists() and not claim.is_symlink():
            now = claim.stat(follow_symlinks=False)
            if (now.st_dev, now.st_ino) == (claim_identity.st_dev, claim_identity.st_ino):
                claim.unlink()


def write_archive(archive, content, name, target):
    entries = regular_tree(content)
    executables = {'dbeer-gpui', 'dbeer-core', 'dbeer-gpui.exe', 'dbeer-core.exe', 'integrate-linux.py'}
    if target.startswith('windows'):
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
            for relative, path in entries:
                entry = zipfile.ZipInfo(archive_name(name+'/'+relative), (1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (0o100755 if relative in executables else 0o100644) << 16
                output.writestr(entry, bounded(path, 512*1024*1024), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    else:
        with archive.open('xb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as output:
                for relative, path in entries:
                    data = bounded(path, 512*1024*1024)
                    entry = tarfile.TarInfo(archive_name(name+'/'+relative))
                    entry.size, entry.mtime, entry.uid, entry.gid = len(data), 0, 0, 0
                    entry.uname = entry.gname = ''
                    entry.mode = 0o755 if relative in executables else 0o644
                    output.addfile(entry, io.BytesIO(data))


def pinned_rust_notices(value, source):
    """Original workspace texts pinned to this exact published crate, never SPDX substitutes."""
    directory = ROOT / 'prototypes/gpui/packaging/notices/upstream'
    catalog = strict_json(bounded(directory / 'INDEX.json', 2 * 1024 * 1024))
    if (not isinstance(catalog, dict) or catalog.get('schemaVersion') != 1
            or not isinstance(catalog.get('packages'), list)):
        raise Refused('Reviewed original upstream notice provenance is required.')
    candidates = [entry for entry in catalog['packages']
                  if entry.get('name') == value['name'] and entry.get('version') == value['version']]
    if len(candidates) != 1:
        raise Refused('This exact dependency lacks reviewed original upstream notices.')
    entry = candidates[0]
    locked = tomllib.loads(bounded(ROOT / 'prototypes/gpui/Cargo.lock').decode('utf-8'))
    packages = [package for package in locked['package']
                if (package['name'], package['version']) == (value['name'], value['version'])]
    manifest_data = bounded(source / 'Cargo.toml')
    vcs = source / '.cargo_vcs_info.json'
    vcs_data = bounded(vcs) if vcs.exists() else None
    vcs_hash = sha(vcs_data) if vcs_data is not None else None
    revision = entry.get('revision')
    if (len(packages) != 1 or not packages[0].get('checksum')
            or entry.get('archiveSha256') != packages[0]['checksum']
            or entry.get('manifestSha256') != sha(manifest_data)
            or entry.get('vcsInfoSha256') != vcs_hash
            or (revision is not None and (not isinstance(revision, str)
                                         or not re.fullmatch('[0-9a-f]{40}', revision)))
            or (vcs_data is not None and strict_json(vcs_data).get('git', {}).get('sha1') != revision)
            or not isinstance(entry.get('notices'), list) or not entry['notices']):
        raise Refused('Original upstream notices do not match the exact locked crate source.')
    files = []
    seen = set()
    for notice in entry['notices']:
        relative = archive_name(notice['path'])
        path = safe(directory / relative)
        if not path.is_relative_to(directory) or relative in seen:
            raise Refused('Invalid original upstream notice ownership.')
        seen.add(relative)
        name = PurePosixPath(relative).name
        if not re.match(r'(?i)^(license|licence|notice|copying|copyright|patents|unlicense|ofl)([._-]|$)', name):
            raise Refused('An upstream notice must retain its original legal filename.')
        data = bounded(path, 2 * 1024 * 1024)
        if (sha(data) != notice.get('sha256') or not isinstance(notice.get('upstreamUrl'), str)
                or not notice['upstreamUrl'].startswith('https://')):
            raise Refused('Original upstream legal bytes or provenance changed.')
        archive_url = ('https://static.crates.io/crates/' + value['name'] + '/'
                       + value['name'] + '-' + value['version'] + '.crate')
        publisher_manifest = (data == manifest_data and notice['upstreamUrl'] == archive_url)
        if not (revision and revision in notice['upstreamUrl']) and not publisher_manifest:
            linked = notice.get('linkedFrom')
            declared = notice.get('declaredBy')
            if isinstance(linked, dict) and not declared:
                # Retain the original project's explicit link together with its
                # primary terms. A merely inferred SPDX grant is insufficient.
                originals = [original for original in entry['notices']
                             if original.get('upstreamUrl') == linked.get('upstreamUrl')
                             and original.get('sha256') == linked.get('sha256')
                             and revision and revision in original.get('upstreamUrl', '')
                             and not original.get('linkedFrom') and not original.get('declaredBy')]
                if len(originals) != 1:
                    raise Refused('The original pinned notice for external terms is missing.')
                original = bounded(directory / archive_name(originals[0]['path']), 2 * 1024 * 1024)
                link = linked.get('linkUrl', notice['upstreamUrl'])
                if (sha(original) != linked['sha256'] or not isinstance(link, str)
                        or link not in html.unescape(original.decode('utf-8'))):
                    raise Refused('External terms were not explicitly linked by the original project.')
            elif isinstance(declared, dict) and not linked:
                # Cargo's publisher-owned license field explicitly references
                # SPDX terms. Keep its exact declaration and unmodified official
                # standard text; never insert authors/years or infer a license.
                originals = [original for original in entry['notices']
                             if original.get('path') == declared.get('path')
                             and original.get('sha256') == declared.get('sha256')
                             and original.get('upstreamUrl') == archive_url]
                expression = tomllib.loads(manifest_data.decode('utf-8')).get('package', {}).get('license')
                license_id = declared.get('licenseId')
                reference = declared.get('referenceUrl')
                if (len(originals) != 1 or declared.get('sha256') != sha(manifest_data)
                        or declared.get('licenseExpression') != expression or expression != value.get('license')
                        or not isinstance(expression, str) or not isinstance(license_id, str)
                        or license_id not in re.findall(r'[A-Za-z0-9][A-Za-z0-9.+-]*', expression)
                        or not isinstance(reference, str)
                        or not reference.startswith(('https://doc.rust-lang.org/cargo/', 'https://spdx.org/'))
                        or not re.fullmatch(r'https://raw\.githubusercontent\.com/spdx/license-list-data/'
                                            r'[0-9a-f]{40}/text/' + re.escape(license_id) + r'\.txt',
                                            notice['upstreamUrl'])):
                    raise Refused('Official terms do not match the original publisher SPDX declaration.')
                original = bounded(directory / archive_name(originals[0]['path']), 2 * 1024 * 1024)
                if original != manifest_data:
                    raise Refused('The preserved publisher license declaration changed.')
            else:
                raise Refused('External legal text needs an exact original project reference.')
        # Keep distinct original paths, even if a workspace repeats a basename.
        files.append(('upstream/' + relative, data))
    return entry, files


def collect_notices(args):
    cargo = strict_json(bounded(args.cargo_metadata, 32*1024*1024))
    if not isinstance(cargo, dict) or not isinstance(cargo.get('packages'), list):
        raise Refused('Cargo metadata is required.')
    # go list -m -json all emits concatenated objects, not one JSON array.
    decoder = json.JSONDecoder()
    text = bounded(args.go_modules, 8*1024*1024).decode('utf-8')
    go = []
    while text.strip():
        value, offset = decoder.raw_decode(text.lstrip())
        go.append(value)
        text = text.lstrip()[offset:]
    destination = safe(args.output, directory=True, missing=True)
    if not destination.is_relative_to(ROOT / 'build'):
        raise Refused('Collected notice outputs belong under ignored build/.')
    if destination.exists():
        raise Refused('An existing notices directory is never overwritten.')
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    stage = Path(tempfile.mkdtemp(prefix='.dbeer-notices-', dir=destination.parent))
    stage_identity = stage.stat(follow_symlinks=False)
    owner = StageOwner(stage)
    packages = []
    locked = tomllib.loads(bounded(ROOT / 'prototypes/gpui/Cargo.lock').decode('utf-8'))
    rust_lock = {(package['name'], package['version']): package for package in locked['package']}
    try:
        for ecosystem, values in [('rust', cargo['packages']), ('go', go)]:
            for value in values:
                if ecosystem == 'rust':
                    manifest = safe(value['manifest_path'])
                    if manifest == ROOT / 'prototypes/gpui/Cargo.toml':
                        continue
                    source = manifest.parent
                    name, version = value['name'], value['version']
                    license_expression = value.get('license')
                    package_lock = rust_lock.get((name, version), {})
                    upstream = {'repository': value.get('repository'),
                                'sourceArchive': f'https://static.crates.io/crates/{name}/{name}-{version}.crate'}
                    if package_lock.get('checksum'):
                        upstream['archiveSha256'] = package_lock['checksum']
                    elif source == ROOT / 'prototypes/gpui/vendor' / name:
                        audit = source / 'LOCAL-CHANGES.json'
                        if audit.exists():
                            archive_hash = strict_json(bounded(audit))['archive_sha256']
                        else:
                            matches = re.findall(r'Archive SHA256: `([0-9a-f]{64})`',
                                                 bounded(source / 'README.md').decode('utf-8'))
                            if len(matches) != 1:
                                raise Refused('Maintained dependency original archive proof is missing.')
                            archive_hash = matches[0]
                        upstream.update({'originalArchiveSha256': archive_hash,
                                         'maintainedSourceNotices': 'notices/maintained/' + name})
                    else:
                        raise Refused('An unreviewed Cargo source cannot enter the dependency inventory.')
                else:
                    if value.get('Main'):
                        continue
                    if value.get('Replace'):
                        raise Refused('Unreviewed Go module replacement cannot be packaged.')
                    source = safe(value.get('Dir', ''), directory=True)
                    name, version = value['Path'], value['Version']
                    if any(not isinstance(value.get(field), str)
                           or not re.fullmatch(r'h1:[A-Za-z0-9+/]{43}=', value[field])
                           for field in ['Sum', 'GoModSum']):
                        raise Refused('Exact downloaded Go source and module checksums are required.')
                    license_expression = None
                    escaped = lambda text: ''.join('!' + char.lower() if char.isupper() else char for char in text)
                    upstream = {'module': value['Path'], 'sourceSum': value['Sum'], 'moduleSum': value['GoModSum'],
                                'sourceArchive': 'https://proxy.golang.org/' + escaped(name) + '/@v/' + escaped(version) + '.zip'}
                if not re.fullmatch(r'[A-Za-z0-9_./@+!~-]+', name) or not re.fullmatch(r'[A-Za-z0-9_.+!-]+', version):
                    raise Refused('Unsupported dependency identity.')
                key = ecosystem + '/' + name.replace('/', '_') + '-' + version
                notices = []
                for relative, path in regular_tree(source):
                    if re.match(r'(?i)^(license|licence|notice|copying|copyright|patents|unlicense|ofl)([._-]|$)', path.name):
                        put(stage, key + '/' + relative, bounded(path, 2*1024*1024))
                        notices.append(relative)
                if not notices:
                    if ecosystem != 'rust':
                        raise Refused('A dependency lacks collected original license/notice text.')
                    provenance, originals = pinned_rust_notices(value, source)
                    for relative, data in originals:
                        put(stage, key + '/' + relative, data)
                        notices.append(relative)
                    upstream['originalNoticeProvenance'] = provenance
                packages.append({'ecosystem': ecosystem, 'name': name, 'version': version,
                                 'license': license_expression, 'upstream': upstream, 'notices': notices})
        packages.extend(collect_runtime_notices(stage, getattr(args, 'environment', None)))
        index = {'version': 1, 'cargoLockSha256': sha(bounded(ROOT / 'prototypes/gpui/Cargo.lock')),
                 'goSumSha256': sha(bounded(ROOT / 'helper/go.sum')),
                 'packages': sorted(packages, key=lambda item: (item['ecosystem'], item['name'], item['version'])),
                 'files': {relative: sha(bounded(path)) for relative, path in regular_tree(stage)}}
        put(stage, 'INDEX.json', json_bytes(index))
        # No other collector may overwrite an existing destination; a conflicting
        # publication refuses. Destination is exclusively created then populated
        # by renaming the private stage only after a final absent check.
        if destination.exists() or destination.is_symlink():
            raise Refused('An existing notices directory is preserved.')
        publish_directory(stage, destination)
    finally:
        if stage.exists():
            owned_cleanup(stage, stage_identity)


def collect_runtime_notices(stage, environment):
    """Copy original installed standard-library license texts, never a guessed substitute."""
    rust = checked_output(['rustc', '-vV'], limit=8192, timeout=15, environment=environment).decode('ascii')
    releases = re.findall(r'^release: ([A-Za-z0-9_.+!-]+)$', rust, re.MULTILINE)
    if len(releases) != 1:
        raise Refused('The actual Rust runtime version is required.')
    sysroot = safe(Path(checked_output(['rustc', '--print', 'sysroot'], limit=32768, timeout=15,
                                      environment=environment).decode('utf-8').strip()), directory=True)
    go = strict_json(checked_output(['go', 'env', '-json', 'GOROOT', 'GOVERSION'], limit=32768,
                                    timeout=15, environment=environment))
    if not isinstance(go.get('GOVERSION'), str) or not re.fullmatch(r'go[A-Za-z0-9_.+!-]+', go['GOVERSION']):
        raise Refused('The actual Go runtime version is required.')
    go_root = safe(Path(go['GOROOT']), directory=True)
    rust_docs = sysroot / 'share/doc/rust'
    rust_files = [('COPYRIGHT-library.html', rust_docs / 'COPYRIGHT-library.html')]
    licenses = regular_tree(rust_docs / 'licenses')
    if not licenses:
        raise Refused('The installed Rust runtime original licenses are incomplete.')
    for relative, path in licenses:
        if '/' in relative or not re.fullmatch(r'[A-Za-z0-9_.+-]+\.txt', relative):
            raise Refused('Unexpected installed Rust runtime license material.')
        rust_files.append(('licenses/' + relative, path))
    groups = [('rust-standard-library', releases[0], 'Rust standard library at rustc ' + releases[0], rust_files),
              ('go-standard-library', go['GOVERSION'], 'Go standard library at ' + go['GOVERSION'],
               [('LICENSE', go_root / 'LICENSE'), ('PATENTS', go_root / 'PATENTS')])]
    packages = []
    for name, version, upstream, files in groups:
        key = 'runtime/' + name + '-' + version
        for relative, path in files:
            put(stage, key + '/' + relative, bounded(path, 4 * 1024 * 1024))
        packages.append({'ecosystem': 'runtime', 'name': name, 'version': version,
                         'license': None, 'upstream': upstream,
                         'notices': [relative for relative, _ in files]})
    return packages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    identity = commands.add_parser('identity')
    identity.add_argument('--target', choices=TARGETS, required=True)
    identity.add_argument('--output', type=Path, required=True)
    notices = commands.add_parser('collect-notices')
    notices.add_argument('--cargo-metadata', type=Path, required=True)
    notices.add_argument('--go-modules', type=Path, required=True)
    notices.add_argument('--output', type=Path, required=True)
    verify_identity = commands.add_parser('verify-identity')
    verify_identity.add_argument('--target', choices=TARGETS, required=True)
    verify_identity.add_argument('--identity', type=Path, required=True)
    candidate = commands.add_parser('package')
    candidate.add_argument('--target', choices=TARGETS, required=True)
    for argument in ['gui', 'helper', 'identity', 'notices']:
        candidate.add_argument('--'+argument, type=Path, required=True)
    candidate.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.command == 'identity':
        native(args.target)
        identity = new_identity(args.target)
        path = safe(args.output, missing=True)
        if not path.is_relative_to(ROOT / 'build'):
            raise Refused('Build identity outputs belong under ignored build/.')
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with path.open('xb') as output:
            output.write(json_bytes(identity))
        path.chmod(0o600)
    elif args.command == 'verify-identity':
        native(args.target)
        if canonical_identity(bounded(args.identity, 4096), args.target) != new_identity(args.target):
            raise Refused('Build identity does not match the frozen native product sources.')
    elif args.command == 'collect-notices':
        collect_notices(args)
    else:
        package(args)


if __name__ == '__main__':
    try:
        main()
    except (Refused, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Never print native exceptions, environment values, SQL, user data or
        # credentials. Build inputs and invalid package payloads stay out of logs.
        print('DBeer packaging refused unsafe, stale, incomplete or mismatched inputs. Existing artifacts are preserved.', file=sys.stderr)
        sys.exit(2)
