package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCassandraConnectionAndCursorValidation(t *testing.T) {
	base := Connection{Engine: "cassandra", Host: "localhost", Port: 9042, SSLMode: "verify-full"}
	if !base.Valid() || base.CassandraConsistency() != "LOCAL_QUORUM" {
		t.Fatal("optional keyspace and authentication or consistency default rejected")
	}
	for _, mutate := range []func(*Connection){
		func(c *Connection) { c.Consistency = "ANY" }, func(c *Connection) { c.Consistency = "SERIAL" },
		func(c *Connection) { c.SSLMode = "require" }, func(c *Connection) { c.Host = "" },
		func(c *Connection) { c.Password = "secret" }, func(c *Connection) { c.ContactPoints = []string{""} },
		func(c *Connection) { c.LocalDatacenter = "dc\x00" },
	} {
		c := base
		mutate(&c)
		if c.Valid() {
			t.Fatal("unsafe Cassandra settings accepted")
		}
	}
	base.Host = ""
	base.ContactPoints = []string{"node1", "node2"}
	encoded, _ := json.Marshal(Command{Type: "connect", RequestID: "c", Connection: &base})
	command, err := NewReader(strings.NewReader(string(encoded) + "\n")).Read()
	if err != nil || len(command.Connection.ContactPoints) != 2 {
		t.Fatal("Cassandra contact points did not parse")
	}
	for _, mutate := range []func(*CatalogRequest){
		func(c *CatalogRequest) { c.Page = 1 }, func(c *CatalogRequest) { c.Kind = "columns" }, func(c *CatalogRequest) { c.Cursor = strings.Repeat("a", 129) }, func(c *CatalogRequest) { c.Cursor = "a\x00" },
	} {
		c := CatalogRequest{Kind: "browse", Schema: "demo", Object: "events", ObjectKind: "table", Cursor: "opaque"}
		if !c.Valid() {
			t.Fatal("valid cursor rejected")
		}
		mutate(&c)
		if c.Valid() {
			t.Fatal("invalid cursor accepted")
		}
	}
}
func TestUnknownAffectedCountDoesNotOverloadRowCount(t *testing.T) {
	unknown := false
	encoded, err := json.Marshal(Response{Type: "query.result", RequestID: "r", SessionID: "s", QueryID: "q", TransactionStatus: "unsupported", CommandTag: "UPDATE", AffectedRowCountKnown: &unknown})
	if err != nil || !strings.Contains(string(encoded), `"rowCount":0`) || !strings.Contains(string(encoded), `"affectedRowCountKnown":false`) {
		t.Fatal("unknown affected count lost")
	}
}

func TestClusterNodesRejectsObjectAndPagingParameters(t *testing.T) {
	for _, mutate := range []func(*CatalogRequest){
		func(c *CatalogRequest) { c.Schema = "demo" },
		func(c *CatalogRequest) { c.Object = "events" },
		func(c *CatalogRequest) { c.ObjectKind = "table" },
		func(c *CatalogRequest) { c.Identity = "node" },
		func(c *CatalogRequest) { c.Page = 1 },
		func(c *CatalogRequest) { c.Cursor = "opaque" },
		func(c *CatalogRequest) { c.Search = "node" },
		func(c *CatalogRequest) { c.Sort = []CatalogSort{{Column: "address", Direction: "asc"}} },
	} {
		request := CatalogRequest{Kind: "clusterNodes"}
		mutate(&request)
		if request.Valid() {
			t.Fatal("cluster snapshot accepted unrelated catalog parameters")
		}
	}
}
