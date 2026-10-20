#!/usr/bin/env python3
"""Remove disposable GPUI outputs while retaining local verification evidence."""

import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile


KEEP_DIRECTORIES = {
    "candidate", "candidates", "release", "releases", "archive", "archives",
    "report", "reports", "logs", "qa", "toolchain", "fixtures", "source", "src",
}
KEEP_SUFFIXES = {
    ".log", ".md", ".txt", ".json", ".jsonl", ".ndjson", ".csv", ".tsv",
    ".yaml", ".yml", ".html", ".htm", ".xml", ".pdf", ".png", ".jpg",
    ".jpeg", ".gif", ".webp", ".svg", ".diff", ".patch", ".sha256",
    ".zip", ".tar", ".gz", ".tgz", ".xz", ".bz2", ".7z", ".crate",
}
CACHE_NAMES = {
    "go-cache", "swift-cache", "swift-modules", "module-cache", "modules",
    "__pycache__", "task30-pycache",
}
OUTPUT_NAMES = {"debug", "release", "tmp", "out", "artifacts", "checkouts", "repositories"}
BINARY_MAGIC = {
    b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
}


def protected_directory(path, disposable=False):
    name = path.name.lower()
    if disposable and name in {"source", "src"}:
        # Downloaded dependency sources inside caches are reproducible inputs.
        return False
    return (name in KEEP_DIRECTORIES
            or name.startswith(("candidate-", "release-", "archive-"))
            or (name == "runtime" and path.parent.name == "powershell")
            or "fixtures" in name)


def protected_file(path):
    return (path.suffix.lower() in KEEP_SUFFIXES
            or any(word in path.name.lower() for word in ("snapshot", ".before", ".after")))


def identity(path):
    info = path.lstat()
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns)


def compiled_file(path):
    if path.suffix.lower() in {".rmeta", ".rlib", ".o", ".a"}:
        return True
    with path.open("rb") as stream:
        magic = stream.read(4)
    return magic in BINARY_MAGIC or magic[:2] == b"MZ"


def cleanup_plan(repo_root):
    """Return disjoint removable paths, never following directory or file links.

    Report/document/image and archive extensions survive even inside an output
    or cache directory. This deliberately leaves some dependency documentation
    and compiler JSON metadata behind rather than guessing which evidence matters.
    """
    base = repo_root / "build" / "gpui"
    for ancestor in (repo_root / "build", base):
        if ancestor.is_symlink():
            raise ValueError("Refusing a symlink at " + str(ancestor.relative_to(repo_root)))
    if not base.exists():
        return []
    if not base.is_dir():
        raise ValueError("build/gpui is not a directory")

    def visit(path, disposable=False, compiler_profile=False):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            return [], True
        if stat.S_ISREG(info.st_mode):
            if protected_file(path):
                return [], True
            if disposable or compiled_file(path):
                return [(path, identity(path), info.st_blocks * 512)], False
            return [], True
        if not stat.S_ISDIR(info.st_mode) or (protected_directory(path, disposable) and not compiler_profile):
            return [], True

        children = sorted(path.iterdir())
        names = {child.name for child in children}
        target = (".rustc_info.json" in names or
                  ("CACHEDIR.TAG" in names and bool(names & {"debug", "release", "out"})))
        cache = (path.name in CACHE_NAMES
                 or ("registry" in names and bool(names & {".package-cache", ".global-cache"}))
                 or (path.parent.name == ".cache" and path.name in {"go", "go-mod"})
                 or (path.name == "cache" and
                     (path.parent.name == "macos-compile"
                      or bool({sibling.name for sibling in path.parent.iterdir()}
                              & {"bin", "swiftpm", "scratch"}))))
        disposable = disposable or cache
        actions = []
        retained = False
        for child in children:
            # A target's release/ directory is an output, while any enclosing
            # releases/ or candidates/ directory remains completely protected.
            child_disposable = disposable or (target and (
                child.name in OUTPUT_NAMES or child.name.startswith(
                    ("x86_64-", "aarch64-", "arm64-", "i686-"))))
            child_actions, child_retained = visit(
                child, child_disposable, compiler_profile=target and child.name == "release")
            actions.extend(child_actions)
            retained = retained or child_retained
        if disposable and not retained:
            return [(path, identity(path), sum(item[2] for item in actions))], False
        return actions, True

    return visit(base)[0]


def validate_plan(repo_root, actions):
    base = repo_root / "build" / "gpui"
    for path, expected, _ in actions:
        if not path.is_relative_to(base) or path == base:
            raise ValueError("Cleanup path is outside build/gpui")
        current = path
        while current != repo_root:
            if current.is_symlink():
                raise ValueError("Cleanup path contains a symlink: " + str(path.relative_to(repo_root)))
            current = current.parent
        if identity(path) != expected:
            raise ValueError("Cleanup path changed; rerun the preview: " + str(path.relative_to(repo_root)))


def remove_readonly(function, path, error):
    if not isinstance(error[1], PermissionError):
        raise error[1]
    # Go's downloaded module directories may be read-only. Retained report
    # files keep their bytes and modes; their enclosing cache may need write access.
    parent = Path(path).parent
    parent.chmod(parent.stat().st_mode | stat.S_IRWXU)
    if Path(path).is_dir() and not Path(path).is_symlink():
        Path(path).chmod(Path(path).stat().st_mode | stat.S_IRWXU)
    function(path)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Clean GPUI outputs only. Preview is the default; stop GPUI builds first.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="delete the previewed kinds of outputs")
    mode.add_argument("--dry-run", action="store_true", help="preview without writing files (default)")
    parser.add_argument("--verbose", action="store_true", help="list every removable path")
    args = parser.parse_args(argv)
    repo_root = Path(__file__).resolve().parent.parent
    try:
        actions = cleanup_plan(repo_root)
        total = sum(item[2] for item in actions)
        print("GPUI cleanup: " + ("apply" if args.apply else "dry run"))
        for path, _, size in actions if args.verbose else actions[:40]:
            print("  {} ({:.1f} MiB)".format(path.relative_to(repo_root), size / 1024**2))
        if len(actions) > 40 and not args.verbose:
            print("  ... {} more paths; use --verbose for the full list.".format(len(actions) - 40))
        print("{} paths, {:.2f} GiB of allocated file blocks (shared blocks may reduce disk savings).".format(
            len(actions), total / 1024**3))
        if not args.apply:
            print("Run ./scripts/clean-gpui.sh --apply to delete these outputs.")
            return 0
        if not actions:
            print("Nothing to remove.")
            return 0
        validate_plan(repo_root, actions)
        maintenance = repo_root / "build" / "maintenance"
        if maintenance.is_symlink():
            raise ValueError("Refusing a symlink at build/maintenance")
        maintenance.mkdir(exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", prefix="gpui-cleanup-", suffix=".json",
                                         dir=maintenance, delete=False) as stream:
            manifest = Path(stream.name)
            json.dump({"paths": [str(p.relative_to(repo_root)) for p, _, _ in actions],
                       "allocated_bytes": total}, stream, indent=2)
            stream.write("\n")
        for action in actions:
            validate_plan(repo_root, [action])
            path = action[0]
            if path.is_dir():
                shutil.rmtree(path, onerror=remove_readonly)
            else:
                try:
                    path.unlink()
                except PermissionError:
                    remove_readonly(os.unlink, str(path), sys.exc_info())
        print("Removed {} paths. Manifest: {}".format(len(actions), manifest.relative_to(repo_root)))
        return 0
    except (OSError, ValueError) as error:
        print("GPUI cleanup failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
