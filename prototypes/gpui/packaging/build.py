#!/usr/bin/env python3
"""Build an exact native DBeer pair; optional tests/packages are explicit operations."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
if sys.version_info < (3, 11):
    print('DBeer paired native builds require Python 3.11 or later.', file=sys.stderr)
    sys.exit(2)
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('dbeer_product_package', HERE / 'package.py')
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
Refused = core.Refused


def build_environment(root):
    """No inherited product marker, alternate target or compiler/link injection."""
    environment = dict(os.environ)
    injections = {'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER',
                  'RUSTC_WORKSPACE_WRAPPER', 'RUSTC', 'RUSTDOC', 'CARGO_BUILD_RUSTFLAGS',
                  'CARGO_BUILD_RUSTC', 'CARGO_BUILD_RUSTC_WRAPPER', 'GOFLAGS', 'GOENV',
                  'CC', 'CXX', 'AR', 'LD', 'CFLAGS', 'CPPFLAGS', 'CXXFLAGS', 'LDFLAGS',
                  'CGO_CFLAGS', 'CGO_CPPFLAGS', 'CGO_CXXFLAGS', 'CGO_LDFLAGS'}
    for name in environment:
        if environment[name] and (name in injections or name.startswith('CARGO_PROFILE_')
                                  or re.fullmatch(r'CARGO_TARGET_.*_(RUSTFLAGS|LINKER|RUNNER|AR)', name)):
            raise Refused('Unset compiler and linker overrides for native product builds.')
    for name in list(environment):
        if name.startswith(('DBEER_', 'PG', 'MYSQL', 'DYLD_', 'LD_')):
            del environment[name]
    cargo_home = core.safe(core.ROOT / 'build/gpui/cargo', directory=True, missing=True)
    if any((cargo_home / name).exists() or (cargo_home / name).is_symlink()
           for name in ['config', 'config.toml']):
        raise Refused('Product builds cannot consume untracked Cargo cache configuration.')
    temporary = core.safe(root / 'tmp', directory=True, missing=True)
    temporary.mkdir(mode=0o700, exist_ok=True)
    environment.update({
        'CARGO_HOME': str(cargo_home),
        'TMPDIR': str(temporary), 'TMP': str(temporary), 'TEMP': str(temporary),
        'GOTMPDIR': str(temporary),
        'CARGO_TARGET_DIR': str(root / 'target'),
        'GOCACHE': str(core.ROOT / 'build/.cache/go'),
        'GOMODCACHE': str(core.ROOT / 'build/.cache/go-mod'),
        'GOTOOLCHAIN': 'local', 'GOENV': 'off',
    })
    return environment


def run(command, environment, *, cwd=None, output=None, phase='Native build or metadata preparation', verification=False):
    """Retain metadata only; child diagnostics cannot become application evidence."""
    if output is None:
        result = subprocess.run(command, cwd=cwd or core.ROOT, env=environment,
                                stdin=subprocess.DEVNULL,
                                stdout=None if verification else subprocess.DEVNULL,
                                stderr=None if verification else subprocess.DEVNULL, check=False)
    else:
        with output.open('xb') as stream:
            result = subprocess.run(command, cwd=cwd or core.ROOT, env=environment,
                                    stdin=subprocess.DEVNULL, stdout=stream,
                                    stderr=subprocess.DEVNULL, check=False)
        output.chmod(0o600)
    if result.returncode != 0:
        raise Refused(phase + ' failed.')


def native_toolchains(target, environment):
    rust = core.checked_output(['rustc', '-vV'], limit=8192, timeout=15,
                               environment=environment).decode('ascii')
    if re.findall(r'^host: (.+)$', rust, re.MULTILINE) != [core.TARGETS[target]]:
        raise Refused('The Rust host must be the exact native product target.')
    go = core.strict_json(core.checked_output(
        ['go', 'env', '-json', 'GOHOSTOS', 'GOHOSTARCH', 'GOFLAGS', 'GOVERSION'],
        limit=8192, timeout=15, environment=environment))
    expected_os = 'windows' if target.startswith('windows') else 'linux'
    if (go.get('GOHOSTOS'), go.get('GOHOSTARCH'), go.get('GOFLAGS')) != (expected_os, 'amd64', ''):
        raise Refused('The Go host must be the exact native product target without extra build flags.')
    return {'rustcVerboseVersion': rust, 'goVersion': go['GOVERSION']}


def go_link_flags(identity):
    marker = core.json_bytes(identity)[:-1].decode('ascii')
    # Go's -ldflags parser, rather than a shell, consumes these single quotes.
    # They preserve every double quote in the canonical JSON marker.
    if "'" in marker or '\n' in marker or '\r' in marker:
        raise Refused('The product identity cannot be represented as a Go link value.')
    return ("-X 'main.productBuildIdentity=" + marker + "' "
            '-X main.productVersion=' + identity['version'] + ' '
            '-X main.productBuildNumber=' + identity['buildNumber'])


def assert_frozen(identity):
    if identity != core.new_identity(identity['target']):
        raise Refused('Product sources changed during the paired build; rebuild from a frozen tree.')


def verify_pair(gui, helper, identity):
    """Static header/marker checks never start either executable."""
    marker = core.json_bytes(identity)[:-1]
    for binary in (gui, helper):
        if marker not in core.binary_header(binary, identity['target']):
            raise Refused('The native pair does not retain the exact canonical embedded marker.')


def execute(args):
    core.native(args.target)
    if args.test:
        # The runner constructs its own unmarked helper, peer and test target.
        # It clears product/compiler injection; no candidate test bypass exists.
        wrapper = 'test-gpui-parity.ps1' if os.name == 'nt' else 'test-gpui-parity.sh'
        command = ['pwsh', '-NoProfile', '-File'] if os.name == 'nt' else ['bash']
        command += [str(core.ROOT / 'scripts' / wrapper), '--final-integration',
                    '--all-headless', '--self-checks']
        # This runner emits only fixed statuses and sanitized proof metadata;
        # its collectors never forward raw compiler, application or DB output.
        run(command, dict(os.environ), phase='Isolated headless verification (see build/gpui/task30-runs)',
            verification=True)
    builds = core.safe(core.ROOT / 'build/gpui/product-builds', directory=True, missing=True)
    builds.mkdir(parents=True, exist_ok=True, mode=0o700)
    root = Path(tempfile.mkdtemp(prefix='product-', dir=builds))
    root.chmod(0o700)
    environment = build_environment(root)
    toolchains = native_toolchains(args.target, environment)
    identity = core.new_identity(args.target)
    data = core.json_bytes(identity)
    core.put(root, 'BUILD-IDENTITY.json', data, 0o600)
    environment['DBEER_PRODUCT_BUILD_IDENTITY'] = data[:-1].decode('ascii')
    environment['DBEER_PRODUCT_IDENTITY_FILE'] = str(root / 'BUILD-IDENTITY.json')
    environment['DBEER_PRODUCT_BUILD_PYTHON'] = str(Path(sys.executable).resolve())
    target = core.TARGETS[args.target]
    suffix = '.exe' if args.target.startswith('windows') else ''
    binary_directory = root / 'target' / target / 'release'
    binary_directory.mkdir(parents=True)
    gui, helper = (binary_directory / ('dbeer-gpui' + suffix),
                   binary_directory / ('dbeer-core' + suffix))
    if args.target.startswith('windows'):
        run([sys.executable, '-B', str(HERE / 'native-resources/generate.py'),
             'generate', '--identity', str(root / 'BUILD-IDENTITY.json'),
             '--output', str(root / 'native-resources')], environment, phase='Windows resource generation')
        environment['DBEER_PRODUCT_NATIVE_RESOURCES'] = str(root / 'native-resources')
    assert_frozen(identity)
    run(['go', 'build', '-trimpath', '-buildvcs=false', '-ldflags', go_link_flags(identity),
         '-o', str(helper), './cmd/dbeer-core'], environment, cwd=core.ROOT / 'helper', phase='Go helper compilation')
    assert_frozen(identity)
    cargo_arguments = ['--locked', '--target', target,
                       '--manifest-path', str(core.ROOT / 'prototypes/gpui/Cargo.toml')]
    if args.target.startswith('windows'):
        cargo_arguments += ['--features', 'product-windows-resources']
    run(['cargo', 'build', *cargo_arguments, '--release', '--bin', 'dbeer-gpui'], environment,
        phase='Rust frontend compilation')
    assert_frozen(identity)
    verify_pair(gui, helper, identity)
    if args.target.startswith('windows'):
        run(['cargo', 'tree', *cargo_arguments, '--edges', 'features', '--invert', 'gpui-pre'],
            environment, output=root / 'windows-manifest-features.txt', phase='Windows feature inspection')
        if b'windows-manifest-provided-by-host' not in core.bounded(root / 'windows-manifest-features.txt'):
            raise Refused('The product host-manifest feature is missing from the actual Windows graph.')
        run([sys.executable, '-B', str(HERE / 'native-resources/generate.py'),
             'verify-native-pe', '--identity', str(root / 'BUILD-IDENTITY.json'),
             '--inputs', str(root / 'native-resources'), '--gui', str(gui)], environment,
            phase='Windows resource verification')
    result = {'schemaVersion': 1, 'identity': identity, 'status': 'compiled-only',
              'runtimeAcceptance': 'not-run',
              'toolchains': toolchains,
              'gui': str(gui.relative_to(core.ROOT)), 'helper': str(helper.relative_to(core.ROOT)),
              'guiSha256': core.sha(core.bounded(gui, 512 * 1024 * 1024)),
              'helperSha256': core.sha(core.bounded(helper, 512 * 1024 * 1024))}
    if args.package:
        run(['cargo', 'metadata', '--locked', '--all-features', '--format-version', '1',
             '--manifest-path', str(core.ROOT / 'prototypes/gpui/Cargo.toml')], environment,
            output=root / 'cargo-metadata.json', phase='Cargo notice metadata preparation')
        cache_spec = importlib.util.spec_from_file_location('dbeer_public_dependency_cache', HERE / 'prepare-go-cache.py')
        cache = importlib.util.module_from_spec(cache_spec)
        cache_spec.loader.exec_module(cache)
        try:
            go_modules = cache.prepare()
        except cache.core.Refused as error:
            raise Refused('Exact public Go notice metadata preparation failed.') from error
        core.put(root, 'go-modules.json', core.bounded(go_modules, 8 * 1024 * 1024), 0o600)
        assert_frozen(identity)
        core.collect_notices(argparse.Namespace(cargo_metadata=root / 'cargo-metadata.json',
                                               go_modules=root / 'go-modules.json',
                                               output=root / 'notices', environment=environment))
        core.package(argparse.Namespace(target=args.target, gui=gui, helper=helper,
                                        identity=root / 'BUILD-IDENTITY.json',
                                        notices=root / 'notices', output=None))
        result['status'] = 'unsigned-development-candidate'
    assert_frozen(identity)
    core.put(root, 'BUILD-RESULT.json', core.json_bytes(result), 0o600)
    print('DBeer paired native build complete: ' + str(root / 'BUILD-RESULT.json'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=core.TARGETS, required=True)
    parser.add_argument('--test', action='store_true', help='run isolated unmarked final verification first')
    parser.add_argument('--package', action='store_true', help='inspect native build-info and prepare a new candidate')
    execute(parser.parse_args())


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        # Refusals contain fixed diagnostics only; never expose child output.
        print('DBeer paired native build refused: ' + str(error) + ' Existing candidates are preserved.', file=sys.stderr)
        sys.exit(2)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('DBeer paired native build refused unsafe, unsupported, changed or incomplete inputs. '
              'Existing candidates are preserved.', file=sys.stderr)
        sys.exit(2)
