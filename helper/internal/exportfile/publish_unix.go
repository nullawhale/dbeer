//go:build !windows

package exportfile

import (
	"fmt"
	"os"
	"syscall"
)

func (d *destination) lock() error {
	if d.file == nil {
		return nil
	}
	return syscall.Flock(int(d.file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
}

func createTemporary(parent string) (*os.File, error) {
	return os.CreateTemp(parent, ".dbeer-export-*")
}
func openDestination(path string) (*os.File, error) { return os.Open(path) }
func (d *destination) publish(temporary string) error {
	if !d.valid() {
		return ErrIO
	}
	if d.info != nil {
		if d.info.Mode().Perm()&0200 == 0 {
			return ErrIO
		}
		// Retain the existing destination's permissions; private temporaries stay 0600 until publication.
		if os.Chmod(temporary, d.info.Mode().Perm()) != nil {
			return ErrIO
		}
		return os.Rename(temporary, d.path)
	}
	// Link is an atomic no-replace publication on this same filesystem. Never delete a destination.
	if err := os.Link(temporary, d.path); err != nil {
		return err
	}
	_ = os.Remove(temporary)
	return nil
}

func fileIdentity(file *os.File) (string, error) {
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", ErrIO
	}
	return fmt.Sprintf("%d:%d", uint64(stat.Dev), stat.Ino), nil
}
