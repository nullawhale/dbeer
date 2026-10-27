#!/usr/bin/env python3
"""Stage only frozen public platform sources/cache for a compile-only container."""
import hashlib
import json
from pathlib import Path
import shutil
import uuid

from run import REPO, private_directory, sha, write_json

SOURCES = ('prototypes/gpui/vendor/gpui-base', 'prototypes/gpui/vendor/gpui-component',
           'prototypes/gpui/vendor/gpui-pre', 'prototypes/gpui/vendor/gpui-pre-linux',
           'prototypes/gpui/verification/platform-harness')


def main():
    nonce = uuid.uuid4().hex
    root = REPO / 'build/gpui' / ('task30-platform-' + nonce)
    private_directory(root)
    source = root / 'source'
    private_directory(source)
    manifest = []
    for relative in SOURCES:
        directory = REPO / relative
        for path in sorted(directory.rglob('*')):
            inner = path.relative_to(directory)
            if any(part in ('.git', 'target', 'build', '__pycache__') for part in inner.parts):
                continue
            if path.is_symlink():
                raise ValueError('Platform staging refuses source symlinks.')
            if not path.is_file():
                continue
            destination = source / relative / inner
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
            manifest.append({'path': destination.relative_to(source).as_posix(), 'sha256': sha(path)})
    # gpui-base's actual lib-test includes the public parent README.
    readme = REPO / 'prototypes/gpui/README.md'
    destination = source / readme.relative_to(REPO)
    shutil.copyfile(readme, destination)
    manifest.append({'path': destination.relative_to(source).as_posix(), 'sha256': sha(readme)})
    build = root / 'build'
    private_directory(build)
    cache = build / 'cargo/registry'
    # The public crates.io cache/index only. Never copy Cargo config, tokens,
    # credentials.toml, a user's HOME, source checkouts or private registry dirs.
    for kind in ('cache', 'index'):
        original = REPO / 'build/gpui/cargo/registry' / kind / 'index.crates.io-1949cf8c6b5b557f'
        if original.is_dir() and not original.is_symlink():
            destination = cache / kind / original.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            for path in original.rglob('*'):
                relative = path.relative_to(original)
                linked_ancestor = any(parent.is_symlink() for parent in [path, *path.parents]
                                      if parent == original or original in parent.parents)
                if linked_ancestor or any(p == '.git' or p.startswith('credentials') or p == 'config.toml' for p in relative.parts):
                    continue
                if not path.is_file():
                    continue
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
    source_digest = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    write_json(root / 'source-manifest.json', {'files': manifest, 'sha256': source_digest})
    request = {'schemaVersion':1, 'nonce':nonce, 'state':'prepared-compile-only', 'imageTag':'dbeer-task30-ubuntu24-x64:0282e61aa8114cdda118b5dbab00e2ac',
               'imageId':'sha256:8a3bf109710797f6b79ffd396e0c100a90ca4c07ca8195fbf13959da960d29df',
               'containerName':'dbeer-task30-platform-' + nonce, 'label':'app.dbeer.task30-run=' + nonce,
               'target':'linux/amd64', 'hostDaemon':'linux/arm64', 'emulated':True, 'jobs':2,
               'scope':'Actual frozen gpui-pre/base/component/pre-linux dependency branches; not the full application or native desktop acceptance',
               'sourceSha256':source_digest, 'testsExecuted':False, 'nativeAcceptance':'not-run'}
    write_json(root / 'request.json', request)
    print(json.dumps({'root':str(root),'nonce':nonce,'containerName':request['containerName'],'sourceSha256':source_digest}))


if __name__ == '__main__':
    main()
