package dbtools

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

func UtilityExitCode(err error) int {
	if err == nil {
		return 0
	}
	var exited *exec.ExitError
	if errors.As(err, &exited) {
		if code := exited.ExitCode(); code >= 0 && code <= 255 {
			return code
		}
		if status, ok := exited.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return 128 + int(status.Signal())
		}
	}
	return 1
}

// RunUtility is dispatched before the framed protocol. The supervisor remains
// alive after an abrupt helper exit and reaps only its private utility group.
func RunUtility(args []string) (bool, error) {
	if len(args) == 0 || args[0] != "--dbtools-watchdog" {
		return false, nil
	}
	if len(args) < 2 || !filepath.IsAbs(args[1]) {
		return true, errors.New("Invalid database utility supervision request.")
	}
	switch filepath.Base(args[1]) {
	case "pg_dump", "pg_restore", "psql", "mysqldump", "mysql", "mariadb-dump", "mariadb":
	default:
		return true, errors.New("Invalid database utility.")
	}
	life := os.NewFile(3, "database-tool-lifetime")
	if life == nil {
		return true, errors.New("Database utility supervision is unavailable.")
	}
	defer life.Close()
	syscall.CloseOnExec(3)
	cmd := exec.Command(args[1], args[2:]...)
	cmd.Env, cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Environ(), os.Stdin, os.Stdout, io.Discard
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	if cmd.Start() != nil {
		return true, errors.New("The database utility could not start.")
	}
	defer syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	exit := make(chan error, 1)
	go func() { exit <- cmd.Wait() }()
	lost := make(chan struct{})
	go func() { io.Copy(io.Discard, life); close(lost) }()
	select {
	case err := <-exit:
		return true, err
	case <-lost:
	case <-signals:
	}
	// Native clients handle SIGINT by cancelling their current server command.
	// Give that protocol recovery a short window before terminating the client.
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGINT)
	select {
	case err := <-exit:
		return true, err
	case <-time.After(700 * time.Millisecond):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		select {
		case err := <-exit:
			return true, err
		case <-time.After(500 * time.Millisecond):
		}
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		err := <-exit
		return true, err
	}
}
