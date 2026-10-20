"""Held exact owned file receipts. No arbitrary paths, deletion or fault injection."""
from __future__ import annotations
import os
import re
from core import Pending, Refused, digest_bytes, native, safe

FILES = {'connections': 'connections.json', 'workspace': 'workspace.json',
         'appearance': 'appearance.json', 'themes': 'themes.json', 'shortcuts': 'shortcuts.json',
         'connections-v1-backup': 'connections.json.v1.backup'}
UUID = r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
BACKUPS = {
    'connections': re.compile(r'connections\.json\.v1(?:-' + UUID + r')?\.backup\Z'),
    'workspace': re.compile(r'workspace\.json\.v0(?:-' + UUID + r')?\.backup\Z'),
    'themes': re.compile(r'themes-recovery-' + UUID + r'\.json\Z'),
    'shortcuts': re.compile(r'shortcuts-recovery-' + UUID + r'\.json\Z'),
}


def open_read(path, *, block_replacement=False):
    if os.name != 'nt':
        if block_replacement:
            raise Pending('Deny-sharing publication barrier requires native Windows.')
        return os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    import ctypes
    from ctypes import wintypes
    import msvcrt
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    create = kernel.CreateFileW
    create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                       wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    create.restype = wintypes.HANDLE
    # Receipts allow the app's explicit atomic replacement. A separate fault
    # barrier denies write/delete sharing only on the held exact owned file.
    handle = create(str(path), 0x80000000, 1 if block_replacement else 7, None, 3, 0x00200000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise Refused('Exact owned Windows file handle could not be acquired.')
    try:
        return msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except Exception:
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle(handle)
        raise


class HeldFile:
    def __init__(self, root, key):
        self.root = safe(root, directory=True)
        self.key = key
        parent = self.root.stat()
        self.parent_identity = (parent.st_dev, parent.st_ino)
        self.prior_backups = self._backup_names()
        if key not in FILES:
            raise Refused('Only exact isolated persisted files may be captured.')
        self.path = safe(self.root / FILES[key])
        native.private_path(self.path)
        before = self.path.stat()
        self.descriptor = open_read(self.path)
        self.closed = False
        metadata = os.fstat(self.descriptor)
        self.identity = (metadata.st_dev, metadata.st_ino)
        if self.identity != (before.st_dev, before.st_ino):
            self.close()
            raise Refused('Original persisted file changed during capture.')
        try:
            self.expected = self._hash()
            self.assert_same()
        except Exception:
            self.close()
            raise

    def _backup_names(self):
        pattern = BACKUPS.get(self.key)
        entries = list(self.root.iterdir())
        if len(entries) > 256:
            raise Refused('Isolated persisted directory exceeds bounds.')
        return {item.name for item in entries if pattern and pattern.fullmatch(item.name)}

    def _hash(self):
        os.lseek(self.descriptor, 0, os.SEEK_SET)
        data = bytearray()
        while block := os.read(self.descriptor, 65536):
            data.extend(block)
            if len(data) > 64 * 1024 * 1024:
                raise Refused('Captured persisted file exceeds bounds.')
        return digest_bytes(data)

    def assert_same(self):
        if self.closed:
            raise Refused('Captured file handle has retired.')
        safe(self.root, directory=True)
        parent = self.root.stat()
        safe(self.path)
        current = self.path.stat()
        if (parent.st_dev, parent.st_ino) != self.parent_identity or (current.st_dev, current.st_ino) != self.identity:
            raise Refused('Original captured file was replaced; preserve replacement.')
        native.private_path(self.path)
        if self._hash() != self.expected:
            raise Refused('Original captured file bytes changed.')
        return {'sha256': self.expected, 'originalFileIdentityPreserved': True}

    def backup_matches(self, root, key):
        # Explicit recovery may publish a new original. The held original bytes
        # remain independent authority, but a backup must be an exact owned file.
        if root != self.root or self.closed or self._hash() != self.expected:
            raise Refused('Original retained backup source changed.')
        parent = safe(self.root, directory=True).stat()
        if (parent.st_dev, parent.st_ino) != self.parent_identity:
            raise Refused('Original backup parent changed.')
        backup = HeldFile(root, key)
        try:
            if backup.identity == self.identity or backup.expected != self.expected:
                raise Refused('Recovery backup is not a distinct exact original copy.')
            backup.assert_same()
            return {'sha256': self.expected, 'distinctOriginalBackupVerified': True}
        finally:
            backup.close()

    def discover_backup(self):
        """Discover only one NEW enumerated recovery copy in the original parent.

        Never adopt a pre-existing same-byte file or follow a guessed glob path.
        The replacement of the original is permitted only by the explicit app
        recovery; the held original handle remains the independent byte oracle.
        """
        if self.closed or self._hash() != self.expected:
            raise Refused('Original recovery source changed or retired.')
        parent = safe(self.root, directory=True).stat()
        if (parent.st_dev, parent.st_ino) != self.parent_identity:
            raise Refused('Original recovery parent changed.')
        added = self._backup_names() - self.prior_backups
        if len(added) != 1:
            raise Refused('Exactly one fresh original recovery backup is required.')
        path = safe(self.root / next(iter(added)))
        # Construct from the exact discovered name without broadening FILES.
        backup = HeldFile.__new__(HeldFile)
        backup.root, backup.key, backup.path = self.root, self.key, path
        backup.parent_identity, backup.closed = self.parent_identity, False
        native.private_path(path)
        metadata = path.stat()
        backup.descriptor = open_read(path)
        try:
            held = os.fstat(backup.descriptor)
            backup.identity = (held.st_dev, held.st_ino)
            backup.expected = backup._hash()
            if (backup.identity != (metadata.st_dev, metadata.st_ino) or backup.identity == self.identity
                    or backup.expected != self.expected):
                raise Refused('Fresh recovery backup differs from the exact original bytes.')
            backup.assert_same()
            return {'sha256': self.expected, 'distinctOriginalBackupVerified': True,
                    'freshRecoveryBackupVerified': True, 'backupFileIdentitySha256':
                    digest_bytes(str(backup.identity).encode())}
        finally:
            backup.close()

    def close(self):
        if not self.closed:
            os.close(self.descriptor)
            self.closed = True


class ReplacementBarrier:
    """Native Windows deny-write/delete sharing on one original held file.

    This cannot simulate an ambiguous publication or lock a credential store.
    It never creates a lock file or modifies permissions/global store state.
    """
    def __init__(self, original):
        original.assert_same()
        self.original, self.descriptor, self.closed = original, None, False
        self.descriptor = open_read(original.path, block_replacement=True)
        try:
            metadata = os.fstat(self.descriptor)
            if (metadata.st_dev, metadata.st_ino) != original.identity:
                raise Refused('Publication lock did not capture the original exact file.')
            original.assert_same()
        except Exception:
            self.close()
            raise

    def verify(self):
        if self.closed or self.descriptor is None:
            raise Refused('Original publication barrier has retired.')
        metadata = os.fstat(self.descriptor)
        if (metadata.st_dev, metadata.st_ino) != self.original.identity:
            raise Refused('Publication barrier original handle changed.')
        return {**self.original.assert_same(), 'nativeDenyWriteDeleteSharingHeld': True}

    def close(self):
        if not self.closed:
            if self.descriptor is not None:
                os.close(self.descriptor)
            self.closed = True
