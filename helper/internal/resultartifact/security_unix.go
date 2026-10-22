//go:build darwin || linux

package resultartifact

import (
	"errors"
	"io"
	"os"
	"syscall"
)

// Open a nofollow descriptor first, then verify that os.Root pinned that same
// inode. Every operation below is relative to an already pinned directory.
func openManagedRoot(path string) (*os.Root, error) {
	pin, err := os.OpenFile(path, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer pin.Close()
	info, err := pin.Stat()
	if err != nil || !ownedDirectory(info) {
		return nil, ErrUnavailable
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, ErrUnavailable
	}
	if err := verifyDirectory(root, info); err != nil {
		root.Close()
		return nil, ErrUnavailable
	}
	return root, nil
}

func openArtifactDirectory(root *os.Root, id string) (*os.Root, error) {
	before, err := root.Lstat(id)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotFound
		}
		return nil, ErrCorrupt
	}
	if !ownedDirectory(before) {
		return nil, ErrCorrupt
	}
	pin, err := root.OpenFile(id, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotFound
		}
		return nil, ErrCorrupt
	}
	defer pin.Close()
	info, err := pin.Stat()
	if err != nil || !ownedDirectory(info) || !os.SameFile(before, info) {
		return nil, ErrCorrupt
	}
	directory, err := root.OpenRoot(id)
	if err != nil {
		return nil, ErrCorrupt
	}
	if err := verifyDirectory(directory, info); err != nil {
		directory.Close()
		return nil, err
	}
	// os.Root follows contained links in user space even when O_NOFOLLOW is
	// present. Lstat before and after opening, plus the pinned inode comparison,
	// rejects both static links and a replacement with a different directory.
	after, err := root.Lstat(id)
	if err != nil || !ownedDirectory(after) || !os.SameFile(info, after) {
		directory.Close()
		return nil, ErrCorrupt
	}
	return directory, nil
}

func verifyDirectory(directory *os.Root, pin os.FileInfo) error {
	file, err := directory.OpenFile(".", os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return ErrCorrupt
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !ownedDirectory(info) || !os.SameFile(pin, info) {
		return ErrCorrupt
	}
	return nil
}

func ownedDirectory(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && info.IsDir() && stat.Uid == uint32(os.Geteuid()) && info.Mode().Perm()&0022 == 0
}

func ownedRegular(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && info.Mode().IsRegular() && stat.Uid == uint32(os.Geteuid()) && stat.Nlink == 1 && info.Size() >= 0 && info.Mode().Perm()&0022 == 0
}

func openRegular(directory *os.Root, name string) (*os.File, os.FileInfo, error) {
	before, err := directory.Lstat(name)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil, ErrNotFound
		}
		return nil, nil, ErrCorrupt
	}
	if !ownedRegular(before) {
		return nil, nil, ErrCorrupt
	}
	file, err := directory.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil, ErrNotFound
		}
		return nil, nil, ErrCorrupt
	}
	info, err := file.Stat()
	if err != nil || !ownedRegular(info) || !sameRegular(before, info) {
		file.Close()
		return nil, nil, ErrCorrupt
	}
	after, err := directory.Lstat(name)
	if err != nil || !ownedRegular(after) || !sameRegular(info, after) {
		file.Close()
		return nil, nil, ErrCorrupt
	}
	return file, info, nil
}

func checkArtifactEntries(directory *os.Root) error {
	file, err := directory.OpenFile(".", os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return ErrCorrupt
	}
	defer file.Close()
	names, err := file.Readdirnames(3)
	if err != nil && err != io.EOF || len(names) != 2 {
		return ErrCorrupt
	}
	if !(names[0] == "manifest.json" && names[1] == "rows.jsonl" || names[0] == "rows.jsonl" && names[1] == "manifest.json") {
		return ErrCorrupt
	}
	return nil
}

// ctime cannot be restored with Chtimes. Together with mtime, size, ownership,
// link count, inode, and the stream/row digests this rejects in-place mutation
// and replacement after validation without copying a potentially 1 GiB file.
func unchanged(file *os.File, before os.FileInfo) error {
	after, err := file.Stat()
	if err != nil || !ownedRegular(after) || !sameRegular(before, after) {
		return ErrCorrupt
	}
	return nil
}

func sameRegular(before, after os.FileInfo) bool {
	return os.SameFile(before, after) && before.Size() == after.Size() && before.Mode() == after.Mode() &&
		before.ModTime().Equal(after.ModTime()) && changeTime(before) == changeTime(after)
}
