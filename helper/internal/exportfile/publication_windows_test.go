//go:build windows

package exportfile

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestWindowsDenyDeleteSharingPreservesExistingDestination(t *testing.T) {
	path := filepath.Join(t.TempDir(), "locked.json")
	_ = os.WriteFile(path, []byte("keep"), 0600)
	writer := readyExport(t, path)
	name, _ := syscall.UTF16PtrFromString(path)
	handle, err := syscall.CreateFile(name, syscall.GENERIC_READ, syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING, 0, 0)
	if err != nil {
		t.Fatal("open fixture lock")
	}
	defer syscall.CloseHandle(handle)
	if writer.Commit() == nil {
		t.Fatal("locked destination replaced")
	}
	unchanged(t, path)
}
