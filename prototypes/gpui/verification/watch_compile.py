#!/usr/bin/env python3
"""Bounded owned-container compile proof finalizer. Never executes test binaries."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import time

from run import REPO, sha, strict_json, write_json

LABEL = 'app.dbeer.task30-run'
CRATES = ('gpui-base', 'gpui-component', 'gpui-pre-linux')


def now():
    return datetime.now(timezone.utc).isoformat()


def state(cid):
    template = '{"running":{{.State.Running}},"exitCode":{{.State.ExitCode}},"oomKilled":{{.State.OOMKilled}},"startedAt":"{{.State.StartedAt}}","owner":"{{index .Config.Labels "' + LABEL + '"}}"}'
    result = subprocess.run(['docker', 'inspect', '--format', template, cid], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=15, check=False)
    if result.returncode:
        reachable = subprocess.run(['docker', 'version', '--format', '{{.Server.Os}}'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
        return {'present': False, 'daemonReachable': reachable.returncode == 0}
    value = json.loads(result.stdout)
    value['present'] = True
    return value


def versions(path):
    return set(re.findall(r'\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"', path.read_text()))


def finish(root, request, stages, observed, timed_out, error=None):
    manifest = strict_json(root / 'source-manifest-original.json')['files']
    frozen_code = True
    originals = True
    for file in manifest:
        relative = Path(file['path'])
        readme = relative.as_posix() == 'prototypes/gpui/README.md'
        vendor = len(relative.parts)>=5 and relative.parts[:3] == ('prototypes', 'gpui', 'vendor') and relative.parts[3] in CRATES
        if relative.is_absolute() or '..' in relative.parts or not (readme or vendor):
            raise ValueError('Compile source manifest escaped its frozen allow-list.')
        original, snapshot = REPO / relative, root / 'source' / relative
        originals &= original.is_file() and not original.is_symlink() and sha(original) == file['sha256']
        if relative.name != 'Cargo.lock':
            frozen_code &= snapshot.is_file() and not snapshot.is_symlink() and sha(snapshot) == file['sha256']
    root_versions = versions(root / 'root-pins-Cargo.lock')
    root_names = {name for name, _ in root_versions}
    locks = []
    for crate in CRATES:
        path = root / 'source/prototypes/gpui/vendor' / crate / 'Cargo.lock'
        actual = versions(path)
        locks.append({'crate':crate,'sha256':sha(path),
                      'rootPinVersionDrift':[name+'@'+version for name,version in sorted(actual-root_versions) if name in root_names],
                      'standaloneDevPackages':[name+'@'+version for name,version in sorted(actual-root_versions) if name not in root_names]})
    all_stages = len(stages)==3 and [s['crate'] for s in stages]==list(CRATES) and all(s['exitCode']==0 for s in stages)
    cleanup = not observed.get('present', True) and observed.get('daemonReachable', False)
    passed = (all_stages and frozen_code and cleanup and not timed_out and not error
              and all(not item['rootPinVersionDrift'] for item in locks))
    proof = dict(request, state='compile-completed', status='passed' if passed else 'failed',
                 finishedAt=now(), timedOut=timed_out, stages=stages, stagedCodeUnchanged=frozen_code,
                 originalFrozenSourcesUnchanged=originals, locks=locks, ownedContainerState=observed,
                 ownedContainerCleanupCompleted=cleanup, testsExecuted=False, nativeAcceptance='not-run')
    if error:
        proof['error'] = error
    write_json(root / 'completed.json', proof)
    print('Dependency unit-target compile '+proof['status']+'; proof: '+str(root/'completed.json'), flush=True)
    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True)
    parser.add_argument('--deadline-seconds', type=int, default=1200)
    args = parser.parse_args()
    if not re.fullmatch(r'task30-platform-units-[0-9a-f]{32}', args.run) or not 1 <= args.deadline_seconds <= 1800:
        raise ValueError('Invalid owned compile request.')
    root = REPO / 'build/gpui' / args.run
    if root.is_symlink() or root.resolve().parent != (REPO / 'build/gpui').resolve():
        raise ValueError('Invalid owned compile root.')
    request = strict_json(root / 'request.json')
    nonce = args.run.removeprefix('task30-platform-units-')
    if request['nonce'] != nonce or request['containerName'] != 'dbeer-task30-platform-units-'+nonce or request['testsExecuted'] is not False:
        raise ValueError('Compile ownership mismatch.')
    cid = (root / 'compile.cid').read_text().strip()
    if not re.fullmatch('[0-9a-f]{64}', cid):
        raise ValueError('Missing exact owned compile container ID.')
    write_json(root / 'watcher-request.json', {'schemaVersion':1,'startedAt':now(),'deadlineSeconds':args.deadline_seconds,
                                              'containerId':cid,'nonce':nonce,'testsExecuted':False})
    print('Owned compile proof watcher started; bounded metadata/cleanup only.', flush=True)
    deadline = time.monotonic()+args.deadline_seconds
    stages, observed, error = [], {}, None
    timed_out = False
    while True:
        try:
            if (root / 'stages.json').exists():
                try:
                    stages = strict_json(root / 'stages.json')
                except json.JSONDecodeError:
                    pass  # Writer may be between truncate and write; never accept it.
            observed = state(cid)
            if observed.get('present') and observed.get('owner') != nonce:
                error = 'Container ownership changed; foreign cleanup refused.'
                break
            if not observed.get('present'):
                if not observed.get('daemonReachable'):
                    error = 'Docker became unavailable; cleanup cannot be verified.'
                break
            if time.monotonic() >= deadline:
                timed_out = True
                # Exact recorded ID + checked nonce only. Never names, groups,
                # foreign PIDs or Docker prune. --rm removes this owned container.
                stopped = subprocess.run(['docker','stop','--time','30',cid], stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, timeout=45, check=False)
                observed = state(cid)
                if stopped.returncode:
                    error = 'Owned compile stop did not complete.'
                break
            time.sleep(5)
        except (OSError, ValueError, subprocess.SubprocessError):
            error = 'Compile metadata observation failed; no completion accepted.'
            break
    return finish(root, request, stages, observed, timed_out, error)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print('Compile proof finalization failed; no acceptance granted.', flush=True)
        raise SystemExit(2)
