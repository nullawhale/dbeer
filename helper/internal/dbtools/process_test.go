package dbtools

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestDatabaseToolsWatchdogReapsUtilityAfterHelperDeath(t *testing.T) {
	dir := t.TempDir()
	tool := fakeUtility(t, "pg_dump", `trap 'echo stopped > "$HOME/stopped"; exit 0' INT TERM
echo started > "$HOME/started"
sleep 30 &
wait`)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal("cannot locate test supervisor")
	}
	parent := exec.Command(executable, "--dbtools-parent-fixture", tool, dir)
	parent.Stdout, parent.Stderr = io.Discard, io.Discard
	if parent.Start() != nil {
		t.Fatal("cannot start disposable helper")
	}
	defer parent.Process.Kill()
	waitFile := func(name string, timeout time.Duration) bool {
		deadline := time.Now().Add(timeout)
		for time.Now().Before(deadline) {
			if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
				return true
			}
			time.Sleep(5 * time.Millisecond)
		}
		return false
	}
	if !waitFile("started", 3*time.Second) {
		parent.Process.Kill()
		parent.Wait()
		t.Fatal("disposable utility did not start")
	}
	if parent.Process.Kill() != nil {
		t.Fatal("cannot end disposable helper")
	}
	_ = parent.Wait()
	if !waitFile("stopped", 3*time.Second) {
		t.Fatal("utility outlived its helper without independent cleanup")
	}
}

func TestDatabaseToolsVersionCompatibilityAndRestrictedClientFloor(t *testing.T) {
	for _, v := range []toolVersion{{major: 16, minor: 9}, {major: 17, minor: 5}, {major: 15, minor: 99}} {
		if supportsRestrict(v) {
			t.Fatal("unpatched psql accepted for local-command restriction")
		}
	}
	for _, v := range []toolVersion{{major: 16, minor: 10}, {major: 17, minor: 6}, {major: 18}} {
		if !supportsRestrict(v) {
			t.Fatal("patched psql rejected")
		}
	}
	if compatible("postgresql", toolVersion{major: 18}, "17.6") == nil || compatible("mysql", toolVersion{major: 8, minor: 4}, "8.0.44") == nil {
		t.Fatal("incompatible utility/server pair accepted")
	}
	if compatible("postgresql", toolVersion{major: 17}, "17.6") != nil || compatible("mysql", toolVersion{major: 8, minor: 4}, "8.4.5") != nil {
		t.Fatal("matching utility/server pair rejected")
	}
}
