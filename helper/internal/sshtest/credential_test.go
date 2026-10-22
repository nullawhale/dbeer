package sshtest

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
)

func TestSSHPasswordCommandsRefreshAfterRotationAndDuringMySQLStop(t *testing.T) {
	root, ssh := fixture(t)
	settings := databaseSettings(t, root)
	if settings.Engine == "cassandra" {
		t.Skip("this fixture covers PostgreSQL/MySQL password rotation")
	}
	settings.SSLMode, settings.SSLRootCert = "verify-full", os.Getenv("DBEER_TEST_SSH_TLS_CA")
	originalPassword := settings.Password
	settings.Password = ""
	directory := t.TempDir()
	provider := filepath.Join(directory, "password-cli")
	counter := filepath.Join(directory, "invocations")
	token := filepath.Join(directory, "token")
	if os.WriteFile(provider, []byte("#!/bin/sh\nprintf x >> \"$1\"\nexec /bin/cat \"$2\"\n"), 0700) != nil ||
		os.WriteFile(token, []byte(originalPassword+"\n"), 0600) != nil {
		t.Fatal("cannot prepare credential fixture")
	}
	settings.PasswordCommand = &protocol.PasswordCommand{Executable: provider, Arguments: []string{counter, token}}
	count := func() int { data, _ := os.ReadFile(counter); return len(data) }
	manager := newManager(t)
	trust(t, manager, &ssh)
	physical := open(t, manager, &ssh, settings)
	query(t, physical, "SELECT 1")
	if count() != 1 {
		t.Fatal("initial credential was not resolved once")
	}
	service := open(t, manager, &ssh, settings)
	query(t, service, "SELECT 1")
	service.Close()
	if count() != 2 {
		t.Fatal("service connection reused credentials")
	}

	alter := func(password string) string {
		password = strings.ReplaceAll(password, "'", "''")
		if settings.Engine == "mysql" {
			return "ALTER USER 'dbeer'@'%' IDENTIFIED BY '" + password + "'"
		}
		return "ALTER ROLE dbeer WITH PASSWORD '" + password + "'"
	}
	rotated := "r30-rotated-fixture-credential"
	query(t, physical, alter(rotated))
	defer func() {
		response := physical.Execute(context.Background(), protocol.Command{Type: "execute", SQL: alter(originalPassword)})
		if response.Type == "error" {
			t.Error("cannot restore fixture password")
		}
	}()

	tryOpen := func() (adapter.Session, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		defer cancel()
		lease, err := manager.Acquire(ctx, &ssh)
		if err != nil {
			return nil, err
		}
		connection := settings
		connection.SSH = &ssh
		ctx = adapter.WithTransport(ctx, lease)
		var session adapter.Session
		if settings.Engine == "mysql" {
			session, err = mysql.Open(ctx, connection)
		} else {
			session, err = postgres.Open(ctx, connection)
		}
		if err != nil {
			lease.Close()
		}
		return session, err
	}
	// The old token must fail without changing the still-live working session.
	stale, err := tryOpen()
	if stale != nil {
		stale.Close()
	}
	if err == nil || count() != 3 {
		t.Fatal("stale credentials were accepted or automatically retried")
	}
	if err := os.WriteFile(token, []byte(rotated+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	fresh, err := tryOpen()
	if err != nil {
		t.Fatal("fresh CLI credential could not authenticate")
	}
	defer fresh.Close()
	query(t, fresh, "SELECT 1")
	if count() != 4 {
		t.Fatal("new connection did not refresh credentials")
	}

	if settings.Engine == "mysql" {
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan protocol.Response, 1)
		go func() {
			done <- physical.Execute(ctx, protocol.Command{Type: "execute", SQL: "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(15) = 0"})
		}()
		time.Sleep(300 * time.Millisecond)
		cancel()
		select {
		case response := <-done:
			if response.Category != "cancelled" || !response.Connected || response.OutcomeUnknown || count() != 5 {
				t.Fatal("MySQL Stop did not obtain a fresh credential through SSH")
			}
		case <-time.After(8 * time.Second):
			t.Fatal("MySQL Stop was not bounded")
		}
		query(t, physical, "SELECT 1")
	}
	// Provider failures have no fallback to the previous successful token.
	if err := os.WriteFile(token, nil, 0600); err != nil {
		t.Fatal(err)
	}
	before := count()
	failed, err := tryOpen()
	if failed != nil {
		failed.Close()
	}
	if err == nil || count() != before+1 || strings.Contains(err.Error(), rotated) {
		t.Fatal("provider failure leaked a token, fell back or retried")
	}
	query(t, physical, "SELECT 1")
}
