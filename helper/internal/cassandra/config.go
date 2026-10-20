// Package cassandra implements Cassandra-specific connection and CQL semantics.
package cassandra

import (
	"crypto/tls"
	"crypto/x509"
	"os"
	"time"

	gocql "github.com/apache/cassandra-gocql-driver/v2"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

// NewClusterConfig returns a fresh configuration and host-selection policy for
// one tab. Call CreateSession once per tab; driver sessions/policies must never
// be shared between independently cancellable document sessions.
func NewClusterConfig(connection protocol.Connection) (*gocql.ClusterConfig, error) {
	if connection.SSLMode == "" {
		connection.SSLMode = "verify-full"
	}
	if connection.Port == 0 {
		connection.Port = 9042
	}
	if connection.DatabaseEngine() != "cassandra" || !connection.Valid() {
		return nil, &adapter.ConnectionError{Category: "connection", Message: "The Cassandra connection settings are invalid."}
	}
	hosts := append([]string(nil), connection.ContactPoints...)
	if len(hosts) == 0 {
		hosts = []string{connection.Host}
	}
	cluster := gocql.NewCluster(hosts...)
	cluster.Port = connection.Port
	cluster.ProtoVersion = 5
	cluster.NumConns = 1
	cluster.Keyspace = connection.Database
	cluster.Consistency = gocql.ParseConsistency(connection.CassandraConsistency())
	cluster.SerialConsistency = gocql.LocalSerial
	cluster.Timeout = 30 * time.Second
	cluster.ConnectTimeout = 10 * time.Second
	// A schema-change frame already acknowledges the DDL. The driver waits
	// for cluster convergence afterwards; keep that optional polling window
	// short on a degraded cluster instead of its 60-second default. Driver
	// metadata I/O remains subject to the query/context network deadlines.
	cluster.MaxWaitSchemaAgreement = 5 * time.Second
	cluster.PageSize = 200
	cluster.DefaultIdempotence = false
	cluster.RetryPolicy = &gocql.SimpleRetryPolicy{NumRetries: 0}
	// Query defaults use NonSpeculativeExecution. Explicitly apply it to each
	// query through ConfigureQuery so later code cannot accidentally speculate.
	cluster.Logger = quietLogger{}
	if connection.LocalDatacenter != "" {
		cluster.PoolConfig.HostSelectionPolicy = gocql.TokenAwareHostPolicy(gocql.DCAwareRoundRobinPolicy(connection.LocalDatacenter))
	} else {
		cluster.PoolConfig.HostSelectionPolicy = gocql.TokenAwareHostPolicy(gocql.RoundRobinHostPolicy())
	}
	if connection.User != "" {
		cluster.Authenticator = gocql.PasswordAuthenticator{Username: connection.User, Password: connection.Password}
	}
	if connection.SSLMode != "disable" {
		config := &tls.Config{MinVersion: tls.VersionTLS12}
		if connection.SSLRootCert != "" {
			certificate, err := os.ReadFile(connection.SSLRootCert)
			if err != nil {
				return nil, &adapter.ConnectionError{Category: "tls", Message: "The Cassandra CA certificate could not be read."}
			}
			roots, err := x509.SystemCertPool()
			if err != nil {
				roots = x509.NewCertPool()
			}
			if !roots.AppendCertsFromPEM(certificate) {
				return nil, &adapter.ConnectionError{Category: "tls", Message: "The Cassandra CA certificate is invalid."}
			}
			config.RootCAs = roots
		}
		cluster.SslOpts = &gocql.SslOptions{Config: config, EnableHostVerification: true}
	}
	return cluster, nil
}

// ConfigureQuery establishes protocol-v5 per-query keyspace selection and an
// explicit no-retry/no-speculation policy. PageState(nil) disables automatic
// fetching; the caller must intentionally request each subsequent server page.
func ConfigureQuery(query *gocql.Query, keyspace string) *gocql.Query {
	return query.SetKeyspace(keyspace).RetryPolicy(&gocql.SimpleRetryPolicy{NumRetries: 0}).
		SetSpeculativeExecutionPolicy(&gocql.NonSpeculativeExecution{}).Idempotent(false).PageState(nil)
}

// Driver diagnostics can contain query text, values or addresses. Suppress them
// at their source; the adapter emits only fixed, sanitized user diagnostics.
type quietLogger struct{}

func (quietLogger) Error(string, ...gocql.LogField)   {}
func (quietLogger) Warning(string, ...gocql.LogField) {}
func (quietLogger) Info(string, ...gocql.LogField)    {}
func (quietLogger) Debug(string, ...gocql.LogField)   {}
