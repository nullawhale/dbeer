package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sshtunnel"
)

func TestMain(tests *testing.M) {
	if handled, err := sshtunnel.RunUtility(os.Args[1:]); handled {
		if err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(tests.Run())
}

func TestSSHProtocolProbeTrustConnectAndShutdown(t *testing.T) {
	root := os.Getenv("DBEER_TEST_SSH_ROOT")
	if root == "" {
		if os.Getenv("DBEER_REQUIRE_SSH") == "1" {
			t.Fatal("required SSH fixture missing")
		}
		t.Skip("requires scripts/test-ssh.sh")
	}
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_SSH_PORT"))
	if err != nil {
		t.Fatal("invalid SSH fixture")
	}
	ssh := protocol.SSHSettings{ProfileID: "protocol-profile", Host: "127.0.0.1", Port: port, User: "dbeer", AuthMethod: "privateKey", IdentityFile: filepath.Join(root, "id_plain")}
	connection := protocol.Connection{Engine: "postgresql", Host: "postgres.ssh-fixture.invalid", Port: 5432, Database: "dbeer", User: "dbeer", SSLMode: "disable", SSH: &ssh}
	secret, err := os.ReadFile(filepath.Join(root, "password"))
	if err != nil {
		t.Fatal("missing fixture credential")
	}
	connection.Password = string(secret[:len(secret)-1])
	if os.Getenv("DBEER_TEST_SSH_ENGINE") != "postgresql" {
		t.Skip("protocol connect covered by PostgreSQL matrix")
	}
	manager, err := sshtunnel.NewManagerWithOptions(sshtunnel.Options{KnownHostsPath: filepath.Join(t.TempDir(), "known_hosts")})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	input, inputWriter := io.Pipe()
	outputReader, output := io.Pipe()
	defer inputWriter.Close()
	defer outputReader.Close()
	done := make(chan error, 1)
	go func() {
		done <- runWithSSH(input, output, func(ctx context.Context, c protocol.Connection) (adapter.Session, error) {
			lease, e := manager.Acquire(ctx, c.SSH)
			if e != nil {
				return nil, safeSSHError(e)
			}
			physical, e := openDatabase(adapter.WithTransport(ctx, lease), c)
			if e != nil {
				lease.Close()
			}
			return physical, e
		}, nil, manager)
	}()
	encoder := json.NewEncoder(inputWriter)
	decoder := json.NewDecoder(outputReader)
	send := func(value any) {
		t.Helper()
		if err := encoder.Encode(value); err != nil {
			t.Fatal(err)
		}
	}
	receive := func() protocol.Response {
		t.Helper()
		result := make(chan protocol.Response, 1)
		go func() {
			var r protocol.Response
			if decoder.Decode(&r) == nil {
				result <- r
			}
		}()
		select {
		case r := <-result:
			return r
		case <-time.After(25 * time.Second):
			t.Fatal("SSH protocol response timed out")
			return protocol.Response{}
		}
	}
	send(map[string]any{"type": "hello", "requestId": "hello", "protocolVersion": protocol.Version})
	if receive().Type != "hello.ack" {
		t.Fatal("handshake failed")
	}
	send(map[string]any{"type": "ssh.probe", "requestId": "probe", "connection": connection})
	probe := receive()
	if probe.SSH == nil || probe.SSH.Status != "unknown" {
		t.Fatal("probe did not request review")
	}
	send(map[string]any{"type": "ssh.trust", "requestId": "trust", "connection": connection, "sshTrust": map[string]any{"token": probe.SSH.ChallengeToken}})
	trusted := receive()
	if trusted.Type != "ssh.trust.result" || trusted.SSH == nil || trusted.SSH.Status != "trusted" {
		t.Fatal("trust did not return trusted SSH metadata")
	}
	send(map[string]any{"type": "connect", "requestId": "connect", "connection": connection})
	if receive().Type != "connect.result" {
		t.Fatal("tunneled protocol connection failed")
	}
	send(map[string]any{"type": "shutdown", "requestId": "shutdown"})
	if receive().Type != "shutdown.ack" {
		t.Fatal("shutdown failed")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("SSH helper did not finish")
	}
}
