package postgres

import (
	"context"
	"crypto/x509"
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

// scripts/test-tls.sh provisions a disposable real PostgreSQL server and creates
// short-lived certificates. No private keys or credentials live in the repo.
func TestPostgresTLSNegotiation(t *testing.T) {
	portText := os.Getenv("DBEER_TEST_TLS_PORT")
	if portText == "" {
		if os.Getenv("DBEER_REQUIRE_TLS_TESTS") == "1" {
			t.Fatal("TLS integration server is required; run scripts/test-tls.sh")
		}
		t.Skip("TLS integration server is not configured; run scripts/test-tls.sh")
	}
	cleanEnvironment(t)
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		t.Fatal("invalid TLS integration port")
	}
	ca := os.Getenv("DBEER_TEST_TLS_CA_FILE")
	untrustedCA := os.Getenv("DBEER_TEST_TLS_UNTRUSTED_CA_FILE")
	password, err := os.ReadFile(os.Getenv("DBEER_TEST_TLS_PASSWORD_FILE"))
	if err != nil || len(password) == 0 || ca == "" || untrustedCA == "" {
		t.Fatal("TLS integration fixtures are incomplete")
	}
	base := protocol.Connection{Host: "localhost", Port: port, Database: "dbeer_tls", User: "dbeer_tls",
		Password: strings.TrimSuffix(string(password), "\n"), SSLMode: "verify-full", SSLRootCert: ca}
	for _, test := range []struct {
		name, host, mode, ca, failure string
	}{
		{"trusted CA and matching hostname", "localhost", "verify-full", ca, ""},
		{"wrong hostname", "127.0.0.1", "verify-full", ca, "hostname"},
		{"untrusted CA", "localhost", "verify-full", untrustedCA, "authority"},
		{"verify-ca accepts a different hostname", "127.0.0.1", "verify-ca", ca, ""},
		{"verify-ca rejects an untrusted CA", "localhost", "verify-ca", untrustedCA, "authority"},
	} {
		t.Run(test.name, func(t *testing.T) {
			connection := base
			connection.Host, connection.SSLMode, connection.SSLRootCert = test.host, test.mode, test.ca
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			conn, err := connect(ctx, connection)
			if test.failure == "" {
				if err != nil {
					t.Fatal("trusted TLS connection to PostgreSQL failed")
				}
				defer closeConnection(conn)
				var ssl bool
				var version string
				if conn.QueryRow(ctx, "SELECT ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid()").Scan(&ssl, &version) != nil || !ssl || !strings.HasPrefix(version, "TLSv") {
					t.Fatal("connection did not negotiate TLS with the real PostgreSQL backend")
				}
				return
			}
			if conn != nil {
				closeConnection(conn)
				t.Fatal("invalid TLS certificate was accepted")
			}
			if err == nil {
				t.Fatal("invalid TLS certificate did not return an error")
			}
			var hostnameError x509.HostnameError
			var authorityError x509.UnknownAuthorityError
			if test.failure == "hostname" && !errors.As(err, &hostnameError) {
				t.Fatal("connection failed for a reason other than hostname verification")
			}
			if test.failure == "authority" && !errors.As(err, &authorityError) {
				t.Fatal("connection failed for a reason other than CA verification")
			}

			// Exercise the same failed connection through the owner, where raw
			// driver errors (which retain settings) must become a safe response.
			owner := newOwner(connect)
			defer owner.Close()
			if !owner.Submit(protocol.Command{Type: "connect", RequestID: "tls-rejection", Connection: &connection}) {
				t.Fatal("owner did not accept the TLS test connection")
			}
			select {
			case response := <-owner.Responses():
				if response.Type != "error" || response.Category != "connection" || response.RequestID != "tls-rejection" || response.Connected || response.SessionID != "" || strings.Contains(response.Message, connection.Password) || strings.Contains(response.Message, connection.SSLRootCert) {
					t.Fatal("TLS failure was not safely reported by the owner")
				}
			case <-ctx.Done():
				t.Fatal("owner did not report TLS rejection promptly")
			}
		})
	}
}
