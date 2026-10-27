//go:build darwin || linux

package mcpbridge

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

func socketPath() string {
	return fmt.Sprintf("/tmp/dev.dbeer.agent-%d/broker.sock", os.Getuid())
}

func securePath(path string, uid uint32) bool {
	dir, err := os.Lstat(filepath.Dir(path))
	if err != nil || !dir.IsDir() || dir.Mode().Perm() != 0700 {
		return false
	}
	parent, ok := dir.Sys().(*syscall.Stat_t)
	if !ok || parent.Uid != uid {
		return false
	}
	file, err := os.Lstat(path)
	if err != nil || file.Mode()&os.ModeSocket == 0 || file.Mode().Perm() != 0600 {
		return false
	}
	stat, ok := file.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uid
}

func dialBroker(ctx context.Context) (net.Conn, error) {
	path := socketPath()
	if !securePath(path, uint32(os.Getuid())) {
		return nil, errUnavailable
	}
	dialer := net.Dialer{Timeout: time.Second}
	conn, err := dialer.DialContext(ctx, "unix", path)
	if err != nil {
		return nil, errUnavailable
	}
	unixConn, ok := conn.(*net.UnixConn)
	if !ok || !sameUser(unixConn) {
		_ = conn.Close()
		return nil, errUnavailable
	}
	return conn, nil
}
