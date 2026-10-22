package credential

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func command(executable string, arguments ...string) protocol.Connection {
	return protocol.Connection{PasswordCommand: &protocol.PasswordCommand{Executable: executable, Arguments: arguments}}
}

func TestPasswordOutputContract(t *testing.T) {
	for index, value := range []string{"token", "token\n", "token\r\n", "  literal '$HOME' ; $(echo hidden)  \n"} {
		password, err := Password(context.Background(), command("/usr/bin/printf", "%s", value))
		want := strings.TrimSuffix(strings.TrimSuffix(value, "\n"), "\r")
		if err != nil || password != want {
			t.Fatalf("output fixture %d rejected or changed (bytes=%d, error=%v)", index, len(password), err)
		}
	}
	path := filepath.Join(t.TempDir(), "output")
	for _, value := range []string{"", "\n", "\r\n", "token\n\n", "token\rtoken", "one\ntwo", "token\x00", "\xff"} {
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		_, err := Password(context.Background(), command("/bin/cat", path))
		if err == nil || strings.Contains(err.Error(), "token") {
			t.Fatal("invalid output was accepted or disclosed")
		}
	}
	for _, length := range []int{MaxOutput, MaxOutput + 1} {
		if err := os.WriteFile(path, []byte(strings.Repeat("t", length)), 0600); err != nil {
			t.Fatal(err)
		}
		value, err := Password(context.Background(), command("/bin/cat", path))
		if length == MaxOutput && (err != nil || len(value) != length) {
			t.Fatal("64 KiB value rejected")
		}
		if length > MaxOutput && err == nil {
			t.Fatal("oversize output accepted")
		}
	}
	started := time.Now()
	if _, err := Password(context.Background(), command("/usr/bin/yes", "sensitive-token")); err == nil || time.Since(started) > 3*time.Second {
		t.Fatal("unbounded output was not stopped promptly")
	}
}

func TestPasswordFreshValuesAndNoShell(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	c := command("/bin/cat", path)
	for _, value := range []string{"first token", "second token"} {
		if err := os.WriteFile(path, []byte(value+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		password, err := Password(context.Background(), c)
		if err != nil || password != value {
			t.Fatal("credential was not refreshed")
		}
	}
	marker := filepath.Join(t.TempDir(), "must-not-exist")
	literal := "$(touch " + marker + ")"
	password, err := Password(context.Background(), command("/usr/bin/printf", "%s", literal))
	if err != nil || password != literal {
		t.Fatal("argv was interpreted")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("a shell was invoked")
	}
	if password, err := Password(context.Background(), protocol.Connection{Password: "static"}); err != nil || password != "static" {
		t.Fatal("static credential changed")
	}
}

func TestPasswordErrorsNeverDiscloseOutputOrArguments(t *testing.T) {
	c := command("/bin/sh", "-c", "printf fixture-sensitive-output; printf fixture-sensitive-stderr >&2; exit 7")
	_, err := Password(context.Background(), c)
	var safe *adapter.ConnectionError
	if !errors.As(err, &safe) || safe.Category != "credential" || strings.Contains(err.Error(), "fixture-sensitive") {
		t.Fatal("unsafe provider error")
	}
	c = command("/synthetic/missing-sensitive-executable", "sensitive-argument")
	if _, err := Password(context.Background(), c); err == nil || strings.Contains(err.Error(), "sensitive") {
		t.Fatal("unsafe launch error")
	}
	c.Password = "must-not-fallback"
	if _, err := Password(context.Background(), c); err == nil {
		t.Fatal("ambiguous credentials accepted")
	}
}

func TestPasswordTimeoutAndCancellationReapDescendants(t *testing.T) {
	for _, timeout := range []bool{false, true} {
		root := t.TempDir()
		pidPath := filepath.Join(root, "child-pid")
		// The shell is an explicit executable in this fixture, never implicit.
		c := command("/bin/sh", "-c", "sleep 60 & echo $! > \"$1\"; wait", "credential-fixture", pidPath)
		ctx, cancel := context.WithCancel(context.Background())
		started := time.Now()
		done := make(chan error, 1)
		go func() {
			_, err := run(ctx, *c.PasswordCommand, 300*time.Millisecond)
			done <- err
		}()
		var pid int
		for time.Since(started) < 2*time.Second {
			data, _ := os.ReadFile(pidPath)
			pid, _ = strconv.Atoi(strings.TrimSpace(string(data)))
			if pid > 0 {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if !timeout {
			cancel()
		}
		if err := <-done; err == nil {
			t.Fatal("provider did not stop")
		}
		cancel()
		if pid == 0 || time.Since(started) > 3*time.Second {
			t.Fatal("provider cancellation was not bounded")
		}
		for syscall.Kill(pid, 0) == nil && time.Since(started) < 3*time.Second {
			time.Sleep(10 * time.Millisecond)
		}
		if syscall.Kill(pid, 0) == nil {
			t.Fatal("provider child survived cancellation")
		}
	}
}

func TestPasswordProductionTimeout(t *testing.T) {
	started := time.Now()
	_, err := Password(context.Background(), command("/bin/sleep", "60"))
	if err == nil || time.Since(started) < 14*time.Second || time.Since(started) > 18*time.Second {
		t.Fatal("15-second provider timeout was not enforced")
	}
}
