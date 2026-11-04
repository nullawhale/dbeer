package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sshtunnel"
)

func TestSSHDatabaseUtilityForwardPreservesTLSAndOwnsOnlyItsLease(t *testing.T) {
	root := os.Getenv("DBEER_TEST_SSH_ROOT")
	if root == "" {
		if os.Getenv("DBEER_REQUIRE_SSH") == "1" {
			t.Fatal("required SSH fixture missing")
		}
		t.Skip("requires scripts/test-ssh.sh")
	}
	if os.Getenv("DBEER_TEST_SSH_ENGINE") != "postgresql" {
		t.Skip("utility forwarding TLS is covered by the PostgreSQL fixture")
	}
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_SSH_PORT"))
	if err != nil {
		t.Fatal("invalid SSH fixture port")
	}
	ssh := protocol.SSHSettings{ProfileID: "database-utility-forward", Host: "127.0.0.1", Port: port, User: "dbeer", AuthMethod: "privateKey", IdentityFile: filepath.Join(root, "id_plain")}
	manager, err := sshtunnel.NewManagerWithOptions(sshtunnel.Options{KnownHostsPath: filepath.Join(t.TempDir(), "known_hosts")})
	if err != nil {
		t.Fatal("cannot create SSH fixture manager")
	}
	defer manager.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	probe, err := manager.Probe(ctx, &ssh)
	if err != nil || probe == nil || probe.Status != "unknown" {
		t.Fatal("SSH fixture did not require host-key review")
	}
	if manager.Trust(ctx, &ssh, probe.ChallengeToken) != nil {
		t.Fatal("cannot trust reviewed fixture host key")
	}
	marker := filepath.Join(t.TempDir(), "provider-calls")
	provider := filepath.Join(t.TempDir(), "fixture-password")
	if os.WriteFile(provider, []byte("#!/bin/sh\nprintf x >> \"$1\"\nexec /bin/cat \"$2\"\n"), 0700) != nil {
		t.Fatal("cannot create credential provider fixture")
	}
	settings := protocol.Connection{Engine: "postgresql", Host: "postgres.ssh-fixture.invalid", Port: 5432, Database: "dbeer", User: "dbeer", SSLMode: "verify-full", SSLRootCert: filepath.Join(root, "ca.crt"), SSH: &ssh, PasswordCommand: &protocol.PasswordCommand{Executable: provider, Arguments: []string{marker, filepath.Join(root, "password")}}}
	prepared, err := prepareToolConnection(manager)(ctx, settings)
	if err != nil {
		t.Fatal("cannot prepare SSH utility forwarding")
	}
	defer prepared.Close()
	if prepared.Host != settings.Host || prepared.HostAddr != "127.0.0.1" || prepared.Port == 0 || prepared.Connection.PasswordCommand != nil || prepared.Connection.Password == "" {
		t.Fatal("forwarded utility lost its TLS identity or resolved credential")
	}
	calls, err := os.ReadFile(marker)
	if err != nil || string(calls) != "x" {
		t.Fatal("utility transport did not resolve exactly one credential")
	}
	ca, err := os.ReadFile(settings.SSLRootCert)
	roots := x509.NewCertPool()
	if err != nil || !roots.AppendCertsFromPEM(ca) {
		t.Fatal("invalid fixture CA")
	}
	checkTLS := func(socket net.Conn) *tls.Conn {
		t.Helper()
		socket.SetDeadline(time.Now().Add(5 * time.Second))
		// PostgreSQL's SSLRequest permits verification without database login.
		if _, err := socket.Write([]byte{0, 0, 0, 8, 4, 210, 22, 47}); err != nil {
			t.Fatal("cannot send PostgreSQL TLS request")
		}
		var response [1]byte
		if _, err := io.ReadFull(socket, response[:]); err != nil || response[0] != 'S' {
			t.Fatal("forwarded database did not offer TLS")
		}
		secured := tls.Client(socket, &tls.Config{RootCAs: roots, ServerName: settings.Host, MinVersion: tls.VersionTLS12})
		if secured.HandshakeContext(ctx) != nil {
			t.Fatal("forwarded database failed original-host TLS verification")
		}
		return secured
	}
	address := net.JoinHostPort(prepared.HostAddr, strconv.Itoa(prepared.Port))
	socket, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err != nil {
		t.Fatal("cannot dial private utility listener")
	}
	secured := checkTLS(socket)
	defer secured.Close()
	sibling, err := manager.Acquire(ctx, &ssh)
	if err != nil {
		t.Fatal("cannot acquire sibling SQL lease")
	}
	defer sibling.Close()
	var closers sync.WaitGroup
	closers.Add(8)
	for range 8 {
		go func() { defer closers.Done(); prepared.Close() }()
	}
	closed := make(chan struct{})
	go func() { closers.Wait(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("concurrent utility forwarding close did not finish")
	}
	select {
	case <-prepared.Done:
	default:
		t.Fatal("utility forwarding lifetime was not closed")
	}
	if extra, err := net.DialTimeout("tcp", address, time.Second); err == nil {
		extra.Close()
		t.Fatal("closed utility listener still accepted clients")
	}
	secured.SetReadDeadline(time.Now().Add(time.Second))
	var b [1]byte
	if _, err := secured.Read(b[:]); err == nil {
		t.Fatal("utility close retained an active forwarded socket")
	}
	independent, err := sibling.DialContext(ctx, "tcp", net.JoinHostPort(settings.Host, strconv.Itoa(settings.Port)))
	if err != nil {
		t.Fatal("utility close cancelled an independent SQL lease")
	}
	checkTLS(independent).Close()
}
