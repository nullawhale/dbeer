#!/usr/bin/env python3
"""Provision public Go module sources using private copies of release module files."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
if sys.version_info < (3, 11):
    print('DBeer dependency preparation requires Python 3.11 or later.', file=sys.stderr)
    sys.exit(2)
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('dbeer_dependency_package', HERE / 'package.py')
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)


def prepare():
    original = {name: core.bounded(core.ROOT / 'helper' / name) for name in ['go.mod', 'go.sum']}
    parent = core.safe(core.ROOT / 'build/gpui/dependency-preparation', directory=True, missing=True)
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    owned = Path(tempfile.mkdtemp(prefix='go-', dir=parent))
    owned.chmod(0o700)
    for name, data in original.items():
        core.put(owned, name, data, 0o600)
    environment = dict(os.environ)
    for name in list(environment):
        if name.startswith(('DBEER_', 'PG', 'MYSQL', 'DYLD_', 'LD_')):
            del environment[name]
    temporary = owned / 'tmp'
    temporary.mkdir(mode=0o700)
    environment.update({'TMPDIR': str(temporary), 'TMP': str(temporary), 'TEMP': str(temporary),
                        'GOTMPDIR': str(temporary),
                        'GOCACHE': str(core.ROOT / 'build/.cache/go'),
                        'GOMODCACHE': str(core.ROOT / 'build/.cache/go-mod'),
                        'GOFLAGS': '', 'GOENV': 'off', 'GOTOOLCHAIN': 'local',
                        'GOPROXY': 'https://proxy.golang.org', 'GOSUMDB': 'sum.golang.org',
                        'GOPRIVATE': '', 'GONOSUMDB': '', 'GONOPROXY': '', 'GOINSECURE': ''})
    result = subprocess.run(['go', 'mod', 'download', '-modfile=' + str(owned / 'go.mod'), 'all'],
                            cwd=core.ROOT / 'helper', env=environment, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if result.returncode != 0:
        raise core.Refused('Exact public module cache preparation failed.')
    modules = owned / 'MODULES.json'
    with modules.open('xb') as stream:
        result = subprocess.run(['go', 'list', '-mod=readonly', '-modfile=' + str(owned / 'go.mod'),
                                 '-m', '-json', 'all'], cwd=core.ROOT / 'helper', env=environment,
                                stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.DEVNULL, check=False)
    modules.chmod(0o600)
    if any(core.bounded(core.ROOT / 'helper' / name) != data for name, data in original.items()):
        raise core.Refused('Release module inputs changed during cache preparation.')
    if result.returncode != 0 or core.bounded(owned / 'go.mod') != original['go.mod']:
        raise core.Refused('Exact public module cache preparation failed or changed its module graph.')
    core.put(owned, 'PREPARED.json', core.json_bytes({
        'schemaVersion': 1, 'status': 'public-compiler-cache-prepared',
        'releaseModuleSha256': {name: core.sha(data) for name, data in original.items()},
        'moduleMetadataSha256': core.sha(core.bounded(modules)),
        'runtimeTestsExecuted': False}), 0o600)
    return modules


def main():
    prepare()
    print('DBeer public Go module cache prepared; release module files are unchanged.')


if __name__ == '__main__':
    try:
        main()
    except (core.Refused, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('DBeer public dependency preparation refused incomplete or changed inputs.', file=sys.stderr)
        sys.exit(2)
