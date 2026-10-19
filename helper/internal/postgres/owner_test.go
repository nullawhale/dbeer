package postgres

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func cleanEnvironment(t *testing.T) {
	t.Helper()
	for _, entry := range os.Environ() {
		name, value, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(name, "PG") {
			t.Setenv(name, value)
			_ = os.Unsetenv(name)
		}
	}
}

func TestExplicitConnectionConfigAndTLSModes(t *testing.T) {
	cleanEnvironment(t)
	connection := protocol.Connection{Host: "database.example", Port: 5440, Database: "db ' \\ = name", User: "user ' \\", Password: "password ' \\ sslmode=disable", SSLMode: "disable"}
	for _, mode := range []string{"disable", "allow", "prefer", "require", "verify-ca", "verify-full"} {
		t.Run(mode, func(t *testing.T) {
			connection.SSLMode = mode
			config, err := connectionConfig(connection)
			if err != nil {
				t.Fatal("valid form rejected")
			}
			if config.Host != connection.Host || config.Port != uint16(connection.Port) || config.Database != connection.Database || config.User != connection.User || config.Password != connection.Password || config.ConnectTimeout != 5*time.Second {
				t.Fatal("explicit fields did not round trip")
			}
			if config.RuntimeParams["application_name"] != "DBeer" {
				t.Fatal("missing application name")
			}
			switch mode {
			case "disable":
				if config.TLSConfig != nil || len(config.Fallbacks) != 0 {
					t.Fatal("disable enabled TLS")
				}
			case "allow":
				if config.TLSConfig != nil || len(config.Fallbacks) != 1 || config.Fallbacks[0].TLSConfig == nil {
					t.Fatal("allow fallback missing")
				}
			case "prefer":
				if config.TLSConfig == nil || len(config.Fallbacks) != 1 || config.Fallbacks[0].TLSConfig != nil {
					t.Fatal("prefer fallback missing")
				}
			case "require":
				if config.TLSConfig == nil || !config.TLSConfig.InsecureSkipVerify || len(config.Fallbacks) != 0 {
					t.Fatal("require configuration changed")
				}
			case "verify-ca":
				if config.TLSConfig == nil || config.TLSConfig.VerifyPeerCertificate == nil || len(config.Fallbacks) != 0 {
					t.Fatal("verify-ca verification missing")
				}
			case "verify-full":
				if config.TLSConfig == nil || config.TLSConfig.InsecureSkipVerify || config.TLSConfig.ServerName != connection.Host || len(config.Fallbacks) != 0 {
					t.Fatal("verify-full hostname verification missing")
				}
			}
		})
	}
}

func TestConfiguredCAAndSafeConfigErrors(t *testing.T) {
	cleanEnvironment(t)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), IsCA: true, BasicConstraintsValid: true, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal("cannot create test certificate")
	}
	path := filepath.Join(t.TempDir(), "ca ' \\ file.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal("cannot save test certificate")
	}
	connection := protocol.Connection{Host: "localhost", Port: 5432, Database: "db", User: "user", Password: "secret-password", SSLMode: "verify-full", SSLRootCert: path}
	config, err := connectionConfig(connection)
	if err != nil || config.TLSConfig.RootCAs == nil {
		t.Fatal("explicit CA did not load")
	}
	connection.SSLRootCert = path + "-missing"
	if _, err := connectionConfig(connection); err == nil || strings.Contains(err.Error(), connection.Password) || strings.Contains(err.Error(), path) {
		t.Fatal("unsafe configuration error")
	}
	connection.Host = "host1,host2"
	if _, err := connectionConfig(connection); err == nil {
		t.Fatal("multi-host failover must not be configured")
	}
}

func TestOwnerIgnoresInheritedPostgresSettings(t *testing.T) {
	cleanEnvironment(t)
	for _, name := range []string{"PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD", "PGSERVICE", "PGSERVICEFILE", "PGPASSFILE", "PGSSLMODE", "PGSSLROOTCERT", "PGSSLCERT", "PGSSLKEY", "PGTARGETSESSIONATTRS", "PGOPTIONS"} {
		t.Setenv(name, "must-not-be-used")
	}
	owner := NewOwner()
	defer owner.Close()
	connection := protocol.Connection{Host: "localhost", Port: 5432, Database: "db", User: "user", Password: "", SSLMode: "disable"}
	config, err := connectionConfig(connection)
	if err != nil || config.Password != "" || config.Host != "localhost" || config.Port != 5432 || config.TLSConfig != nil || len(config.RuntimeParams) != 1 {
		t.Fatal("inherited PG settings affected the form")
	}
}

func receiveResponse(t *testing.T, owner *Owner) protocol.Response {
	t.Helper()
	select {
	case response, ok := <-owner.Responses():
		if !ok {
			t.Fatal("owner stopped before response")
		}
		return response
	case <-time.After(2 * time.Second):
		t.Fatal("owner did not respond promptly")
		return protocol.Response{}
	}
}

func TestConnectDoesNotBlockConflictsOrShutdown(t *testing.T) {
	started := make(chan struct{})
	owner := newOwner(func(ctx context.Context, _ protocol.Connection) (*pgx.Conn, error) {
		close(started)
		<-ctx.Done()
		return nil, ctx.Err()
	})
	defer owner.Close()
	connection := &protocol.Connection{}
	owner.Submit(protocol.Command{Type: "connect", RequestID: "connect", Connection: connection})
	<-started
	owner.Submit(protocol.Command{Type: "connect", RequestID: "replace", Connection: connection})
	if response := receiveResponse(t, owner); response.RequestID != "replace" || response.Category != "busy" {
		t.Fatal("concurrent connection was not rejected")
	}
	owner.Submit(protocol.Command{Type: "disconnect", RequestID: "disconnect", SessionID: "old"})
	if response := receiveResponse(t, owner); response.Category != "busy" {
		t.Fatal("disconnect during connection attempt was not rejected")
	}
	owner.Submit(protocol.Command{Type: "shutdown", RequestID: "shutdown"})
	if response := receiveResponse(t, owner); response.RequestID != "connect" || response.Category != "cancelled" {
		t.Fatal("pending connect did not terminate")
	}
	if response := receiveResponse(t, owner); response.Type != "shutdown.ack" {
		t.Fatal("missing shutdown acknowledgement")
	}
}

func TestSafeConnectionErrors(t *testing.T) {
	for _, err := range []error{errors.New("secret-password"), &pgconn.PgError{Code: "28P01", Message: "secret-password"}, &pgconn.PgError{Code: "secret-password", Message: "secret-password"}, context.DeadlineExceeded} {
		response := connectionError(protocol.Command{RequestID: "r"}, err)
		if strings.Contains(response.Message, "secret-password") || strings.Contains(response.SQLState, "secret-password") || response.Connected {
			t.Fatal("unsafe connection diagnostic")
		}
	}
}
