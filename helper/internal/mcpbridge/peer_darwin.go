package mcpbridge

import (
	"net"
	"os"

	"golang.org/x/sys/unix"
)

func sameUser(conn *net.UnixConn) bool {
	raw, err := conn.SyscallConn()
	if err != nil {
		return false
	}
	valid := false
	if raw.Control(func(fd uintptr) {
		credential, err := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		valid = err == nil && credential.Uid == uint32(os.Getuid())
	}) != nil {
		return false
	}
	return valid
}
