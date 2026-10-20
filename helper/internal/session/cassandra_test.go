package session

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type cassandraPolicySession struct {
	testSession
	executions atomic.Int32
}

func (*cassandraPolicySession) TransactionStatus() string { return "unsupported" }
func (*cassandraPolicySession) CurrentKeyspace() string   { return "dbeer" }
func (s *cassandraPolicySession) Execute(_ context.Context, command protocol.Command) protocol.Response {
	s.executions.Add(1)
	r := fakeResult(command)
	r.TransactionStatus = "unsupported"
	return r
}
func TestCassandraReadOnlyIsLocalAndBlocksUnrecognizedFunctions(t *testing.T) {
	physical := &cassandraPolicySession{testSession: testSession{closed: make(chan struct{})}}
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer manager.Close()
	policy := protocol.ExecutionPolicy{Environment: "development", ReadOnly: true}
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "connect-cql", Connection: &protocol.Connection{Engine: "cassandra", Policy: &policy}})
	connected := receive(t, manager)
	if connected.Type != "connect.result" || connected.TransactionStatus != "unsupported" || connected.CurrentKeyspace == nil || *connected.CurrentKeyspace != "dbeer" {
		t.Fatalf("local readonly did not connect: %#v", connected)
	}
	caps := strings.Join(connected.Capabilities, ",")
	if !strings.Contains(caps, "localReadOnly") || strings.Contains(caps, "serverReadOnly") {
		t.Fatal("readonly scope misrepresented")
	}
	for i, sql := range []string{"SELECT custom_udf(value) FROM t", "SELECT uuid(1) FROM t", "SELECT count(value) FROM t", "INSERT INTO t(id) VALUES(1)", "BEGIN BATCH INSERT INTO t(id) VALUES(1); APPLY BATCH"} {
		id := string(rune('a' + i))
		submit(t, manager, protocol.Command{Type: "execute", RequestID: id, QueryID: id, SessionID: connected.SessionID, SQL: sql})
		if response := receive(t, manager); response.Category != "policy" || physical.executions.Load() != 0 {
			t.Fatal("unsafe operation reached Cassandra")
		}
	}
	value := "1"
	changes := &protocol.ChangesRequest{Schema: "dbeer", Table: "items", Columns: []protocol.SnapshotColumn{{Name: "id", Engine: "cassandra", NativeType: "int"}}, Changes: []protocol.RowChange{{Kind: "update", Original: []protocol.CellValue{{Kind: "text", Value: &value}}, Values: []protocol.ColumnAssignment{{Column: "id", Value: protocol.CellValue{Kind: "text", Value: &value}}}}}}
	submit(t, manager, protocol.Command{Type: "changes.apply", RequestID: "grid-blocked", QueryID: "grid-blocked", SessionID: connected.SessionID, Changes: changes})
	if response := receive(t, manager); response.Category != "policy" || physical.executions.Load() != 0 {
		t.Fatal("readonly grid mutation reached Cassandra")
	}
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "cql-read", QueryID: "cql-read", SessionID: connected.SessionID, SQL: "SELECT * FROM t"})
	if receive(t, manager).Type != "query.started" || receive(t, manager).Type != "query.result" || physical.executions.Load() != 1 {
		t.Fatal("local readonly rejected safe SELECT")
	}
	submit(t, manager, protocol.Command{Type: "catalog", RequestID: "cluster-nodes", QueryID: "cluster-nodes", SessionID: connected.SessionID, Catalog: &protocol.CatalogRequest{Kind: "clusterNodes"}})
	if receive(t, manager).Type != "query.started" || receive(t, manager).Type != "query.result" || physical.executions.Load() != 2 {
		t.Fatal("local readonly rejected cluster observations")
	}
}
func TestCassandraStreamPreservesCursorUnknownCountsAndHonestTruncation(t *testing.T) {
	known := false
	sink := &streamSink{sets: []*streamSet{{columns: []protocol.Column{{Name: "id", Engine: "cassandra"}}, summary: protocol.ResultSet{NextCursor: "opaque", AffectedRowCountKnown: &known, Truncated: true, DisplayedRowCount: 1000, DisplayNotice: "Additional Cassandra pages were not fetched."}, ended: true, sent: 1000, seen: 1000}}}
	response := sink.finish(protocol.Response{Type: "query.result", TransactionStatus: "unsupported"})
	if response.NextCursor != "opaque" || response.AffectedRowCountKnown == nil || *response.AffectedRowCountKnown || !response.Truncated || strings.Contains(response.DisplayNotice, "completed in full") {
		t.Fatalf("stream changed Cassandra semantics: %#v", response)
	}
}
