//go:build !windows

package exportfile

import (
	"dbeer/helper/internal/protocol"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestCooperativeDestinationLockAndSymlinkAreRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "locked.json")
	_ = os.WriteFile(path, []byte("keep"), 0600)
	locked, err := os.Open(path)
	if err != nil {
		t.Fatal("fixture")
	}
	defer locked.Close()
	if syscall.Flock(int(locked.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		t.Fatal("fixture lock")
	}
	if _, err := New(protocol.ExportRequest{Path: path, Format: "json"}); err == nil {
		t.Fatal("locked destination accepted")
	}
	link := path + "-link"
	_ = os.Symlink(path, link)
	if _, err := New(protocol.ExportRequest{Path: link, Format: "json"}); err == nil {
		t.Fatal("symlink destination accepted")
	}
	unchanged(t, path)
}
