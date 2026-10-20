"""Installed acceptance primitives. No operation adopts an existing process."""
from __future__ import annotations

import ctypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import queue
import re
import stat
import struct
import subprocess
import sys
import tarfile
import threading
import time
import zipfile

REPO = Path(__file__).resolve().parents[3]
OUTPUT = REPO / 'build/gpui/task32-runs'
TARGETS = {'windows11-x64': 'windows-x86_64-msvc',
           'ubuntu2404-x64-wayland': 'linux-x86_64-gnu',
           'ubuntu2404-x64-x11': 'linux-x86_64-gnu'}
APP_ID = 'app.dbeer.DBeer'
MAX_FILE = 512 * 1024 * 1024
MAX_TREE = 1024 * 1024 * 1024


class Refused(Exception):
    """A fixed, payload-free refusal suitable for evidence."""


class Pending(Refused):
    """Required native capability or authentic artifact is unavailable."""


def now():
    return datetime.now(timezone.utc).isoformat()


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def parse(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise Refused('Duplicate metadata field.')
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs)
    except (ValueError, UnicodeError, RecursionError):
        raise Refused('Invalid metadata.') from None


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def safe(path, directory=False):
    path = Path(os.path.abspath(path))
    for item in [*reversed(path.parents), path]:
        metadata = item.lstat()
        if stat.S_ISLNK(metadata.st_mode) or getattr(metadata, 'st_file_attributes', 0) & 0x400:
            raise Refused('Symlink or reparse input refused.')
        if item != path and not stat.S_ISDIR(metadata.st_mode):
            raise Refused('Non-directory ancestor refused.')
    if not (path.is_dir() if directory else path.is_file()):
        raise Refused('Unexpected file type.')
    return path


def read(path, limit=MAX_FILE):
    path = safe(path)
    with path.open('rb') as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise Refused('Input limit exceeded.')
    return data


def sha(path):
    return digest_bytes(read(path))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native = load_module('dbeer_installed_native', REPO / 'prototypes/gpui/native/run.py')


def private_directory(path):
    safe(path.parent, directory=True)
    path.mkdir(mode=0o700)
    if os.name == 'nt' and not native.windows_private(path, create=True):
        raise Refused('Private owner ACL unavailable.')
    native.private_path(path, directory=True)


def write_new(path, value):
    # No overwrite: an interrupted record is never a successful completion.
    safe(path.parent, directory=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(canonical(value))
        stream.flush()
        os.fsync(stream.fileno())


def archive_name(name):
    path = PurePosixPath(name)
    if (not name or '\\' in name or ':' in name or any(c in name for c in '\0\r\n')
            or path.is_absolute() or any(p in ('', '.', '..') for p in name.split('/'))
            or path.as_posix() != name or len(name) > 240):
        raise Refused('Unsafe archive path.')
    return name


def identity(value, target):
    keys = {'schemaVersion', 'productId', 'version', 'buildNumber', 'target', 'protocolVersion',
            'contractRevision', 'sourceSha256', 'capabilities'}
    if (not isinstance(value, dict) or set(value) != keys or type(value['schemaVersion']) is not int
            or value['schemaVersion'] != 1 or value['productId'] != APP_ID
            or value['target'] != target or type(value['protocolVersion']) is not int
            or value['protocolVersion'] != 3 or value['contractRevision'] != 'gpui-v3-captured-export-v1'
            or value['capabilities'] != ['capturedExportV1']
            or not isinstance(value['sourceSha256'], str) or not re.fullmatch('[0-9a-f]{64}', value['sourceSha256'])
            or not isinstance(value['version'], str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value['version'])
            or not isinstance(value['buildNumber'], str) or not re.fullmatch('[1-9][0-9]*', value['buildNumber'])):
        raise Refused('Unsupported build identity.')
    return value


def binary(data, target):
    if target.startswith('linux'):
        good = len(data) >= 64 and data[:6] == b'\x7fELF\x02\x01' and data[18:20] == b'\x3e\0'
    else:
        offset = struct.unpack_from('<I', data, 60)[0] if len(data) >= 64 else len(data)
        good = (data[:2] == b'MZ' and offset + 26 <= len(data)
                and data[offset:offset + 6] == b'PE\0\0\x64\x86'
                and data[offset + 24:offset + 26] == b'\x0b\x02')
    if not good:
        raise Refused('Native x64 executable header mismatch.')


class Artifact:
    """Read/verify the complete archive before any member can execute."""
    def __init__(self, descriptor, desktop):
        if set(descriptor) != {'archive', 'checksumFile', 'archiveSha256', 'identitySha256', 'manifestSha256', 'provenance'}:
            raise Refused('Artifact descriptor fields mismatch.')
        if descriptor['provenance'] not in ('trusted-prior-artifact', 'trusted-candidate-artifact'):
            raise Pending('Explicit trusted artifact provenance is required.')
        for key in ('archiveSha256', 'identitySha256', 'manifestSha256'):
            if not isinstance(descriptor[key], str) or not re.fullmatch('[0-9a-f]{64}', descriptor[key]):
                raise Refused('An explicit artifact digest is required.')
        self.path = safe(descriptor['archive'])
        self.digest = sha(self.path)
        if self.digest != descriptor['archiveSha256']:
            raise Refused('Archive digest mismatch.')
        checksum = read(descriptor['checksumFile'], 1024).decode('ascii')
        if checksum != self.digest + '  ' + self.path.name + '\n':
            raise Refused('Distributed SHA256 sidecar mismatch.')
        self.members = {}
        total = 0
        if self.path.suffix == '.zip':
            with zipfile.ZipFile(self.path) as archive:
                for entry in archive.infolist():
                    mode = entry.external_attr >> 16
                    if entry.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG) or entry.flag_bits & 1:
                        raise Refused('Unsupported ZIP member.')
                    total = self._put(entry.filename, entry.file_size, total, lambda: archive.read(entry))
        elif self.path.name.endswith('.tar.gz'):
            with tarfile.open(self.path, 'r:gz') as archive:
                for entry in archive:
                    if (not entry.isfile() or entry.issym() or entry.islnk()
                            or set(entry.pax_headers) - {'path'}
                            or entry.pax_headers.get('path', entry.name) != entry.name):
                        raise Refused('Unsupported tar member.')
                    total = self._put(entry.name, entry.size, total, lambda: archive.extractfile(entry).read(MAX_FILE + 1))
        else:
            raise Refused('Unsupported archive format.')
        prefixes = {name.split('/')[0] for name in self.members}
        if len(prefixes) != 1 or any('/' not in name for name in self.members):
            raise Refused('Package must contain exactly one complete product folder.')
        self.archive_root = next(iter(prefixes))
        self.members = {name.split('/', 1)[1]: data for name, data in self.members.items()}
        try:
            metadata = self.members['BUILD-IDENTITY.json']
            manifest_data = self.members['MANIFEST.json']
        except KeyError:
            raise Pending('Unmarked legacy artifact needs a reviewed provenance contract.') from None
        if len(metadata) > 4096 or len(manifest_data) > 16 * 1024 * 1024:
            raise Refused('Embedded metadata size limit exceeded.')
        if digest_bytes(metadata) != descriptor['identitySha256'] or digest_bytes(manifest_data) != descriptor['manifestSha256']:
            raise Refused('Pinned embedded metadata mismatch.')
        self.identity = identity(parse(metadata), TARGETS[desktop])
        suffix = 'windows-x86_64' if desktop == 'windows11-x64' else 'linux-x86_64'
        expected_root = 'DBeer-' + self.identity['version'] + '-' + self.identity['buildNumber'] + '-' + suffix
        if self.archive_root != expected_root:
            raise Refused('Package folder/build identity mismatch.')
        if metadata != canonical(self.identity):
            raise Refused('Build identity must be canonical.')
        manifest = parse(manifest_data)
        if (not isinstance(manifest, dict) or set(manifest) != {'schemaVersion', 'productId', 'identity', 'status', 'files'}
                or type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1 or manifest['productId'] != APP_ID
                or manifest['identity'] != self.identity or manifest['status'] != 'unsigned-development-candidate'
                or not isinstance(manifest['files'], dict)
                or set(manifest['files']) != set(self.members) - {'MANIFEST.json'}):
            raise Refused('Archive manifest mismatch.')
        self.files = manifest['files']
        for name, record in self.files.items():
            data = self.members[name]
            if (not isinstance(record, dict) or set(record) != {'sha256', 'size', 'executable'}
                    or type(record['size']) is not int or record['size'] != len(data)
                    or type(record['executable']) is not bool or record['sha256'] != digest_bytes(data)):
                raise Refused('Archive member digest or shape mismatch.')
        suffix = '.exe' if desktop == 'windows11-x64' else ''
        self.gui_name, self.helper_name = 'dbeer-gpui' + suffix, 'dbeer-core' + suffix
        for name in (self.gui_name, self.helper_name):
            if name not in self.members or not self.files[name]['executable']:
                raise Refused('Exact executable missing.')
            binary(self.members[name], TARGETS[desktop])
            if canonical(self.identity).strip() not in self.members[name]:
                raise Pending('Exact canonical build identity is not embedded.')
        self.staged = None

    def _put(self, name, size, total, reader):
        name = archive_name(name)
        # Refuse case-insensitive aliases even on Linux; these bytes install on Windows.
        if name.casefold() in {n.casefold() for n in self.members} or len(self.members) >= 10000:
            raise Refused('Duplicate archive member.')
        if size < 0 or size > MAX_FILE or total + size > MAX_TREE:
            raise Refused('Archive size bound exceeded.')
        data = reader()
        if len(data) != size:
            raise Refused('Archive length mismatch.')
        self.members[name] = data
        return total + size

    def stage(self, destination):
        private_directory(destination)
        for name, data in self.members.items():
            path = destination / name
            for parent in reversed(path.parents):
                if parent == destination or destination in parent.parents:
                    if not parent.exists():
                        private_directory(parent)
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700 if self.files.get(name, {}).get('executable') else 0o600)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        self.staged = safe(destination, directory=True)
        self.verify()

    def verify(self):
        if self.staged is None:
            raise Refused('Artifact is not staged.')
        safe(self.staged, directory=True)
        actual, directories = set(), set()
        for path in self.staged.rglob('*'):
            safe(path, directory=path.is_dir())
            (directories if path.is_dir() else actual).add(path.relative_to(self.staged).as_posix())
        expected_directories = {parent.as_posix() for name in self.members for parent in PurePosixPath(name).parents if parent.as_posix() != '.'}
        if actual != set(self.members) or directories != expected_directories:
            raise Refused('Installed tree contains unexpected or missing content.')
        for name, data in self.members.items():
            if sha(self.staged / name) != digest_bytes(data):
                raise Refused('Installed bytes changed.')

    @property
    def gui(self):
        return self.staged / self.gui_name

    @property
    def helper(self):
        return self.staged / self.helper_name

    def proof(self):
        return {'archiveSha256': self.digest, 'identity': self.identity,
                'manifestSha256': digest_bytes(self.members['MANIFEST.json']),
                'guiSha256': self.files[self.gui_name]['sha256'], 'helperSha256': self.files[self.helper_name]['sha256']}

    def require_reviewed_source(self, pins):
        """Join trusted exact archive/binary identity to reviewed current source.

        This is the trusted paired builder's provenance, not a cryptographic
        compiler attestation. An old or unavailable source tree remains pending.
        The packager's pure source inventory/digest is reused without building,
        executing, signing, installing or publishing any application.
        """
        self.verify()
        if 'SOURCE-PROVENANCE.json' not in self.members:
            raise Pending('Trusted exact paired source provenance is required for the physical Apply fault.')
        provenance = parse(self.members['SOURCE-PROVENANCE.json'])
        if (not isinstance(provenance, dict) or set(provenance) != {'schemaVersion', 'identity', 'digestAlgorithm', 'files'}
                or provenance.get('identity') != self.identity or type(provenance.get('schemaVersion')) is not int
                or provenance['schemaVersion'] != 1 or not isinstance(provenance.get('files'), dict)):
            raise Refused('Exact paired artifact source provenance schema differs.')
        for relative, expected in pins.items():
            if provenance['files'].get(relative, {}).get('sha256') != expected:
                raise Refused('The packaged helper lacks the reviewed sequential Apply source pin.')
        package_path = REPO / 'prototypes/gpui/packaging/package.py'
        before = sha(package_path)
        package = load_module('dbeer_acceptance_source_provenance', package_path)
        try:
            actual = package.source_provenance(self.identity)
        except Exception:
            raise Pending('The exact candidate source inventory is unavailable or changed.') from None
        if sha(package_path) != before or canonical(actual) != canonical(provenance):
            raise Refused('Trusted paired source provenance differs from the complete current reviewed source.')
        return {'pairedSourceSha256': self.identity['sourceSha256'],
                'provenanceSha256': digest_bytes(self.members['SOURCE-PROVENANCE.json']),
                'reviewedAdapterPinsSha256': digest_bytes(canonical(pins)), 'trustedBuilderProvenance': True}

    def require_verification_source(self):
        """Bind the actual Task30 inventory to exact current candidate files.

        Package and verification digests use different reviewed algorithms.
        Joining each named raw-byte file proof avoids comparing those hashes.
        All platform branches and Mac regression sources belong to one shared
        contract, so platform-specific execution never changes the inventory.
        """
        self.require_reviewed_source({})
        provenance = parse(self.members['SOURCE-PROVENANCE.json'])
        source = load_module('dbeer_installed_verification_source', REPO / 'prototypes/gpui/verification/source_contract.py')
        try:
            expected = source.capture(REPO)
        except (OSError, ValueError):
            raise Pending('The reviewed cross-platform verification sources are unavailable.') from None
        if any(provenance['files'].get(name) != row for name, row in expected['files'].items()):
            raise Refused('Candidate provenance does not contain the exact reviewed Task30 input inventory.')
        return expected


def clean_environment(root, desktop):
    # Preserve real DBus/Wayland/X11/GPU authorization. Never replace HOME/runtime/bus.
    blocked = ('DBEER_', 'PG', 'MYSQL', 'LD_', 'DYLD_', 'PYTHON', 'GODEBUG', 'RUST_LOG')
    env = {k: v for k, v in os.environ.items() if not k.startswith(blocked)}
    for item in ('data', 'config', 'state', 'cache', 'temp'):
        private_directory(root / item)
    if desktop == 'windows11-x64':
        env.update(LOCALAPPDATA=str(root / 'data'), APPDATA=str(root / 'config'), TEMP=str(root / 'temp'), TMP=str(root / 'temp'))
    else:
        env.update(XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
                   XDG_STATE_HOME=str(root / 'state'), XDG_CACHE_HOME=str(root / 'cache'), TMPDIR=str(root / 'temp'))
    return env


def process_start(process):
    if process.poll() is not None:
        raise Refused('Owned child exited.')
    if os.name != 'nt':
        data = Path('/proc', str(process.pid), 'stat').read_text()
        return data[data.rfind(')') + 2:].split()[19]
    class FileTime(ctypes.Structure):
        _fields_ = [('low', ctypes.c_uint32), ('high', ctypes.c_uint32)]
    times = [FileTime() for _ in range(4)]
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetProcessTimes.argtypes = [ctypes.c_void_p, *([ctypes.POINTER(FileTime)] * 4)]
    if not kernel.GetProcessTimes(ctypes.c_void_p(int(process._handle)), *(ctypes.byref(t) for t in times)):
        raise Refused('Owned child start time unavailable.')
    return str((times[0].high << 32) | times[0].low)


class Child:
    def __init__(self, executable, expected_hash, env, args=(), pipe=False):
        self.executable = safe(executable)
        self.expected_hash = expected_hash
        if sha(self.executable) != expected_hash:
            raise Refused('Owned child bytes mismatch.')
        self.process = subprocess.Popen([str(self.executable), *args], env=env,
                                        stdin=subprocess.PIPE if pipe else subprocess.DEVNULL,
                                        stdout=subprocess.PIPE if pipe else subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
        self.start = process_start(self.process)
        self.verify()

    def verify(self):
        if self.process.poll() is not None or process_start(self.process) != self.start:
            raise Refused('Owned process lifetime changed.')
        if native.process_image(self.process) != self.executable or sha(self.executable) != self.expected_hash:
            raise Refused('Owned process image changed.')

    def identity(self):
        self.verify()
        return {'pid': self.process.pid, 'startTime': self.start, 'executable': str(self.executable), 'sha256': self.expected_hash}

    def stop(self):
        # Popen owns exactly this lifetime; no discovery, PID reattachment or groups.
        if self.process.poll() is None:
            self.verify()
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.verify()
                self.process.kill()
                self.process.wait(timeout=5)
        return self.process.returncode


def bounded_call(command, env, payload=None, limit=65536, timeout=10):
    process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE if payload is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    result = queue.Queue(maxsize=1)
    def read_output():
        result.put(process.stdout.read(limit + 1))
    worker = threading.Thread(target=read_output, daemon=True)
    worker.start()
    try:
        if payload is not None:
            if len(payload) > 65536:
                raise Refused('Bounded child input exceeded.')
            def write_input():
                try:
                    process.stdin.write(payload)
                    process.stdin.close()
                except (OSError, ValueError):
                    pass
            threading.Thread(target=write_input, daemon=True).start()
        data = result.get(timeout=timeout)
        if len(data) > limit:
            raise Refused('Bounded child output exceeded.')
        code = process.wait(timeout=timeout)
        if code:
            raise Refused('Bounded native adapter refused.')
        return data
    except (queue.Empty, subprocess.TimeoutExpired):
        raise Refused('Bounded native adapter timed out.') from None
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


def verify_build_info(artifact, env):
    artifact.verify()
    for component, executable in (('gui', artifact.gui), ('helper', artifact.helper)):
        # Embedded identity was already checked without executing either image.
        output = bounded_call([str(executable), '--build-info'], env, limit=4096)
        if parse(output) != {'component': component, 'identity': artifact.identity}:
            raise Refused('Executed build metadata mismatch.')
    artifact.verify()


class Journal:
    def __init__(self, root, nonce):
        self.root, self.nonce, self.sequence = root, nonce, 0

    def append(self, event, **metadata):
        if not re.fullmatch('[a-z][a-z0-9-]{0,63}', event):
            raise Refused('Unsupported journal event.')
        self.sequence += 1
        write_new(self.root / ('journal-%05d.json' % self.sequence),
                  {'schemaVersion': 1, 'runNonce': self.nonce, 'at': now(), 'event': event, **metadata})


def state_snapshot(data_root):
    """Only hashes/shape leave the isolated root; no source/result/secret is emitted."""
    safe(data_root, directory=True)
    files = {}
    for path in sorted(data_root.rglob('*')):
        safe(path, directory=path.is_dir())
        if path.is_file() and path.name != '.workspace.lock':
            name = path.relative_to(data_root).as_posix()
            files[name] = {'sha256': sha(path), 'size': path.stat().st_size}
    return {'files': files, 'treeSha256': digest_bytes(canonical(files))}
