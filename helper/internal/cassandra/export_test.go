package cassandra

import (
	"testing"

	gocql "github.com/apache/cassandra-gocql-driver/v2"

	"dbeer/helper/internal/protocol"
)

// NewSessionWithDialerForTest instruments transport without changing production
// configuration or disabling discovery, routing, or the adapter's query policy.
// This constructor is available only to tests, including external-package tests.
func NewSessionWithDialerForTest(t *testing.T, connection protocol.Connection, dialer gocql.Dialer) *Session {
	t.Helper()
	config, err := NewClusterConfig(connection)
	if err != nil {
		t.Fatal("invalid instrumented Cassandra fixture settings")
	}
	config.Dialer = dialer
	driver, err := config.CreateSession()
	if err != nil {
		t.Fatal("instrumented Cassandra fixture connection failed")
	}
	session := &Session{driver: driver, keyspace: connection.Database, cursors: make(map[string]browseCursor)}
	t.Cleanup(session.Close)
	return session
}
