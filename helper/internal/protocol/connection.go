package protocol

import (
	"strings"
	"unicode/utf8"
)

// Database is a database name for relational engines and the optional default
// keyspace for Cassandra. Empty legacy engines retain PostgreSQL semantics.
func (connection Connection) CassandraConsistency() string {
	if connection.Consistency == "" {
		return "LOCAL_QUORUM"
	}
	return connection.Consistency
}

func (connection Connection) Valid() bool {
	if connection.Port < 1 || connection.Port > 65535 {
		return false
	}
	engine := connection.DatabaseEngine()
	if engine != "cassandra" {
		return (engine == "postgresql" || engine == "mysql") && connection.Host != "" && connection.Database != "" && connection.User != "" &&
			len(connection.ContactPoints) == 0 && connection.LocalDatacenter == "" && connection.Consistency == ""
	}
	if len(connection.ContactPoints) > 32 || (connection.Host == "" && len(connection.ContactPoints) == 0) ||
		(connection.User == "" && connection.Password != "") || (connection.SSLMode != "disable" && connection.SSLMode != "verify-full") {
		return false
	}
	for _, value := range append([]string{connection.Host, connection.Database, connection.LocalDatacenter, connection.User}, connection.ContactPoints...) {
		if !utf8.ValidString(value) || len(value) > 1024 || strings.ContainsRune(value, 0) {
			return false
		}
	}
	for _, host := range connection.ContactPoints {
		if strings.TrimSpace(host) == "" {
			return false
		}
	}
	switch connection.CassandraConsistency() {
	case "ONE", "TWO", "THREE", "QUORUM", "ALL", "LOCAL_QUORUM", "EACH_QUORUM", "LOCAL_ONE":
		return true
	default:
		return false
	}
}
