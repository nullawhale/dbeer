//go:build !windows

package exportfile

import (
	"context"
	"dbeer/helper/internal/protocol"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestDestinationFIFOParentIsRejectedWithoutBlockingAndSymlinkParentWorks(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "fifo")
	if syscall.Mkfifo(fifo, 0600) != nil {
		t.Fatal("cannot create destination FIFO fixture")
	}
	rejected := make(chan bool, 1)
	go func() {
		_, err := CaptureDestinationContext(context.Background(), filepath.Join(fifo, "backup.dump"))
		rejected <- err != nil
	}()
	select {
	case invalid := <-rejected:
		if !invalid {
			t.Fatal("FIFO parent was accepted as a directory")
		}
	case <-time.After(time.Second):
		writer, _ := os.OpenFile(fifo, os.O_RDWR|syscall.O_NONBLOCK, 0)
		if writer != nil {
			writer.Close()
		}
		select {
		case <-rejected:
		case <-time.After(time.Second):
		}
		t.Fatal("destination FIFO parent blocked preparation")
	}
	actual := filepath.Join(dir, "actual")
	alias := filepath.Join(dir, "alias")
	if os.Mkdir(actual, 0700) != nil || os.Symlink(actual, alias) != nil {
		t.Fatal("cannot create symlink parent fixture")
	}
	if _, err := CaptureDestination(filepath.Join(alias, "backup.dump")); err != nil {
		t.Fatal("legitimate symlink directory parent was rejected")
	}
}

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
