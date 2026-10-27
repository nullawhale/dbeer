// Package credential resolves a fresh password for each physical connection.
package credential

import (
	"context"
	"io"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

const Timeout = 15 * time.Second
const MaxOutput = 64 * 1024

func failure(message string) error {
	return &adapter.ConnectionError{Category: "credential", Message: message}
}

// Password never retains output beyond this connection attempt. Processes get
// no stdin; argv is passed literally and no shell or SQL retry is introduced.
func Password(ctx context.Context, connection protocol.Connection) (string, error) {
	if connection.PasswordCommand == nil {
		return connection.Password, nil
	}
	command := connection.PasswordCommand
	if !command.Valid() || connection.Password != "" {
		return "", failure("The password command settings are invalid.")
	}
	return run(ctx, *command, Timeout)
}

type output struct {
	bytes    []byte
	cancel   context.CancelFunc
	exceeded bool
}

func (out *output) Write(value []byte) (int, error) {
	if len(value) > MaxOutput-len(out.bytes) {
		out.exceeded = true
		out.cancel()
		return 0, io.ErrShortWrite
	}
	out.bytes = append(out.bytes, value...)
	return len(value), nil
}

func run(ctx context.Context, command protocol.PasswordCommand, timeout time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if ctx.Err() != nil {
		return "", failure("The password command was cancelled or timed out.")
	}
	out := &output{cancel: cancel}
	cmd := exec.CommandContext(ctx, command.Executable, command.Arguments...)
	cmd.Stdout, cmd.Stderr = out, io.Discard
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	// A descendant retaining a pipe must never hold up cancellation or shutdown.
	cmd.WaitDelay = time.Second
	if err := cmd.Start(); err != nil {
		return "", failure("The password command could not be started.")
	}
	err := cmd.Wait()
	// Also reap descendants when the executable exits normally or fails early.
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	defer clear(out.bytes)
	if out.exceeded {
		return "", failure("The password command exceeded the 64 KiB output limit.")
	}
	if ctx.Err() != nil {
		return "", failure("The password command was cancelled or timed out.")
	}
	if err != nil {
		return "", failure("The password command failed. Check its local configuration.")
	}
	value := strings.TrimSuffix(string(out.bytes), "\n")
	if len(value) != len(out.bytes) {
		value = strings.TrimSuffix(value, "\r")
	}
	if value == "" || !utf8.ValidString(value) || strings.ContainsAny(value, "\r\n\x00") {
		return "", failure("The password command must return one nonempty UTF-8 value.")
	}
	return value, nil
}
