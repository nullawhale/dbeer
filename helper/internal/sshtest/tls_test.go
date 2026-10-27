package sshtest

import (
	"context"
	"os"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sshtunnel"
)

// TLS terminates at the database beyond the bastion. The identity being
// verified must remain the database's, independently of the loopback proxy.
func TestSSHDatabaseTLSIdentity(t *testing.T) {
	ca := os.Getenv("DBEER_TEST_SSH_TLS_CA")
	if ca == "" {
		if os.Getenv("DBEER_REQUIRE_SSH_TLS") == "1" {
			t.Fatal("required SSH TLS fixture is missing")
		}
		t.Skip("SSH TLS checks require scripts/test-ssh.sh TLS fixtures")
	}
	root, ssh := fixture(t)
	settings := databaseSettings(t, root)
	settings.SSLMode, settings.SSLRootCert = "verify-full", ca
	settings.SSH = &ssh
	manager := newManager(t)
	trust(t, manager, &ssh)

	t.Run("original-database-identity", func(t *testing.T) {
		physical, err := openTLSDatabase(manager, &ssh, settings)
		if err != nil {
			t.Fatal("database TLS identity failed through SSH")
		}
		defer physical.Close()
		sql := "SELECT 1"
		if settings.Engine == "cassandra" {
			sql = "SELECT release_version FROM system.local"
		}
		query(t, physical, sql)
	})
	t.Run("untrusted-ca-is-rejected", func(t *testing.T) {
		wrongCA := os.Getenv("DBEER_TEST_SSH_TLS_WRONG_CA")
		if wrongCA == "" {
			t.Fatal("untrusted CA fixture is missing")
		}
		wrong := settings
		wrong.SSLRootCert = wrongCA
		physical, err := openTLSDatabase(manager, &ssh, wrong)
		if physical != nil {
			physical.Close()
		}
		if err == nil {
			t.Fatal("SSH bypassed database certificate verification")
		}
	})
	if settings.Engine != "cassandra" {
		t.Run("wrong-database-name-is-rejected", func(t *testing.T) {
			wrong := settings
			// The runner maps this alias to the same database container, but
			// deliberately excludes it from the server certificate's SANs.
			wrong.Host = "wrong-tls.ssh-fixture.invalid"
			encrypted := wrong
			encrypted.SSLMode = "require"
			control, err := openTLSDatabase(manager, &ssh, encrypted)
			if err != nil {
				t.Fatal("wrong-name control alias is not reachable through SSH")
			}
			control.Close()
			physical, err := openTLSDatabase(manager, &ssh, wrong)
			if physical != nil {
				physical.Close()
			}
			if err == nil {
				t.Fatal("SSH bypassed the original database hostname check")
			}
		})
	}
}

func openTLSDatabase(manager *sshtunnel.Manager, ssh *protocol.SSHSettings, settings protocol.Connection) (adapter.Session, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	lease, err := manager.Acquire(ctx, ssh)
	if err != nil {
		return nil, err
	}
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
	if err != nil || physical == nil {
		lease.Close()
	}
	return physical, err
}
