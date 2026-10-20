#!/usr/bin/env python3
"""Reversible per-user desktop integration for an already extracted DBeer package."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

APP_ID = 'app.dbeer.DBeer'


class Refused(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def bounded_file(path, limit):
    with safe_path(path).open('rb') as source:
        data = source.read(limit+1)
    if len(data) > limit:
        raise Refused('Oversized integration file.')
    return data


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise Refused('Duplicate integration ownership field.')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs)


def safe_path(path, *, directory=False, missing=False):
    path = Path(os.path.abspath(path))
    if any(character in str(path) for character in '\0\r\n'):
        raise Refused('Unsupported integration path.')
    for part in [*reversed(path.parents), path]:
        try:
            entry = part.lstat()
        except FileNotFoundError:
            if missing:
                continue
            raise Refused('Required integration file is missing.') from None
        if stat.S_ISLNK(entry.st_mode):
            raise Refused('Integration paths must not contain symlinks.')
        if part != path and not stat.S_ISDIR(entry.st_mode):
            raise Refused('Integration parent is not a directory.')
    if path.exists() and (directory != path.is_dir() or (not directory and not path.is_file())):
        raise Refused('Unexpected integration path type.')
    return path


def desktop_exec(executable):
    # Desktop Entry string escaping is applied after Exec argument escaping.
    text = str(executable)
    if any(character in text for character in '\0\r\n'):
        raise Refused('Unsupported executable path.')
    text = ''.join('\\' + c if c in '\\"$`' else '%%' if c == '%' else c for c in text)
    return '"' + text.replace('\\', '\\\\') + '"'


def desktop_bytes(package):
    executable = safe_path(package / 'dbeer-gpui')
    return ('[Desktop Entry]\nType=Application\nName=DBeer\n'
            'Comment=SQL client for PostgreSQL and MySQL\n'
            f'Exec={desktop_exec(executable)}\nIcon={APP_ID}\n'
            'Terminal=false\nCategories=Development;Database;\n'
            f'StartupWMClass={APP_ID}\nStartupNotify=true\n').encode('utf-8')


def owned_create(path, data, mode):
    safe_path(path.parent, directory=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    identity = os.fstat(descriptor)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        if not same_file_identity(identity, path.stat(follow_symlinks=False)):
            raise Refused('Integration changed during publication.')
        return identity
    except BaseException:
        if path.exists() and not path.is_symlink() and same_file_identity(identity, path.stat(follow_symlinks=False)):
            path.unlink()
        raise


def same_file_identity(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def paths_for(root):
    return {
        'desktop': root / 'applications' / f'{APP_ID}.desktop',
        'icon': root / 'icons' / 'hicolor' / 'scalable' / 'apps' / f'{APP_ID}.svg',
        'manifest': root / 'dbeer-integration' / f'{APP_ID}.json',
    }


def prepare_directory(path):
    safe_path(path, directory=True, missing=True)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    safe_path(path, directory=True)


def install(package, root):
    package = safe_path(package, directory=True)
    root = safe_path(root, directory=True, missing=True)
    paths = paths_for(root)
    if any(path.exists() or path.is_symlink() for path in paths.values()):
        raise Refused('Existing integration files are preserved. Remove owned integration before updating.')
    icon = bounded_file(package / 'icons' / f'{APP_ID}.svg', 2*1024*1024)
    payloads = {'desktop': desktop_bytes(package), 'icon': icon}
    created = []
    try:
        entries = []
        for kind in ['icon', 'desktop']:
            path = paths[kind]
            prepare_directory(path.parent)
            identity = owned_create(path, payloads[kind], 0o644)
            created.append((path, identity, payloads[kind]))
            entries.append({'kind': kind, 'sha256': digest(payloads[kind]),
                            'device': identity.st_dev, 'inode': identity.st_ino})
        manifest = {'version': 1, 'productId': APP_ID, 'files': entries}
        data = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
        prepare_directory(paths['manifest'].parent)
        identity = owned_create(paths['manifest'], data, 0o600)
        created.append((paths['manifest'], identity, data))
    except BaseException:
        for path, identity, data in reversed(created):
            if (path.exists() and not path.is_symlink()
                    and same_file_identity(identity, path.stat(follow_symlinks=False))
                    and path.read_bytes() == data):
                path.unlink()
        raise


def remove(root):
    paths = paths_for(safe_path(root, directory=True))
    manifest_path = safe_path(paths['manifest'])
    manifest_identity = manifest_path.stat(follow_symlinks=False)
    if manifest_identity.st_size > 16 * 1024:
        raise Refused('Invalid integration ownership manifest.')
    manifest_bytes = bounded_file(manifest_path, 16*1024)
    try:
        manifest = strict_json(manifest_bytes)
    except (ValueError, UnicodeError):
        raise Refused('Invalid integration ownership manifest.') from None
    if (not isinstance(manifest, dict) or set(manifest) != {'version', 'productId', 'files'} or manifest['version'] != 1
            or type(manifest['version']) is not int
            or manifest['productId'] != APP_ID or not isinstance(manifest['files'], list)
            or len(manifest['files']) != 2):
        raise Refused('Invalid integration ownership manifest.')
    captured = []
    kinds = set()
    for item in manifest['files']:
        if (not isinstance(item, dict) or set(item) != {'kind', 'sha256', 'device', 'inode'}
                or item['kind'] not in {'desktop', 'icon'} or item['kind'] in kinds):
            raise Refused('Invalid integration ownership manifest.')
        kinds.add(item['kind'])
        path = safe_path(paths[item['kind']])
        identity = path.stat(follow_symlinks=False)
        if (identity.st_dev != item['device'] or identity.st_ino != item['inode']
                or identity.st_size > 2 * 1024 * 1024 or digest(path.read_bytes()) != item['sha256']):
            raise Refused('Changed or unrelated integration files are preserved.')
        captured.append((path, identity, item['sha256']))
    # Preflight all entries before deleting anything. Never removes the package,
    # credential service, user data, parent directories or any unlisted path.
    captured.append((manifest_path, manifest_identity, digest(manifest_bytes)))
    for path, identity, expected in captured:
        safe_path(path)
        if not same_file_identity(identity, path.stat(follow_symlinks=False)) or digest(path.read_bytes()) != expected:
            raise Refused('Integration changed during removal; remaining files are preserved.')
        path.unlink()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'remove'])
    parser.add_argument('--data-home', type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() == 0:
        raise Refused('Run per-user integration as a standard user on Linux.')
    configured = os.environ.get('XDG_DATA_HOME', '')
    root = args.data_home or (Path(configured) if configured.startswith('/') else Path.home() / '.local/share')
    if not root.is_absolute():
        raise Refused('The integration directory must be absolute.')
    if args.action == 'install':
        install(Path(__file__).absolute().parent, root)
    else:
        remove(root)
    print('DBeer desktop integration ' + ('installed.' if args.action == 'install' else 'removed.'))


if __name__ == '__main__':
    try:
        main()
    except (Refused, OSError, ValueError, KeyError, TypeError):
        print('DBeer desktop integration was refused; existing files and user data are preserved.', file=sys.stderr)
        sys.exit(2)
