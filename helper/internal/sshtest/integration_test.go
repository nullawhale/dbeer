// Package sshtest exercises real adapters through an owned sshd fixture. It is
// intentionally separate from transport unit tests so required mode can never
// silently replace the database/SSH matrix with synthetic sockets.
package sshtest

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
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

func fixture(t *testing.T) (string, protocol.SSHSettings) {
	t.Helper()
	root := os.Getenv("DBEER_TEST_SSH_ROOT")
	if root == "" {
		if os.Getenv("DBEER_REQUIRE_SSH") == "1" {
			t.Fatal("required SSH fixture is missing")
		}
		t.Skip("SSH integration requires scripts/test-ssh.sh")
	}
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_SSH_PORT"))
	if err != nil {
		t.Fatal("invalid SSH fixture port")
	}
	return root, protocol.SSHSettings{ProfileID: "ssh-integration", Host: "127.0.0.1", Port: port, User: "dbeer", AuthMethod: "privateKey", IdentityFile: filepath.Join(root, "id_plain")}
}

func readSecret(t *testing.T, root, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, name))
	if err != nil {
		t.Fatal("missing fixture credential")
	}
	return strings.TrimSpace(string(data))
}

func newManager(t *testing.T) *sshtunnel.Manager {
	t.Helper()
	manager, err := sshtunnel.NewManagerWithOptions(sshtunnel.Options{KnownHostsPath: filepath.Join(t.TempDir(), "known_hosts")})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { manager.Close() })
	return manager
}

func trust(t *testing.T, manager *sshtunnel.Manager, settings *protocol.SSHSettings) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	probe, err := manager.Probe(ctx, settings)
	if err != nil {
		t.Fatal(err)
	}
	if probe.Status == "unknown" {
		if err := manager.Trust(ctx, settings, probe.ChallengeToken); err != nil {
			t.Fatal(err)
		}
		if err := manager.Trust(ctx, settings, probe.ChallengeToken); err == nil {
			t.Fatal("trust challenge replay accepted")
		}
	} else if probe.Status != "trusted" {
		t.Fatal("unexpected host trust status")
	}
}

func databaseSettings(t *testing.T, root string) protocol.Connection {
	t.Helper()
	password := readSecret(t, root, "password")
	switch os.Getenv("DBEER_TEST_SSH_ENGINE") {
	case "postgresql":
		return protocol.Connection{Engine: "postgresql", Host: "postgres.ssh-fixture.invalid", Port: 5432, Database: "dbeer", User: "dbeer", Password: password, SSLMode: "disable"}
	case "mysql":
		return protocol.Connection{Engine: "mysql", Host: "mysql.ssh-fixture.invalid", Port: 3306, Database: "dbeer", User: "dbeer", Password: password, SSLMode: "disable"}
	case "cassandra":
		host := os.Getenv("DBEER_TEST_SSH_CASSANDRA_HOST")
		if net.ParseIP(host) == nil {
			t.Fatal("required Cassandra address is missing")
		}
		return protocol.Connection{Engine: "cassandra", Host: host, ContactPoints: []string{host}, Port: 9042, SSLMode: "disable"}
	default:
		t.Fatal("required database engine fixture is missing")
		return protocol.Connection{}
	}
}

func open(t *testing.T, manager *sshtunnel.Manager, ssh *protocol.SSHSettings, settings protocol.Connection) adapter.Session {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	lease, err := manager.Acquire(ctx, ssh)
	if err != nil {
		t.Fatal(err)
	}
	settings.SSH = ssh
	ctx = adapter.WithTransport(ctx, lease)
	var physical adapter.Session
	switch settings.Engine {
	case "postgresql":
		physical, err = postgres.Open(ctx, settings)
	case "mysql":
		physical, err = mysql.Open(ctx, settings)
	case "cassandra":
		physical, err = cassandra.Open(ctx, settings)
	}
	if err != nil {
		lease.Close()
		t.Fatal(err)
	}
	t.Cleanup(physical.Close)
	return physical
}

func query(t *testing.T, physical adapter.Session, sql string) protocol.Response {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	response := physical.Execute(ctx, protocol.Command{Type: "execute", RequestID: "request", QueryID: "query", SQL: sql})
	if response.Type == "error" {
		t.Fatalf("fixture query failed: %s %s", response.Category, response.Message)
	}
	return response
}

func TestSSHRealDatabaseAuthenticationAndIndependentLeases(t *testing.T) {
	root, settings := fixture(t)
	database := databaseSettings(t, root)
	// A successful query must prove the tunnel: client-side DNS/routing must
	// not reach this same target when the forwarding dependency is absent.
	ctx, cancel := context.WithTimeout(context.Background(), 350*time.Millisecond)
	direct, err := (&net.Dialer{}).DialContext(ctx, "tcp", net.JoinHostPort(database.Host, strconv.Itoa(database.Port)))
	cancel()
	if err == nil {
		direct.Close()
		t.Fatal("fixture database is directly reachable")
	}
	sql := "SELECT 1"
	if database.Engine == "cassandra" {
		sql = "SELECT release_version FROM system.local"
	}
	manager := newManager(t)
	trust(t, manager, &settings)
	for _, method := range []string{"privateKey", "encryptedKey", "password", "agent"} {
		t.Run(method, func(t *testing.T) {
			ssh := settings
			ssh.ProfileID = "profile-" + method
			switch method {
			case "encryptedKey":
				ssh.IdentityFile = filepath.Join(root, "id_encrypted")
				ssh.Passphrase = readSecret(t, root, "passphrase")
			case "password":
				ssh.AuthMethod = "password"
				ssh.IdentityFile = ""
				ssh.Password = readSecret(t, root, "password")
			case "agent":
				ssh.AuthMethod = "agent"
				ssh.IdentityFile = ""
			}
			trust(t, manager, &ssh)
			a := open(t, manager, &ssh, database)
			b := open(t, manager, &ssh, database)
			query(t, a, sql)
			a.Close()
			query(t, b, sql)
			if database.Engine == "cassandra" {
				response := query(t, b, "SELECT peer FROM system.peers")
				if response.RowCount < 2 {
					t.Fatal("multi-node fixture did not discover all peers")
				}
			}
		})
	}
}

func TestSSHRealDatabaseCancellationUsesTunnel(t *testing.T) {
	root, ssh := fixture(t)
	database := databaseSettings(t, root)
	if database.Engine == "cassandra" {
		t.Skip("Cassandra cancellation is local; dedicated cluster loss runner covers its network semantics")
	}
	manager := newManager(t)
	trust(t, manager, &ssh)
	physical := open(t, manager, &ssh, database)
	ctx, cancel := context.WithCancel(context.Background())
	var result protocol.Response
	var workers sync.WaitGroup
	workers.Add(1)
	sql := "SELECT pg_sleep(15)"
	if database.Engine == "mysql" {
		// A standalone MySQL SLEEP returns success when interrupted. Put the
		// delay in a predicate so KILL QUERY produces an authoritative error.
		sql = "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(15) = 0"
	}
	go func() {
		defer workers.Done()
		result = physical.Execute(ctx, protocol.Command{Type: "execute", SQL: sql})
	}()
	time.Sleep(300 * time.Millisecond)
	cancel()
	done := make(chan struct{})
	go func() { workers.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(12 * time.Second):
		t.Fatal("cancellation did not complete through SSH")
	}
	if result.Category != "cancelled" || !result.Connected || result.OutcomeUnknown {
		t.Fatalf("tunneled cancellation did not recover authoritative session: category=%s connected=%t unknown=%t", result.Category, result.Connected, result.OutcomeUnknown)
	}
	query(t, physical, "SELECT 1")
}

func TestSSHRejectsUnknownHostAndIncorrectCredentials(t *testing.T) {
	root, ssh := fixture(t)
	manager := newManager(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if lease, err := manager.Acquire(ctx, &ssh); err == nil {
		lease.Close()
		t.Fatal("unknown key connected without trust")
	}
	trust(t, manager, &ssh)
	for _, method := range []string{"password", "encryptedKey"} {
		wrong := ssh
		wrong.ProfileID = "wrong-" + method
		if method == "password" {
			wrong.AuthMethod = "password"
			wrong.IdentityFile = ""
			wrong.Password = "synthetic-incorrect-password"
		} else {
			wrong.IdentityFile = filepath.Join(root, "id_encrypted")
			wrong.Passphrase = "synthetic-incorrect-passphrase"
		}
		if lease, err := manager.Acquire(ctx, &wrong); err == nil {
			lease.Close()
			t.Fatal("incorrect SSH credential accepted")
		}
	}
}

func TestSSHTunnelLossDuringWritePreservesUnknownOutcome(t *testing.T) {
	root, ssh := fixture(t)
	database := databaseSettings(t, root)
	if database.Engine == "cassandra" {
		t.Skip("Cassandra acknowledgement loss is covered by the dedicated loss proxy suite")
	}
	manager := newManager(t)
	trust(t, manager, &ssh)
	physical := open(t, manager, &ssh, database)
	query(t, physical, "CREATE TEMPORARY TABLE dbeer_ssh_loss (id int)")
	sql := "INSERT INTO dbeer_ssh_loss SELECT 1 FROM pg_sleep(15)"
	if database.Engine == "mysql" {
		sql = "INSERT INTO dbeer_ssh_loss SELECT SLEEP(15)"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	done := make(chan protocol.Response, 1)
	go func() { done <- physical.Execute(ctx, protocol.Command{Type: "execute", SQL: sql}) }()
	time.Sleep(300 * time.Millisecond)
	manager.Close()
	select {
	case response := <-done:
		if response.Type != "error" || !response.OutcomeUnknown || response.Connected {
			t.Fatalf("lost write acknowledgement was not preserved: type=%s category=%s unknown=%t connected=%t", response.Type, response.Category, response.OutcomeUnknown, response.Connected)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("lost tunnel did not terminate the in-flight write")
	}
}
