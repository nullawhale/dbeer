package cassandra

import (
	"crypto/tls"
	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestClusterConfigurationDefaultsAndIsolation(t *testing.T) {
	connection := protocol.Connection{Engine: "cassandra", Host: "node.example"}
	first, err := NewClusterConfig(connection)
	if err != nil {
		t.Fatal(err)
	}
	second, err := NewClusterConfig(connection)
	if err != nil {
		t.Fatal(err)
	}
	if first.ProtoVersion != 5 || first.Port != 9042 || first.NumConns != 1 || first.Consistency != gocql.LocalQuorum || first.DefaultIdempotence || first.Authenticator != nil || first.RetryPolicy.(*gocql.SimpleRetryPolicy).NumRetries != 0 {
		t.Fatal("unsafe or incorrect driver defaults")
	}
	if first.SslOpts == nil || !first.SslOpts.EnableHostVerification || first.SslOpts.Config.InsecureSkipVerify || first.SslOpts.Config.MinVersion < tls.VersionTLS12 {
		t.Fatal("TLS does not verify certificate and hostname")
	}
	if first == second || first.PoolConfig.HostSelectionPolicy == second.PoolConfig.HostSelectionPolicy {
		t.Fatal("tabs share mutable driver configuration")
	}
	query := ConfigureQuery(&gocql.Query{}, "quoted keyspace")
	if query.Keyspace() != "quoted keyspace" {
		t.Fatal("per-query keyspace was not retained")
	}
}
func TestContactPointsAuthConsistencyAndTLSValidation(t *testing.T) {
	c := protocol.Connection{Engine: "cassandra", ContactPoints: []string{"node1", "node2"}, Database: "demo", User: "test", Password: "fixture", SSLMode: "disable", LocalDatacenter: "dc1", Consistency: "LOCAL_ONE"}
	cluster, err := NewClusterConfig(c)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(cluster.Hosts, c.ContactPoints) || cluster.Keyspace != "demo" || cluster.Consistency != gocql.LocalOne || cluster.SslOpts != nil || cluster.Authenticator == nil {
		t.Fatal("explicit connection settings lost")
	}
	c.ContactPoints[0] = "changed"
	if cluster.Hosts[0] != "node1" {
		t.Fatal("driver retains caller-owned host list")
	}
	c.SSLMode = "verify-full"
	c.SSLRootCert = filepath.Join(t.TempDir(), "ca.pem")
	if _, err := NewClusterConfig(c); err == nil {
		t.Fatal("missing CA accepted")
	}
	if err := os.WriteFile(c.SSLRootCert, []byte("not a certificate"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewClusterConfig(c); err == nil {
		t.Fatal("invalid CA accepted")
	}
}

func TestCassandraSchemaAgreementWaitIsBoundedForDegradedClusters(t *testing.T) {
	cluster, err := NewClusterConfig(protocol.Connection{Engine: "cassandra", Host: "node.example"})
	if err != nil {
		t.Fatal(err)
	}
	// The pinned driver defaults this post-acknowledgement wait to 60 seconds.
	// Keep ordinary operation/cancellation from inheriting that full interval.
	if cluster.MaxWaitSchemaAgreement <= 0 || cluster.MaxWaitSchemaAgreement > 5*time.Second {
		t.Fatal("Cassandra schema agreement inherits an unbounded or minute-long polling window")
	}
	if cluster.MaxWaitSchemaAgreement >= cluster.Timeout {
		t.Fatal("schema agreement exhausts the ordinary query deadline")
	}
}
