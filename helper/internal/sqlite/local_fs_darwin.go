//go:build darwin

package sqlite

import "golang.org/x/sys/unix"

func localFilesystem(path string) bool {
	var info unix.Statfs_t
	return unix.Statfs(path, &info) == nil && info.Flags&unix.MNT_LOCAL != 0
}
