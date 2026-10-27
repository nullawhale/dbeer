//go:build darwin || linux

package mcpbridge

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestSocketSecurityRejectsPermissiveAndSymlinkPaths(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "dbeer-mcp-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "broker.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	uid := uint32(os.Getuid())
	if !securePath(path, uid) || securePath(path, uid+1) {
		t.Fatal("socket owner check failed")
	}
	if err := os.Chmod(path, 0660); err != nil {
		t.Fatal(err)
	}
	if securePath(path, uid) {
		t.Fatal("permissive socket accepted")
	}
	_ = os.Chmod(path, 0600)
	_ = os.Chmod(dir, 0755)
	if securePath(path, uid) {
		t.Fatal("permissive parent accepted")
	}
	_ = os.Chmod(dir, 0700)
	link := filepath.Join(dir, "linked.sock")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if securePath(link, uid) {
		t.Fatal("socket symlink accepted")
	}
	parentLink := dir + "-link"
	if err := os.Symlink(dir, parentLink); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(parentLink) })
	if securePath(filepath.Join(parentLink, "broker.sock"), uid) {
		t.Fatal("parent symlink accepted")
	}
	go func() {
		connection, err := listener.Accept()
		if err == nil {
			defer connection.Close()
			if !sameUser(connection.(*net.UnixConn)) {
				t.Error("matching peer rejected")
			}
		}
	}()
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if !sameUser(connection.(*net.UnixConn)) {
		t.Fatal("matching broker uid rejected")
	}
}
