package sshtest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestSSHOpenSSHConfigurationDatabaseTLSAndCancellation(t *testing.T) {
	root, explicit := fixture(t)
	ca := os.Getenv("DBEER_TEST_SSH_TLS_CA")
	if ca == "" {
		t.Fatal("SSH configuration database test requires TLS fixtures")
	}
	directory := t.TempDir()
	include, config := filepath.Join(directory, "routes"), filepath.Join(directory, "config")
	// Only the first host is reachable from the client. The next two endpoints
	// are resolved and contacted inside the bastion's network namespace.
	text := fmt.Sprintf("Host first\n HostName 127.0.0.1\n Port %d\nHost inside database-route\n HostName 127.0.0.1\n Port 22\nHost database-route\n ProxyJump first,inside\nHost *\n User dbeer\n IdentityFile %s\n IdentitiesOnly yes\n", explicit.Port, filepath.Join(root, "id_plain"))
	if os.WriteFile(include, []byte(text), 0600) != nil || os.WriteFile(config, []byte("Include "+include+"\n"), 0600) != nil {
		t.Fatal("cannot prepare route fixture")
	}
	ssh := protocol.SSHSettings{ProfileID: "ssh-configuration-database", Host: "database-route", AuthMethod: "openSSH", ConfigFile: config}
	manager := newManager(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	for count := 0; count < 4; count++ {
		probe, err := manager.Probe(ctx, &ssh)
		if err != nil {
			t.Fatal(err)
		}
		if probe.Status == "trusted" {
			break
		}
		if probe.Status != "unknown" {
			t.Fatal("unexpected fixture key change")
		}
		if err := manager.Trust(ctx, &ssh, probe.ChallengeToken); err != nil {
			t.Fatal(err)
		}
	}
	settings := databaseSettings(t, root)
	settings.SSLMode = "verify-full"
	settings.SSLRootCert = ca
	physical, err := openTLSDatabase(manager, &ssh, settings)
	if err != nil {
		t.Fatal("database TLS failed through the multi-hop configuration route")
	}
	defer physical.Close()
	sql := "SELECT 1"
	if settings.Engine == "cassandra" {
		sql = "SELECT release_version FROM system.local"
	}
	query(t, physical, sql)
	wrong := settings
	wrong.SSLRootCert = os.Getenv("DBEER_TEST_SSH_TLS_WRONG_CA")
	if wrong.SSLRootCert == "" {
		t.Fatal("wrong CA fixture missing")
	}
	bad, err := openTLSDatabase(manager, &ssh, wrong)
	if bad != nil {
		bad.Close()
	}
	if err == nil {
		t.Fatal("configuration mode bypassed TLS trust")
	}
	if settings.Engine == "cassandra" {
		return
	}
	wrong = settings
	wrong.Host = "wrong-tls.ssh-fixture.invalid"
	bad, err = openTLSDatabase(manager, &ssh, wrong)
	if bad != nil {
		bad.Close()
	}
	if err == nil {
		t.Fatal("configuration mode bypassed database hostname verification")
	}
	queryCtx, stopQuery := context.WithCancel(context.Background())
	defer stopQuery()
	sleepSQL := "SELECT pg_sleep(20)"
	if settings.Engine == "mysql" {
		// Standalone SLEEP may complete successfully when interrupted. A
		// predicate makes KILL QUERY return the authoritative cancellation.
		sleepSQL = "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(20) = 0"
	}
	result := make(chan protocol.Response, 1)
	go func() {
		result <- physical.Execute(queryCtx, protocol.Command{Type: "execute", RequestID: "config-cancel", QueryID: "config-cancel", SQL: sleepSQL})
	}()
	time.Sleep(300 * time.Millisecond)
	stopQuery()
	select {
	case response := <-result:
		if response.Type != "error" || !strings.Contains(strings.ToLower(response.Category), "cancel") {
			t.Fatal("multi-hop query did not report cancellation")
		}
	case <-time.After(6 * time.Second):
		t.Fatal("multi-hop cancellation did not finish")
	}
	query(t, physical, sql)
}
