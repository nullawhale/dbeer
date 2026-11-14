package sshtest

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sshtunnel"
)

type mariaDBCountingTransport struct {
	adapter.Transport
	dials atomic.Int32
}

func (t *mariaDBCountingTransport) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	t.dials.Add(1)
	return t.Transport.DialContext(ctx, network, address)
}
func mariaDBSSHSettings(t *testing.T) (string, protocol.SSHSettings, protocol.Connection) {
	t.Helper()
	if os.Getenv("DBEER_TEST_SSH_ENGINE") != "mariadb" {
		if os.Getenv("DBEER_REQUIRE_MARIADB_SSH") == "1" {
			t.Fatal("required MariaDB SSH endpoint missing")
		}
		t.Skip("MariaDB SSH requires scripts/test-ssh.sh --engine mariadb")
	}
	root, ssh := fixture(t)
	ca := os.Getenv("DBEER_TEST_SSH_TLS_CA")
	if ca == "" {
		t.Fatal("MariaDB SSH private CA missing")
	}
	settings := protocol.Connection{Engine: "mariadb", Host: "mariadb.ssh-fixture.invalid", Port: 3306, Database: "dbeer", User: "dbeer", Password: readSecret(t, root, "password"), SSLMode: "verify-full", SSLRootCert: ca, SSH: &ssh}
	return root, ssh, settings
}
func mariaDBSSHOpen(manager *sshtunnel.Manager, ssh *protocol.SSHSettings, settings protocol.Connection) (adapter.Session, *mariaDBCountingTransport, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	lease, err := manager.Acquire(ctx, ssh)
	if err != nil {
		return nil, nil, err
	}
	counted := &mariaDBCountingTransport{Transport: lease}
	physical, err := mariadb.Open(adapter.WithTransport(ctx, counted), settings)
	if err != nil {
		lease.Close()
	}
	return physical, counted, err
}
func TestSSHMariaDBNativeTLSAndIndependentCancellation(t *testing.T) {
	_, ssh, settings := mariaDBSSHSettings(t)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	direct, err := (&net.Dialer{}).DialContext(ctx, "tcp", net.JoinHostPort(settings.Host, strconv.Itoa(settings.Port)))
	cancel()
	if err == nil {
		direct.Close()
		t.Fatal("MariaDB fixture is directly reachable without SSH")
	}
	manager := newManager(t)
	trust(t, manager, &ssh)
	a, transport, err := mariaDBSSHOpen(manager, &ssh, settings)
	if err != nil {
		t.Fatal("MariaDB verified private-CA TLS connection through SSH failed")
	}
	defer a.Close()
	b, _, err := mariaDBSSHOpen(manager, &ssh, settings)
	if err != nil {
		t.Fatal("independent MariaDB TLS lease unavailable")
	}
	defer b.Close()
	id := func(s adapter.Session) string {
		r := query(t, s, "SELECT CONNECTION_ID()")
		if len(r.Rows) != 1 || r.Rows[0][0] == nil {
			t.Fatal("native MariaDB connection identity unavailable")
		}
		return *r.Rows[0][0]
	}
	aid, bid := id(a), id(b)
	if aid == bid {
		t.Fatal("independent SSH owners reused the same MariaDB session")
	}
	cipher := query(t, a, "SHOW SESSION STATUS LIKE 'Ssl_cipher'")
	if len(cipher.Rows) != 1 || cipher.Rows[0][1] == nil || *cipher.Rows[0][1] == "" {
		t.Fatal("MariaDB over SSH lacks native TLS cipher")
	}
	query(t, a, "CREATE TEMPORARY TABLE owned_ssh_state(id INT) ENGINE=InnoDB")
	query(t, a, "START TRANSACTION")
	query(t, a, "INSERT INTO owned_ssh_state VALUES(7)")
	if a.TransactionStatus() != "transaction" || b.TransactionStatus() != "idle" {
		t.Fatal("independent MariaDB transaction owners merged")
	}
	running, stop := context.WithCancel(context.Background())
	defer stop()
	done := make(chan protocol.Response, 1)
	before := transport.dials.Load()
	go func() {
		done <- a.Execute(running, protocol.Command{Type: "execute", SQL: "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(20)=0"})
	}()
	witnessed := false
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		state := query(t, b, "SELECT STATE FROM information_schema.PROCESSLIST WHERE ID="+aid)
		if len(state.Rows) == 1 && state.Rows[0][0] != nil && *state.Rows[0][0] == "User sleep" {
			witnessed = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !witnessed {
		stop()
		<-done
		t.Fatal("native MariaDB delayed query was not actually running before cancellation")
	}
	stop()
	var result protocol.Response
	select {
	case result = <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("MariaDB SSH cancellation did not complete")
	}
	if result.Category != "cancelled" || !result.Connected || result.OutcomeUnknown || result.SQLNotExecuted || result.SQLState != "70100" || result.TransactionStatus != "transaction" || transport.dials.Load() <= before {
		t.Fatal("MariaDB SSH cancellation lacked independent native control acknowledgement or retained transaction")
	}
	rows := query(t, a, "SELECT id FROM owned_ssh_state")
	if len(rows.Rows) != 1 || rows.Rows[0][0] == nil || *rows.Rows[0][0] != "7" {
		t.Fatal("native SSH cancellation lost owning transaction contents")
	}
	query(t, a, "ROLLBACK")
	rows = query(t, a, "SELECT id FROM owned_ssh_state")
	if len(rows.Rows) != 0 {
		t.Fatal("native owning transaction did not roll back after cancellation")
	}
	a.Close()
	query(t, b, "SELECT 1")
	if id(b) != bid {
		t.Fatal("closing one SSH lease replaced the other MariaDB owner")
	}
}
func TestSSHMariaDBRejectsWrongTrust(t *testing.T) {
	root, ssh, settings := mariaDBSSHSettings(t)
	t.Run("wrongHostKey", func(t *testing.T) {
		public, err := os.ReadFile(filepath.Join(root, "id_plain.pub"))
		if err != nil {
			t.Fatal("private wrong-key fixture unavailable")
		}
		path := filepath.Join(t.TempDir(), "wrong_known_hosts")
		line := "[" + ssh.Host + "]:" + strconv.Itoa(ssh.Port) + " " + string(public)
		if os.WriteFile(path, []byte(line), 0600) != nil {
			t.Fatal("private wrong-key record unavailable")
		}
		manager, err := sshtunnel.NewManagerWithOptions(sshtunnel.Options{KnownHostsPath: filepath.Join(t.TempDir(), "known_hosts"), SystemKnownHosts: []string{path}})
		if err != nil {
			t.Fatal("wrong-key manager unavailable")
		}
		defer manager.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		lease, err := manager.Acquire(ctx, &ssh)
		if lease != nil {
			lease.Close()
		}
		if err == nil {
			t.Fatal("wrong SSH host key gained database transport authority")
		}
	})
	manager := newManager(t)
	trust(t, manager, &ssh)
	for _, mode := range []string{"wrongCA", "wrongDatabaseName"} {
		t.Run(mode, func(t *testing.T) {
			wrong := settings
			if mode == "wrongCA" {
				wrong.SSLRootCert = os.Getenv("DBEER_TEST_SSH_TLS_WRONG_CA")
				if wrong.SSLRootCert == "" {
					t.Fatal("wrong CA fixture missing")
				}
			} else {
				wrong.Host = "wrong-tls.ssh-fixture.invalid"
			}
			physical, _, err := mariaDBSSHOpen(manager, &ssh, wrong)
			if physical != nil {
				physical.Close()
			}
			if err == nil {
				t.Fatal("SSH bypassed MariaDB native TLS identity verification")
			}
		})
	}
}
