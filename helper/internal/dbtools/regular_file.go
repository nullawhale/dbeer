package dbtools

import (
	"errors"
	"os"
	"syscall"
)

// Opening a FIFO for reading can block before fstat or context cancellation is
// possible. O_NONBLOCK permits checking the opened object safely; it has no
// effect on regular-file reads. Symlinks remain supported and are pinned by fd.
func openReadonlyRegular(path string) (*os.File, os.FileInfo, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, nil, err
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		file.Close()
		if err == nil {
			err = errors.New("A regular file is required.")
		}
		return nil, nil, err
	}
	return file, info, nil
}
