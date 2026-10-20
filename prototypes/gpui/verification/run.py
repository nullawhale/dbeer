#!/usr/bin/env python3
"""Additive final-integration proof collector; never modifies parity acceptance."""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import tarfile
import threading
import uuid

from assertion_coverage import behavior_evidence, validate_coverage
from dependency_inputs import lock_packages, verify_dependency_review
import source_contract
from macos_coverage import coverage as macos_coverage

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUTPUT = REPO / 'build/gpui/task30-runs'
MAX_LINE = 1024 * 1024
SUMMARY = re.compile(r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; (\d+) filtered out;')
SWIFT = re.compile(r'Test run with ([1-9][0-9]*) tests? .*passed after')
TEST = re.compile(r'^test ([a-zA-Z0-9_:]+) \.\.\. (ok|FAILED|ignored(?:,.*)?)$')
NATIVE_OWNERSHIP = None


def ownership_module():
    global NATIVE_OWNERSHIP
    if NATIVE_OWNERSHIP is None:
        spec = importlib.util.spec_from_file_location('dbeer_native_ownership', REPO / 'prototypes/gpui/native/run.py')
        NATIVE_OWNERSHIP = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(NATIVE_OWNERSHIP)
    return NATIVE_OWNERSHIP


def now():
    return datetime.now(timezone.utc).isoformat()


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def strict_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON key.')
            result[key] = value
        return result
    return json.loads(Path(path).read_text(encoding='utf-8'), object_pairs_hook=pairs)


def write_json(path, value):
    # Atomically publish a new complete record; never overwrite prior evidence.
    data = (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()
    descriptor, temporary = tempfile.mkstemp(prefix='.' + Path(path).name + '.', dir=Path(path).parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        verify_private(Path(temporary), directory=False)
        os.link(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    if os.name != 'nt':
        directory = os.open(Path(path).parent, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


def verify_private(path, directory=True):
    metadata = path.lstat()
    regular = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not regular or getattr(metadata, 'st_file_attributes', 0) & 0x400:
        raise ValueError('Owned path is not a regular private path.')
    if os.name == 'nt':
        if not ownership_module().windows_private(path):
            raise ValueError('Owned path lacks its current-user private DACL.')
        if directory:
            advapi = ctypes.WinDLL('advapi32', use_last_error=True)
            pointer, dword = ctypes.c_void_p, ctypes.c_uint32
            advapi.GetFileSecurityW.argtypes = [ctypes.c_wchar_p, dword, pointer, dword, ctypes.POINTER(dword)]
            advapi.GetSecurityDescriptorControl.argtypes = [pointer, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(dword)]
            size, revision, control = dword(), dword(), ctypes.c_ushort()
            advapi.GetFileSecurityW(str(path), 4, None, 0, ctypes.byref(size))
            descriptor = ctypes.create_string_buffer(size.value)
            if (not advapi.GetFileSecurityW(str(path), 4, descriptor, size, ctypes.byref(size))
                    or not advapi.GetSecurityDescriptorControl(descriptor, ctypes.byref(control), ctypes.byref(revision))
                    or not control.value & 0x1000):
                raise ValueError('Owned directory DACL must be protected from inheritance.')
    elif metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        raise ValueError('Owned path is not private to the current user.')
    return (metadata.st_dev, metadata.st_ino)


def windows_create_private_directory(path):
    # Set owner and protected inheritable DACL AT creation, before any fixture
    # bytes exist. DataDirectory's Unix mode is not Windows ACL evidence.
    pointer, dword = ctypes.c_void_p, ctypes.c_uint32
    advapi = ctypes.WinDLL('advapi32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    advapi.OpenProcessToken.argtypes = [pointer, dword, ctypes.POINTER(pointer)]
    advapi.GetTokenInformation.argtypes = [pointer, dword, pointer, dword, ctypes.POINTER(dword)]
    advapi.ConvertSidToStringSidW.argtypes = [pointer, ctypes.POINTER(pointer)]
    advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [ctypes.c_wchar_p, dword, ctypes.POINTER(pointer), ctypes.POINTER(dword)]
    kernel.CloseHandle.argtypes = [pointer]
    kernel.LocalFree.argtypes = [pointer]
    class SecurityAttributes(ctypes.Structure):
        _fields_ = [('length', dword), ('descriptor', pointer), ('inherit', ctypes.c_int)]
    kernel.CreateDirectoryW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(SecurityAttributes)]
    token, sid_text, descriptor = pointer(), pointer(), pointer()
    try:
        if not advapi.OpenProcessToken(pointer(-1), 8, ctypes.byref(token)):
            raise ValueError('Cannot obtain private directory ownership.')
        size = dword()
        advapi.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
        user = ctypes.create_string_buffer(size.value)
        if not advapi.GetTokenInformation(token, 1, user, size, ctypes.byref(size)):
            raise ValueError('Cannot obtain private directory ownership.')
        sid = ctypes.cast(user, ctypes.POINTER(pointer))[0]
        if not advapi.ConvertSidToStringSidW(sid, ctypes.byref(sid_text)):
            raise ValueError('Cannot obtain private directory ownership.')
        owner = ctypes.wstring_at(sid_text)
        sddl = 'O:' + owner + 'D:P(A;OICI;FA;;;' + owner + ')'
        if not advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, ctypes.byref(descriptor), None):
            raise ValueError('Cannot construct private directory DACL.')
        attributes = SecurityAttributes(ctypes.sizeof(SecurityAttributes), descriptor, False)
        if not kernel.CreateDirectoryW(str(path), ctypes.byref(attributes)):
            raise ValueError('Cannot reserve private directory.')
    finally:
        if descriptor: kernel.LocalFree(descriptor)
        if sid_text: kernel.LocalFree(sid_text)
        if token: kernel.CloseHandle(token)


def private_directory(path):
    path = Path(path)
    if not path.is_absolute() or not path.is_relative_to(REPO / 'build'):
        raise ValueError('Private fixture directories belong only inside the ignored build tree.')
    if any(p.is_symlink() or (p.exists() and getattr(p.lstat(), 'st_file_attributes', 0) & 0x400)
           for p in [path, *path.parents] if p != REPO.parent and REPO in (p, *p.parents)):
        raise ValueError('Symlinked private run ancestors are refused.')
    if os.name == 'nt':
        windows_create_private_directory(path)
    else:
        path.mkdir(mode=0o700)
    verify_private(path)


def executable_identity(path, expected=None):
    path = Path(path)
    if not path.is_absolute() or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('Executable must have an absolute unsymlinked path.')
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or getattr(before, 'st_file_attributes', 0) & 0x400:
        raise ValueError('Executable must be a regular native file.')
    with path.open('rb') as stream:
        header = stream.read(1024 * 1024)
        descriptor = os.fstat(stream.fileno())
    if (descriptor.st_dev, descriptor.st_ino) != (before.st_dev, before.st_ino):
        raise ValueError('Executable identity changed while opening.')
    if os.name == 'nt':
        offset = struct.unpack_from('<I', header, 60)[0] if len(header) >= 64 else len(header)
        native = header[:2] == b'MZ' and header[offset:offset + 6] == b'PE\0\0\x64\x86' and header[offset + 24:offset + 26] == b'\x0b\x02'
    else:
        native = header[:6] == b'\x7fELF\x02\x01' and header[18:20] == b'\x3e\x00' and os.access(path, os.X_OK)
    if not native:
        raise ValueError('Executable is not the actual host native x64 format.')
    value = {'path': str(path), 'sha256': sha(path), 'device': before.st_dev, 'inode': before.st_ino,
             'size': before.st_size, 'modifiedNs': before.st_mtime_ns}
    after = path.lstat()
    if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) or (expected and value != expected):
        raise ValueError('Executable bytes or file identity changed.')
    return value


def verify_fixture_environment(env):
    root = Path(env.get('DBEER_GPUI_TEST_ROOT', ''))
    if not root.is_absolute() or not root.is_relative_to(REPO / 'build') or root.resolve() != root:
        raise ValueError('Fault test root must be an absolute private build directory.')
    verify_private(root)
    digest = env.get('DBEER_GPUI_FAULT_HELPER_SHA256', '')
    peer = executable_identity(env.get('DBEER_GPUI_FAULT_HELPER_PATH', ''))
    helper = executable_identity(env.get('DBEER_GPUI_HELPER_PATH', ''))
    if not re.fullmatch('[0-9a-f]{64}', digest) or peer['sha256'] != digest:
        raise ValueError('The exact native portable peer hash is required.')
    if helper['sha256'] != env.get('DBEER_GPUI_TEST_HELPER_SHA256'):
        raise ValueError('The exact development helper hash is required.')
    return {'rootIdentity': list(verify_private(root)), 'peer': peer, 'helper': helper}


def source_identity():
    return source_contract.capture(REPO)['sourceSha256']


def clean_environment(root):
    # Inherited production DSNs, app overrides, fixtures and store overrides are
    # never accepted. Desktop auth variables are retained for owned native hooks.
    removed = {'PGHOST', 'PGHOSTADDR', 'PGPORT', 'PGDATABASE', 'PGUSER', 'PGPASSWORD', 'PGPASSFILE', 'PGSERVICE', 'PGSERVICEFILE',
               'MYSQL_PWD', 'MYSQL_HOST', 'MYSQL_TCP_PORT', 'MYSQL_UNIX_PORT', 'DATABASE_URL', 'SQLX_DATABASE_URL',
               'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'GOFLAGS', 'GOENV',
               'RUSTC', 'RUSTDOC', 'CARGO_BUILD_RUSTFLAGS', 'GOEXPERIMENT', 'GOAMD64', 'GOWORK',
               'RUSTC_BOOTSTRAP', 'RUSTC_LOG', 'CARGO_BUILD_RUSTC', 'CARGO_BUILD_RUSTDOC',
               'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER',
               'CC', 'CXX', 'CPP', 'LD', 'AR', 'RANLIB', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS',
               'CGO_CFLAGS', 'CGO_CPPFLAGS', 'CGO_CXXFLAGS', 'CGO_LDFLAGS',
               'OPENSSL_CONF', 'OPENSSL_ENGINES', 'OPENSSL_MODULES',
               'PYTHONPATH', 'PYTHONHOME', 'LD_PRELOAD', 'LD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH'}
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(('DBEER_', 'PG', 'MYSQL_', 'CARGO_TARGET_', 'CARGO_PROFILE_', 'CARGO_FEATURE_')) and k.upper() not in removed}
    for name in ('CARGO_BUILD_TARGET', 'GOOS', 'GOARCH'):
        if env.get(name):
            raise ValueError('Native verification refuses cross-build overrides.')
    for name in ('config', 'data', 'state', 'cache', 'temp', 'fixtures', 'bin'):
        private_directory(root / name)
    env.update({'CI': '1', 'CARGO_HOME': str(REPO / 'build/gpui/cargo'),
                'CARGO_TARGET_DIR': str(REPO / 'build/gpui/verification-target'),
                'GOCACHE': str(REPO / 'build/.cache/go'),
                'GOMODCACHE': str(REPO / 'build/.cache/go-mod'),
                'DBEER_GPUI_TEST_ROOT': str(root / 'fixtures'),
                'GOENV': 'off', 'GOTOOLCHAIN': 'local',
                'GOWORK': 'off', 'GOPROXY': 'off', 'GOSUMDB': 'off', 'CARGO_NET_OFFLINE': 'true',
                'DBEER_GPUI_HELPER_PATH': str(root / 'bin' / ('dbeer-core.exe' if os.name == 'nt' else 'dbeer-core'))})
    if os.name == 'nt':
        env.update({'LOCALAPPDATA': str(root / 'data'), 'APPDATA': str(root / 'config'),
                    'TEMP': str(root / 'temp'), 'TMP': str(root / 'temp')})
    else:
        env.update({'XDG_CONFIG_HOME': str(root / 'config'), 'XDG_DATA_HOME': str(root / 'data'),
                    'XDG_STATE_HOME': str(root / 'state'), 'XDG_CACHE_HOME': str(root / 'cache'),
                    'TMPDIR': str(root / 'temp')})
    return env


def host_identity():
    # Hosted Windows Server and headless Ubuntu are accurately recorded; neither
    # is a supported graphical acceptance session. No hostname/account is read.
    value = {'os': platform.system(), 'release': platform.release(), 'machine': platform.machine(),
             'pythonBits': 64 if sys.maxsize > 2**32 else 32, 'coverageLayer': 'headless',
             'desktopAcceptance': False, 'container': Path('/.dockerenv').exists()}
    if value['os'] == 'Linux' and Path('/etc/os-release').is_file():
        fields = dict(re.findall(r'^([A-Z_]+)="?([^\n"]+)', Path('/etc/os-release').read_text(), re.M))
        value['distribution'] = fields.get('ID', 'unknown')
        value['distributionVersion'] = fields.get('VERSION_ID', 'unknown')
    return value


def native_preflight():
    host = host_identity()
    if host['os'] not in ('Windows', 'Linux') or host['machine'].lower() not in ('amd64', 'x86_64') or host['pythonBits'] != 64:
        raise ValueError('Native headless matrix requires Windows or Linux x64.')
    if host['os'] == 'Linux' and (host.get('distribution'), host.get('distributionVersion')) != ('ubuntu', '24.04'):
        raise ValueError('The supported Linux headless host is Ubuntu 24.04 x64.')
    if host['container']:
        raise ValueError('Container compilation is separate from native-host execution evidence.')
    if host['os'] == 'Windows':
        process_machine, native_machine = ctypes.c_ushort(), ctypes.c_ushort()
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.IsWow64Process2.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ushort)]
        if not kernel.IsWow64Process2(ctypes.c_void_p(-1), ctypes.byref(process_machine), ctypes.byref(native_machine)) or native_machine.value != 0x8664:
            raise ValueError('Native x64 Windows is required; ARM emulation is separate.')
    return host


def verify_interactive_windows():
    if platform.system() != 'Windows':
        raise ValueError('Owned HWND delivery requires its actual Windows 11 desktop.')
    version = sys.getwindowsversion()
    if version.product_type != 1 or version.build < 22000:
        raise ValueError('The native HWND adapter stage requires Windows 11, not hosted Server.')
    user = ctypes.WinDLL('user32', use_last_error=True)
    user.GetProcessWindowStation.restype = ctypes.c_void_p
    class UserObjectFlags(ctypes.Structure):
        _fields_ = [('inherit', ctypes.c_int), ('reserved', ctypes.c_int), ('flags', ctypes.c_uint32)]
    flags, needed = UserObjectFlags(), ctypes.c_uint32()
    user.GetUserObjectInformationW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
    if (not user.GetUserObjectInformationW(user.GetProcessWindowStation(), 1, ctypes.byref(flags), ctypes.sizeof(flags), ctypes.byref(needed))
            or not flags.flags & 1):
        raise ValueError('The native HWND adapter stage requires the original interactive window station.')


def stop_child(process):
    # Only the retained Popen child handle. Never search by PID/name or kill a
    # process group/foreign descendants. Fixtures must reap their own children.
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=8)


def expected_go_packages():
    return {'dbeer/helper/' + p.parent.relative_to(REPO / 'helper').as_posix() for p in (REPO / 'helper').rglob('*_test.go')}


def standalone_fast_artifact(message, command, env):
    """Identify the unrelated, locked gpui-fast dev dependency by exact origin.

    Its library is also named gpui and its upstream host-manifest feature is
    unrelated to the maintained gpui-pre product-host contract. Only the reviewed
    standalone base/component library and named compatibility commands may use
    it; root/product graphs and other standalone recipes cannot.
    """
    recipes = ({'manifest': 'prototypes/gpui/vendor/gpui-component/Cargo.toml',
                'lib': True, 'features': 'test-support,tree-sitter,tree-sitter-sql'},
               {'manifest': 'prototypes/gpui/vendor/gpui-base/Cargo.toml',
                'lib': True, 'features': 'test-support'},
               {'manifest': 'prototypes/gpui/vendor/gpui-base/Cargo.toml',
                'testTarget': 'element_ext', 'features': 'test-support'},
               *({'manifest': 'prototypes/gpui/vendor/gpui-component/Cargo.toml',
                  'testTarget': target, 'features': 'test-support,tree-sitter,tree-sitter-sql'}
                 for target in ('base_compat', 'controlled_change_callbacks', 'legacy_button_compat',
                                'legacy_controls_compat', 'legacy_language_config_compat',
                                'table_dump_range', 'theme_compat')))
    stage = next((recipe for recipe in recipes if command[1:] == cargo_plan(recipe)[1:]), None)
    if stage is None:
        return None
    locked = [row for (name, _), row in lock_packages(REPO / stage['manifest'].replace('Cargo.toml', 'Cargo.lock')).items()
              if name == 'gpui-fast']
    if len(locked) != 1:
        return None
    package = locked[0]
    if (package.get('source') != 'registry+https://github.com/rust-lang/crates.io-index'
            or not re.fullmatch('[0-9a-f]{64}', package.get('checksum', ''))
            or message.get('package_id') != package['source'] + '#gpui-fast@' + package['version']):
        return None
    home = Path(env.get('CARGO_HOME', ''))
    manifest = Path(message.get('manifest_path', ''))
    name = 'gpui-fast-' + package['version']
    try:
        relative = manifest.relative_to(home / 'registry/src')
    except ValueError:
        return None
    if (not home.is_absolute() or not manifest.is_absolute() or len(relative.parts) != 3
            or relative.parts[1:] != (name, 'Cargo.toml')):
        return None
    target = message.get('target', {})
    sources = {('custom-build',): ('build-script-build', 'build.rs'), ('lib',): ('gpui', 'src/gpui.rs')}
    expected = sources.get(tuple(target.get('kind', [])))
    if (expected is None or target.get('name') != expected[0]
            or target.get('src_path') != str(manifest.parent / expected[1])
            or message.get('profile', {}).get('test') is not False or message.get('executable')):
        return None
    archive = home / 'registry/cache' / relative.parts[0] / (name + '.crate')
    paths = (manifest, archive)
    if any(p.is_symlink() for path in paths for p in (path, *path.parents)) or any(not path.is_file() for path in paths):
        return None
    # Authenticate and parse the same bounded immutable bytes, even if the
    # cache archive is replaced or changed in place before parsing.
    metadata = archive.lstat()
    with archive.open('rb') as stream:
        opened = os.fstat(stream.fileno())
        if (not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino)):
            return None
        archive_bytes = stream.read(16 * 1024 * 1024 + 1)
    if len(archive_bytes) > 16 * 1024 * 1024 or hashlib.sha256(archive_bytes).hexdigest() != package['checksum']:
        return None
    # Compare the actual extracted sources with the checksum-pinned public
    # archive. Never extract paths or accept a symlink/hardlink source override.
    files = set()
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode='r:gz') as source:
        for member in source.getmembers():
            path = Path(member.name)
            if not path.parts or path.parts[0] != name or '..' in path.parts or path.is_absolute():
                return None
            if member.isdir():
                continue
            if not member.isfile() or member.size > 16 * 1024 * 1024:
                return None
            tail = Path(*path.parts[1:])
            actual = manifest.parent / tail
            if (tail in files or not actual.is_file()
                    or any(p.is_symlink() for p in (actual, *actual.parents))):
                return None
            stream = source.extractfile(member)
            if stream is None or hashlib.sha256(stream.read()).hexdigest() != sha(actual):
                return None
            files.add(tail)
    actual = {path.relative_to(manifest.parent) for path in manifest.parent.rglob('*') if path.is_file() or path.is_symlink()}
    if not files or actual - {Path('.cargo-ok'), Path('.cargo-checksum.json')} != files:
        return None
    return {'package': package['name'], 'version': package['version'], 'source': package['source'],
            'checksum': package['checksum'], 'manifest': str(manifest), 'sourceFiles': len(files)}


def verify_cargo_artifact(message, command, env):
    features = message.get('features', [])
    if not isinstance(features, list) or any(not isinstance(f, str) for f in features):
        raise ValueError('Cargo artifact features are invalid.')
    if 'product-windows-resources' in features:
        raise ValueError('Candidate product features cannot enter unmarked verification.')
    try:
        unrelated = standalone_fast_artifact(message, command, env)
    except (OSError, ValueError, tarfile.TarError):
        unrelated = None
    if 'windows-manifest-provided-by-host' in features and unrelated is None:
        raise ValueError('Candidate product features cannot enter unmarked verification.')
    return unrelated


def collect(command, env, timeout, kind='rust', cwd=REPO):
    """Consume without retaining arbitrary diagnostics, SQL, results or secrets."""
    start = now()
    result = {'command': command, 'startedAt': start, 'summaries': [], 'tests': [],
              'artifacts': [], 'maintainedDependencies': {}, 'ignored': [], 'truncatedLines': 0, 'timedOut': False}
    go_started, go_finished, go_passed = set(), set(), set()
    process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    result['ownedPid'] = process.pid
    timer = threading.Timer(timeout, lambda: (result.update(timedOut=True), stop_child(process)))
    timer.daemon = True
    timer.start()
    try:
        while True:
            raw = process.stdout.readline(MAX_LINE + 1)
            if not raw:
                break
            if len(raw) > MAX_LINE:
                result['truncatedLines'] += 1
                while raw and not raw.endswith(b'\n'):
                    raw = process.stdout.readline(MAX_LINE + 1)
                continue
            line = raw.decode('utf-8', errors='replace').strip()
            if kind in ('cargo', 'cargo-bin'):
                try:
                    message = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                if message.get('reason') == 'compiler-artifact':
                    unrelated = verify_cargo_artifact(message, command, env)
                    if unrelated:
                        result.setdefault('standaloneDevelopmentDependencies', {})[unrelated['package']] = unrelated
                    manifest = message.get('manifest_path')
                    for crate, library in (('gpui-pre', 'gpui'), ('gpui-base', 'gpui_base'), ('gpui-component', 'gpui_component'), ('gpui-pre-linux', 'gpui_linux')):
                        expected_manifest = REPO / 'prototypes/gpui/vendor' / crate / 'Cargo.toml'
                        target_name = message.get('target', {}).get('name', '')
                        if manifest == str(expected_manifest) or (target_name == library and not unrelated):
                            if manifest != str(expected_manifest):
                                # The relocated Linux manifest still compiles the
                                # exact reviewed library source.
                                relocated = HERE / 'pre-linux-unit/Cargo.toml'
                                if crate != 'gpui-pre-linux' or manifest != str(relocated):
                                    raise ValueError('Maintained dependency bypassed its exact local patch.')
                            features = message.get('features', [])
                            if (not isinstance(features, list) or any(not isinstance(f, str) or not re.fullmatch('[A-Za-z0-9_-]+', f) for f in features)
                                    or 'windows-manifest-provided-by-host' in features):
                                raise ValueError('Unmarked verification cannot enable candidate host resources.')
                            result['maintainedDependencies'][crate] = {'manifest': manifest, 'features': sorted(features)}
                if message.get('reason') == 'compiler-artifact' and (kind == 'cargo-bin' or message.get('profile', {}).get('test')) and message.get('executable'):
                    path = Path(message['executable'])
                    if not path.is_absolute() or not path.is_relative_to(Path(env['CARGO_TARGET_DIR'])):
                        raise ValueError('Cargo test artifact escaped the owned build root.')
                    artifact = executable_identity(path)
                    if artifact not in result['artifacts']:
                        result['artifacts'].append(artifact)
                elif message.get('reason') == 'build-finished':
                    result['summaries'].append({'buildFinished': message.get('success') is True})
            elif kind in ('go', 'swift') and line.startswith('{'):
                try:
                    message = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                package = message.get('Package', '')
                if not re.fullmatch(r'dbeer/helper/[A-Za-z0-9_./-]+', package):
                    continue
                action, test = message.get('Action'), message.get('Test')
                if not test and action == 'start':
                    go_started.add(package)
                if not test and action in ('pass', 'fail', 'skip'):
                    go_finished.add(package)
                    if action == 'pass': go_passed.add(package)
                    result['summaries'].append({'result': 'ok' if action == 'pass' else 'FAIL' if action == 'fail' else '?', 'package': package})
                if action in ('pass', 'fail') and test and '/' not in test and re.fullmatch('Test[A-Za-z0-9_]+', test):
                    result['tests'].append({'id': package + '/' + test, 'outcome': 'ok' if action == 'pass' else 'FAILED'})
                if action == 'skip' and test:
                    # Arbitrary subtest labels can contain SQL/values. Retain
                    # the actual root test symbol only; never Output or labels.
                    symbol = test.split('/', 1)[0]
                    result['ignored'].append(package + '/' + symbol if re.fullmatch(r'Test[A-Za-z0-9_]+', symbol) else package + '/redacted-test-label')
            elif kind == 'rust' and (match := SUMMARY.match(line)):
                result['summaries'].append({'result': match[1], 'passed': int(match[2]), 'failed': int(match[3]),
                                            'ignored': int(match[4]), 'measured': int(match[5]), 'filtered': int(match[6])})
            elif kind == 'rust' and (match := TEST.fullmatch(line)):
                entry = {'id': match[1], 'outcome': match[2].split(',')[0]}
                result['tests'].append(entry)
                if entry['outcome'] == 'ignored':
                    result['ignored'].append(entry['id'])
            elif kind == 'swift' and (match := SWIFT.search(line)):
                result['summaries'].append({'passed': int(match[1]), 'framework': 'Swift Testing'})
            elif kind == 'swift' and re.search(r'\bTest\b.*\bskipped\b', line):
                name = re.search(r'\bTest ([A-Za-z_][A-Za-z0-9_]*)\(', line)
                result['ignored'].append(name[1] if name else 'swift-test-label-redacted')
            elif kind == 'python' and (match := re.fullmatch(r'Ran ([1-9][0-9]*) tests? in [0-9.]+s', line)):
                result['summaries'].append({'framework': 'unittest', 'tests': int(match[1])})
            elif kind == 'python' and line == 'OK':
                result['summaries'].append({'result': 'ok', 'framework': 'unittest'})
            elif kind == 'python' and (match := re.fullmatch(r'(test_[A-Za-z0-9_]+) \([A-Za-z0-9_.]+\) \.\.\. (ok|FAIL|ERROR)', line)):
                result['tests'].append({'id': match[1], 'outcome': 'ok' if match[2] == 'ok' else 'FAILED'})
        result['exitCode'] = process.wait(timeout=10)
    finally:
        timer.cancel()
        stop_child(process)
        process.stdout.close()
    result['finishedAt'] = now()
    result['completed'] = (result['exitCode'] == 0 and not result['timedOut'] and not result['truncatedLines'] and bool(result['summaries']))
    if kind in ('cargo', 'cargo-bin'):
        result['completed'] &= result['summaries'] == [{'buildFinished': True}] and bool(result['artifacts'])
    elif kind == 'rust':
        counts = {outcome: sum(t['outcome'] == outcome for t in result['tests']) for outcome in ('ok', 'FAILED', 'ignored')}
        result['completed'] &= len(result['summaries']) == 1 and len({t['id'] for t in result['tests']}) == len(result['tests'])
        if len(result['summaries']) == 1:
            summary = result['summaries'][0]
            result['completed'] &= (summary.get('result') == 'ok' and summary.get('passed', 0) > 0 and summary.get('failed') == 0
                                    and (counts['ok'], counts['FAILED'], counts['ignored']) == (summary.get('passed'), summary.get('failed'), summary.get('ignored')))
    elif kind in ('go', 'swift'):
        required = expected_go_packages()
        result['missingPackages'] = sorted(required - go_passed)
        go_complete = (not result['missingPackages'] and go_started <= go_finished and bool(go_started)
                       and any(t['outcome'] == 'ok' for t in result['tests']) and not any(t['outcome'] == 'FAILED' for t in result['tests'])
                       and len({t['id'] for t in result['tests']}) == len(result['tests'])
                       and not any(s.get('result') == 'FAIL' for s in result['summaries']))
        result['completed'] &= go_complete
        if kind == 'swift':
            result['completed'] &= sum(s.get('framework') == 'Swift Testing' for s in result['summaries']) == 1
    elif kind == 'python':
        result['completed'] &= (len(result['summaries']) == 2 and result['summaries'][-1].get('result') == 'ok'
                                and result['summaries'][0].get('tests') == len(result['tests'])
                                and bool(result['tests']) and all(t['outcome'] == 'ok' for t in result['tests']))
    return result


def require_go_assertions(proof, required):
    missing = [name for name in required if sum(row['id'] == name and row['outcome'] == 'ok' for row in proof['tests']) != 1
               or name in proof['ignored']]
    proof['requiredAssertionsExpected'] = len(required)
    proof['requiredAssertionsObserved'] = len(required) - len(missing)
    proof['missingRequiredAssertions'] = missing
    proof['completed'] = proof['completed'] and not missing
    return proof


def cargo_plan(stage):
    command = ['cargo', 'test', '--locked', '--no-run', '--message-format=json', '--manifest-path', str(REPO / stage.get('manifest', 'prototypes/gpui/Cargo.toml'))]
    if stage.get('lib'):
        command += ['--lib']
    if stage.get('integrationTests'):
        command += ['--tests']
    if stage.get('testTarget'):
        command += ['--test', stage['testTarget']]
    if stage.get('features'):
        command += ['--features', stage['features']]
    # Standalone dependency manifests do not inherit the application's patches.
    # Pass every maintained source explicitly; TOML forward slashes work on Windows.
    if stage.get('manifest'):
        for crate in ('gpui-pre', 'gpui-base', 'gpui-component', 'gpui-pre-linux'):
            patch = (REPO / 'prototypes/gpui/vendor' / crate).as_posix()
            command += ['--config', 'patch.crates-io.' + crate + '.path="' + patch + '"']
    return command


def verify_unit_review(stage):
    if not stage.get('inputReview'):
        return None
    review_path = REPO / stage['inputReview']
    review = strict_json(review_path)
    original = REPO / review['originalManifest']
    manifest = REPO / stage['manifest']
    expected = '# Verification-only relocated manifest. All library/test source remains the actual vendor source.\n'
    expected += original.read_text().replace('path = "src/gpui_linux.rs"', 'path = "../../vendor/gpui-pre-linux/src/gpui_linux.rs"')
    source_root = REPO / review['sourceRoot']
    source = {path.relative_to(REPO / 'prototypes/gpui').as_posix(): sha(path)
              for path in sorted(source_root.rglob('*')) if path.is_file() and not path.is_symlink()}
    if (review['schemaVersion'] != 1 or manifest.read_text() != expected
            or sha(original) != review['originalManifestSha256'] or sha(manifest) != review['manifestSha256']
            or sha(manifest.with_name('Cargo.lock')) != review['lockSha256']
            or sha(REPO / 'prototypes/gpui/Cargo.lock') != review['rootLockSha256']
            or source != review['sourceSha256'] or review['rootKnownAdditionalVersions']
            or review['rootKnownSourceOrChecksumChanges']):
        raise ValueError('Reviewed standalone unit inputs changed; review the new exact graph before execution.')
    return {'reviewSha256': sha(review_path), 'originalManifestSha256': review['originalManifestSha256'],
            'rootLockSha256': review['rootLockSha256'], 'unitLockSha256': review['lockSha256'],
            'rootPackageCount': review['rootPackageCount'], 'unitPackageCount': review['unitPackageCount'],
            'rootKnownAdditionalVersions': review['rootKnownAdditionalVersions'], 'unitOnlyPackages': review['unitOnlyPackages']}


def execute_rust(stage, env, ledger, root):
    if stage.get('requiresInteractiveWindows'):
        verify_interactive_windows()
    fixture = verify_fixture_environment(env)
    unit_review = verify_unit_review(stage)
    dependency_review = verify_dependency_review(REPO)
    manifest = REPO / stage.get('manifest', 'prototypes/gpui/Cargo.toml')
    if not manifest.with_name('Cargo.lock').is_file():
        ledger['stages'].append({'id': stage['id'], 'layer': stage['layer'], 'status': 'pending',
                                 'reason': 'reviewed-standalone-lock-required-before-locked-unit-build',
                                 'dependencyGraph': stage.get('dependencyGraph', 'root-lock')})
        return False
    built = collect(cargo_plan(stage), env, 3600, kind='cargo')
    write_json(root / (stage['id'] + '-build.json'), built)
    item = {'id': stage['id'], 'layer': stage['layer'], 'buildProof': stage['id'] + '-build.json',
            'conditionalSkips': stage.get('conditionalSkips', []), 'runs': [], 'status': 'failed',
            'fixture': fixture, 'buildMode': 'unmarked-development-tests'}
    item['dependencyGraph'] = stage.get('dependencyGraph', 'root-lock')
    item['maintainedInputReview'] = dependency_review
    if unit_review:
        item['unitInputReview'] = unit_review
    item['manifestSha256'] = sha(manifest)
    item['lockSha256'] = sha(manifest.with_name('Cargo.lock'))
    item['maintainedDependencies'] = built['maintainedDependencies']
    ledger['stages'].append(item)
    if not built['completed']:
        return False
    required_dependencies = stage.get('requiredMaintainedDependencies', []) + stage.get('requiredMaintainedDependenciesByHost', {}).get(platform.system(), [])
    if set(required_dependencies) - set(built['maintainedDependencies']):
        item['missingMaintainedDependencies'] = sorted(set(required_dependencies) - set(built['maintainedDependencies']))
        return False
    for artifact in built['artifacts']:
        executable_identity(artifact['path'], artifact)
        if verify_fixture_environment(env) != fixture:
            raise ValueError('Owned fault fixture environment changed.')
        command = [artifact['path']]
        if stage.get('filter'):
            command.append(stage['filter'])
        command += ['--test-threads=1', '--format=pretty']
        if stage.get('ignored'):
            command.append('--ignored')
        proof = collect(command, env, 1200)
        executable_identity(artifact['path'], artifact)
        if verify_fixture_environment(env) != fixture:
            proof['completed'] = False
        proof['artifact'] = artifact
        item['runs'].append(proof)
    item['status'] = 'passed' if item['runs'] and all(p['completed'] for p in item['runs']) else 'failed'
    names = [t['id'] for proof in item['runs'] for t in proof['tests'] if t['outcome'] == 'ok']
    exact = stage.get('requiredTests', [])
    suffixes = list(dict.fromkeys(stage.get('requiredSuffixes', []) + stage.get('requiredSuffixesByHost', {}).get(platform.system(), [])))
    suffixes = [suffix for suffix in suffixes if not any(name == suffix or name.endswith('::' + suffix) for name in exact)]
    missing = [suffix for suffix in suffixes if sum(name.endswith('::' + suffix) or name == suffix for name in names) != 1]
    if missing:
        item['status'] = 'failed'
        item['missingRequiredAssertions'] = missing
    missing_exact = [name for name in exact if names.count(name) != 1]
    if missing_exact:
        item['status'] = 'failed'
        item['missingRequiredAssertions'] = sorted(set(item.get('missingRequiredAssertions', []) + missing_exact))
    item['requiredAssertionsExpected'] = len(exact) + len(suffixes)
    item['requiredAssertionsObserved'] = item['requiredAssertionsExpected'] - len(item.get('missingRequiredAssertions', []))
    if 'portableFaultAssertionsExpected' in stage:
        item['portableFaultAssertionsExpected'] = stage['portableFaultAssertionsExpected']
        critical = strict_json(REPO / 'prototypes/gpui/fixtures/parity-matrix/fault-plan.json')['portablePeer']['requiredTests']
        item['portableFaultAssertionsObserved'] = sum(names.count(name) == 1 for name in critical)
        if item['portableFaultAssertionsObserved'] != item['portableFaultAssertionsExpected']:
            item['status'] = 'failed'
    return item['status'] == 'passed'


def validate():
    matrix = strict_json(HERE / 'matrix.json')
    cases = strict_json(REPO / 'prototypes/gpui/fixtures/parity-matrix/cases.json')
    faults = strict_json(REPO / 'prototypes/gpui/fixtures/parity-matrix/fault-plan.json')
    if matrix['schemaVersion'] != 1 or cases['schemaVersion'] != 1:
        raise ValueError('Unknown matrix version.')
    verify_dependency_review(REPO)
    ids = [s['id'] for s in matrix['rustStages'] + matrix['databaseStages'] + matrix['sharedStages']]
    if len(ids) != len(set(ids)) or any(not re.fullmatch('[a-z0-9-]+', i) for i in ids):
        raise ValueError('Invalid or duplicate stage identity.')
    for stage in matrix['rustStages'] + matrix['databaseStages']:
        if stage['layer'] not in ('headless', 'transport', 'persistence', 'vendor', 'private-bus', 'database', 'native-window'):
            raise ValueError('Automated stage cannot claim desktop acceptance.')
        if not (REPO / stage.get('manifest', 'prototypes/gpui/Cargo.toml')).is_file():
            raise ValueError('Missing stage manifest.')
        required = stage.get('requiredTests', []) + stage.get('requiredSuffixes', [])
        required += [name for names in stage.get('requiredSuffixesByHost', {}).values() for name in names]
        source_root = REPO / stage['sourceRoot'] if stage.get('sourceRoot') else (REPO / stage.get('manifest', 'prototypes/gpui/Cargo.toml')).parent / 'src'
        verify_unit_review(stage)
        sources = '\n'.join(path.read_text(encoding='utf-8') for path in source_root.rglob('*.rs'))
        if stage.get('integrationTests') or stage.get('testTarget'):
            sources += '\n' + '\n'.join(path.read_text(encoding='utf-8') for path in source_root.parent.joinpath('tests').rglob('*.rs'))
        for name in required:
            if not re.fullmatch('[A-Za-z0-9_:]+', name):
                raise ValueError('Invalid required assertion symbol.')
            if not re.search(r'\bfn\s+' + re.escape(name.rsplit('::', 1)[-1]) + r'\b', sources):
                raise ValueError('Required assertion is absent from the stage source graph.')
        if len(set(stage.get('requiredTests', []))) != len(stage.get('requiredTests', [])):
            raise ValueError('Duplicate required assertion symbol.')
    seen = set()
    for case in cases['cases']:
        if case['id'] in seen or not re.fullmatch('[A-Z0-9-]+', case['id']):
            raise ValueError('Invalid or duplicate case identity.')
        seen.add(case['id'])
        if case['preparedStatus'] != 'not-run':
            raise ValueError('Prepared behavior mappings cannot record runtime success.')
        for assertion in case['assertions']:
            path, symbol = assertion.split('#', 1)
            if not re.fullmatch('[A-Za-z0-9_]+', symbol) or not re.search(r'\b(?:fn|func)\s+' + re.escape(symbol) + r'\b', (REPO / path).read_text(encoding='utf-8')):
                raise ValueError('Missing prepared behavior assertion.')
        for suite in case['swiftBehaviorSuites']:
            swift_sources = (REPO / 'macos/Tests/DBeerTests').glob('*.swift')
            if not any(re.search(r'\b(?:struct|class)\s+' + re.escape(suite) + r'\b', p.read_text()) for p in swift_sources):
                raise ValueError('Missing Swift behavior suite.')
        for path in case.get('fixtures', []):
            if not (REPO / path).is_file():
                raise ValueError('Missing fixture input.')
    for stage in matrix['sharedStages']:
        for name in stage['requiredTests']:
            match = re.fullmatch(r'dbeer/helper/([A-Za-z0-9_/]+)/((?:Test)[A-Za-z0-9_]+)', name)
            if not match or not any(re.search(r'\bfunc\s+' + re.escape(match[2]) + r'\b', path.read_text())
                                    for path in (REPO / 'helper' / match[1]).glob('*_test.go')):
                raise ValueError('Required Go database assertion is absent from its exact package.')
    if (matrix['nativeAcceptance']['features'] != 57 or matrix['nativeAcceptance']['assertions'] != 190
            or matrix['nativeAcceptance']['cells'] != 171 or matrix['nativeAcceptance']['status'] != 'not-run'
            or matrix['nativeAcceptance']['headlessCanAccept'] is not False):
        raise ValueError('Prepared matrix cannot accept native cells.')
    if faults['schemaVersion'] != 1 or faults['state'] != 'prepared-not-run' or faults['disposableMarker'] != 'owned-dbeer-parity-only-v1':
        raise ValueError('Invalid disposable fault plan.')
    if set(faults['caseIds']) - seen:
        raise ValueError('Fault plan references an unknown behavior group.')
    peer = (HERE / 'fault-helper/src/main.rs').read_text()
    for mode in faults['portablePeer']['previewModes'] + faults['portablePeer']['runToFileModes']:
        # success/mutated-target intentionally use the common successful peer
        # terminal: the product test changes the destination for mutated-target.
        if mode not in ('success', 'mutated-target') and ('"' + mode + '"') not in peer:
            raise ValueError('Fault plan mode has no portable fixture behavior.')
    critical = faults['portablePeer']['requiredTests']
    if len(critical) != 13 or len(set(critical)) != 13:
        raise ValueError('All thirteen portable fault assertions are required.')
    for name in critical:
        path = 'preview/tests.rs' if name.startswith('preview::tests::fault_helper::') else 'run_to_file/tests.rs'
        if not re.search(r'\bfn\s+' + re.escape(name.rsplit('::', 1)[-1]) + r'\b', (REPO / 'prototypes/gpui/src' / path).read_text()):
            raise ValueError('Missing converted portable fault assertion.')
    for stage in matrix['rustStages']:
        if stage['id'] in ('default', 'native-smoke') and not set(critical) <= set(stage.get('requiredTests', [])):
            raise ValueError('Root stages must require every portable fault assertion.')
    validate_coverage(REPO, matrix, cases)
    return matrix


def main():
    os.umask(0o077)
    sys.dont_write_bytecode = True
    def terminate_as_interrupt(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate_as_interrupt)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--validate', action='store_true', help='Static manifest/source-symbol validation only; runs no tests.')
    parser.add_argument('--final-integration', action='store_true', help='Explicit authorization after all Task 32 code is ready.')
    parser.add_argument('--stage', action='append', default=[], help='Exact matrix stage ID; may repeat.')
    parser.add_argument('--all-headless', action='store_true')
    parser.add_argument('--database-pair', nargs=2, metavar=('POSTGRES', 'MYSQL'))
    parser.add_argument('--shared-go', action='store_true')
    parser.add_argument('--swift', action='store_true')
    parser.add_argument('--self-checks', action='store_true', help='Run prepared runner/portable-peer safety suites in the controlled environment.')
    args = parser.parse_args()
    matrix = validate()
    if args.validate:
        if any((args.final_integration, args.stage, args.all_headless, args.database_pair, args.shared_go, args.swift, args.self_checks)):
            parser.error('Static validation cannot be combined with execution.')
        print('Matrix/source-symbol validation completed; no tests executed; native cells remain not-run.')
        return 0
    if not args.final_integration:
        parser.error('Execution is deferred; supply --final-integration only after all Task 32 code is ready.')
    if not any((args.stage, args.all_headless, args.database_pair, args.shared_go, args.swift, args.self_checks)):
        parser.error('Select an execution layer.')
    stages = matrix['rustStages']
    selected = [s for s in stages if (args.all_headless and s.get('includedInAll', True)) or s['id'] in args.stage]
    if set(args.stage) - {s['id'] for s in stages}:
        parser.error('Unknown stage identity.')
    host = native_preflight() if selected or args.database_pair or args.self_checks else host_identity()
    if args.swift and host['os'] != 'Darwin':
        parser.error('Swift product verification requires the supported macOS runner.')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    root = OUTPUT / uuid.uuid4().hex
    private_directory(root)
    env = clean_environment(root)
    env['RUSTUP_TOOLCHAIN'] = matrix['rustToolchain']
    env['RUSTUP_AUTO_INSTALL'] = '0'
    ledger = {'schemaVersion': 1, 'runNonce': root.name, 'startedAt': now(), 'host': host,
              'sourceInventory': source_contract.capture(REPO), 'stages': [], 'nativeAcceptance': matrix['nativeAcceptance'],
              'status': 'running', 'privateRoot': str(root), 'cleanup': 'owned-resources-only',
              'buildMode': 'unmarked-development-tests', 'rustToolchain': matrix['rustToolchain'],
              'targetDirectory': env['CARGO_TARGET_DIR'], 'rootIdentity': list(verify_private(root)),
              'fixtureRootIdentity': list(verify_private(root / 'fixtures')),
              'finalSnapshotObligations': matrix['finalSnapshotObligations']}
    ledger['sourceSha256'] = ledger['sourceInventory']['sourceSha256']
    write_json(root / 'request.json', ledger)
    success = False
    try:
        if selected or args.database_pair or args.self_checks:
            # Read installed names only; the runner does not install/download a
            # toolchain. RUSTUP_AUTO_INSTALL=0 also applies to every later child.
            toolchains = subprocess.run(['rustup', 'toolchain', 'list'], env=env, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, check=False)
            if toolchains.returncode or not any(line.split()[0].startswith(matrix['rustToolchain'] + '-') for line in toolchains.stdout.decode('ascii', errors='replace').splitlines() if line.split()):
                raise ValueError('Pinned Rust must already be installed locally.')
            helper = Path(env['DBEER_GPUI_HELPER_PATH'])
            # No stdout/stderr retained: Go build diagnostics can include paths.
            result = subprocess.run(['go', 'build', '-trimpath', '-o', str(helper), './cmd/dbeer-core'],
                                    cwd=REPO / 'helper', env=env, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, timeout=1200, check=False)
            if result.returncode:
                raise ValueError('Native helper compilation failed.')
            helper_identity = executable_identity(helper)
            env['DBEER_GPUI_TEST_HELPER_SHA256'] = helper_identity['sha256']
            ledger['helper'] = {**helper_identity, 'buildCommand': ['go', 'build', '-trimpath', '-o', str(helper), './cmd/dbeer-core'], 'buildMode': 'unmarked-development-tests'}
            fixture_env = env.copy()
            fixture_env['CARGO_TARGET_DIR'] = str(REPO / 'build/gpui/task30-fault-target')
            fixture_command = ['cargo', 'build', '--locked', '--message-format=json', '--manifest-path', str(HERE / 'fault-helper/Cargo.toml')]
            fixture_result = collect(fixture_command, fixture_env, 1200, kind='cargo-bin')
            write_json(root / 'fault-peer-build.json', fixture_result)
            if not fixture_result['completed'] or len(fixture_result['artifacts']) != 1:
                raise ValueError('Portable fault fixture compilation failed.')
            fault_helper = Path(fixture_env['CARGO_TARGET_DIR']) / 'debug' / ('dbeer-parity-fault-helper.exe' if os.name == 'nt' else 'dbeer-parity-fault-helper')
            fault_identity = executable_identity(fault_helper, fixture_result['artifacts'][0])
            env['DBEER_GPUI_FAULT_HELPER_PATH'] = str(fault_helper)
            env['DBEER_GPUI_FAULT_HELPER_SHA256'] = fault_identity['sha256']
            ledger['faultHelper'] = {**fault_identity, 'buildCommand': fixture_command}
            verify_fixture_environment(env)
        success = True
        for stage in selected:
            if host['os'] not in stage['hosts']:
                ledger['stages'].append({'id': stage['id'], 'layer': stage['layer'], 'status': 'skipped', 'reason': 'host-not-applicable'})
                continue
            if not execute_rust(stage, env, ledger, root):
                success = False
        if args.database_pair:
            from owned_databases import run_pair
            success = run_pair(args.database_pair, env, ledger, root, execute_rust, collect) and success
        if args.shared_go:
            shared_env = env.copy()
            shared_env['GOFLAGS'] = '-json'
            proof = collect(['bash', './scripts/test-go.sh'], shared_env, 1800, 'go')
            proof['environmentOverrides'] = {'GOFLAGS': '-json'}
            ledger['stages'].append({'id': 'shared-go-race', 'layer': 'shared', 'proof': proof,
                                     'conditionalSkips': ['PostgreSQL/MySQL/TLS integration: no owned DB in this stage'],
                                     'status': 'passed' if proof['completed'] else 'failed'})
            success = proof['completed'] and success
        if args.swift:
            swift_env = env.copy()
            swift_env['GOFLAGS'] = '-json'
            proof = collect(['./scripts/test.sh', '--all'], swift_env, 3600, 'swift')
            proof['coverage'] = macos_coverage(proof)
            proof['completed'] = proof['completed'] and not proof['coverage']['unapprovedSkips']
            ledger['stages'].append({'id': 'swiftui-regressions', 'layer': 'swiftui', 'proof': proof,
                                     'status': 'passed' if proof['completed'] else 'failed',
                                     'conditionalSkips': proof['coverage']['uncoveredDatabaseRoots']})
            success = proof['completed'] and success
        if args.self_checks:
            for identity, filename in (('runner-safety', 'test_runner.py'), ('portable-peer-conformance', 'test_fault_peer.py')):
                proof = collect([sys.executable, '-B', str(HERE / filename)], env, 300, kind='python')
                ledger['stages'].append({'id': identity, 'layer': 'runner-safety', 'proof': proof,
                                         'status': 'passed' if proof['completed'] else 'failed'})
                success = proof['completed'] and success
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt):
        ledger['error'] = 'Verification did not complete; no acceptance granted.'
        ledger['proofInvalidated'] = True
        success = False
    finally:
        ledger['finishedAt'] = now()
        if not any(stage.get('status') == 'passed' for stage in ledger['stages']):
            success = False
        ledger['sourceInventoryAfter'] = source_contract.capture(REPO)
        ledger['sourceSha256After'] = ledger['sourceInventoryAfter']['sourceSha256']
        if ledger['sourceSha256'] != ledger['sourceSha256After']:
            success = False
            ledger['error'] = 'Sources changed during verification; proof cannot accept this revision.'
        ownership_ok = True
        try:
            if list(verify_private(root)) != ledger['rootIdentity'] or list(verify_private(root / 'fixtures')) != ledger['fixtureRootIdentity']:
                raise ValueError('Owned run directory changed.')
            if 'faultHelper' in ledger:
                verify_fixture_environment(env)
        except (OSError, ValueError):
            ownership_ok = False
            success = False
            ledger['error'] = 'Owned path or executable identity changed; proof is invalid.'
        if (ledger.get('proofInvalidated') or not ownership_ok or ledger['sourceSha256'] != ledger['sourceSha256After']
                or ledger.get('databaseFixtures', {}).get('cleanupCompleted') is False):
            for stage in ledger['stages']:
                if stage['status'] == 'passed':
                    stage.update(status='invalidated', reason='source-or-owned-fixture-proof-incomplete')
        ledger['status'] = 'passed' if success else 'failed'
        ledger['behaviorEvidence'] = behavior_evidence(matrix, strict_json(REPO / 'prototypes/gpui/fixtures/parity-matrix/cases.json'), ledger)
        # Never follow a replacement path just to publish a failure record.
        if list(verify_private(root)) != ledger['rootIdentity']:
            raise ValueError('Completion publication refused for a replaced run root.')
        write_json(root / 'completed.json', ledger)
    print('Verification ' + ledger['status'] + '; proof: ' + str(root / 'completed.json'))
    print('Native desktop and installed acceptance remain not-run.')
    return 0 if success else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        print('Verification configuration is invalid; no tests accepted.', file=sys.stderr)
        sys.exit(2)
