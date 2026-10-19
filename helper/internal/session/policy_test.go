package session

import (
	"context"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func applyFixture() *protocol.ChangesRequest {
	value := "1"
	return &protocol.ChangesRequest{Schema: "public", Table: "demo", Columns: []protocol.SnapshotColumn{{Name: "id", Engine: "postgresql", NativeType: "int4"}}, Changes: []protocol.RowChange{{Kind: "delete", Original: []protocol.CellValue{{Kind: "text", Value: &value}}}}}
}

func TestExecutionPolicyMatrixAndExactAuthorization(t *testing.T) {
	for _, environment := range []string{"unspecified", "development", "staging", "production"} {
		for _, readOnly := range []bool{false, true} {
			policy := protocol.ExecutionPolicy{Environment: environment, ReadOnly: readOnly}
			for _, test := range []struct{ sql, kind string }{
				{"SELECT 'DELETE FROM demo'", "read"},
				{"WITH changed AS (UPDATE demo SET id=2 WHERE id=1 RETURNING *) SELECT * FROM changed", "write"},
				{"DELETE FROM demo", "destructive"}, {"EXPLAIN ANALYZE DELETE FROM demo", "destructive"},
				{"SELECT custom_side_effect()", "unknown"}, {"SET default_transaction_read_only=off", "unknown"},
			} {
				t.Run(environment+"/"+test.kind+"/readonly="+map[bool]string{true: "true", false: "false"}[readOnly], func(t *testing.T) {
					owner := &owner{id: "session-a"}
					operation := protocol.OperationRequest{Type: "execute", SQL: test.sql}
					response := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, "postgresql", policy)
					assessment := response.Assessment
					if assessment == nil || assessment.Operations[0].Kind != test.kind {
						t.Fatal("unexpected structural assessment")
					}
					command := protocol.Command{Type: "execute", SQL: test.sql}
					direct := owner.authorize(command, "postgresql", policy)
					expectedDirect := !readOnly && test.kind == "write" && environment != "production" || test.kind == "read"
					if direct != expectedDirect {
						t.Fatal("raw execution bypassed the policy")
					}
					response = owner.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, "postgresql", policy)
					command.Authorization = response.Assessment.Authorization
					permitted := owner.authorize(command, "postgresql", policy)
					if permitted != (test.kind == "read" || !readOnly) {
						t.Fatal("confirmed execution violated readonly")
					}
					if command.Authorization != "" && owner.authorize(command, "postgresql", policy) {
						t.Fatal("confirmation was reused")
					}
				})
			}
		}
	}
}

func TestGrantBindsSQLExportApplySnapshotSessionAndOrder(t *testing.T) {
	policy := protocol.ExecutionPolicy{Environment: "production"}
	export := &protocol.ExportRequest{Path: "/tmp/export.json", Format: "json"}
	cases := []struct {
		name      string
		operation protocol.OperationRequest
		mutate    func(*protocol.Command)
	}{
		{"sql", protocol.OperationRequest{Type: "execute", SQL: "DELETE FROM demo"}, func(c *protocol.Command) { c.SQL += " WHERE id=1" }},
		{"export", protocol.OperationRequest{Type: "execute", SQL: "SELECT 1", Export: export}, func(c *protocol.Command) { c.Export = &protocol.ExportRequest{Path: "/tmp/other.json", Format: "json"} }},
		{"apply snapshot", protocol.OperationRequest{Type: "changes.apply", Changes: applyFixture()}, func(c *protocol.Command) {
			c.Changes = applyFixture()
			v := "2"
			c.Changes.Changes[0].Original[0].Value = &v
		}},
		{"operation type", protocol.OperationRequest{Type: "execute", SQL: "DELETE FROM demo"}, func(c *protocol.Command) { c.Type = "changes.apply"; c.SQL = ""; c.Changes = applyFixture() }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			other := &owner{id: "session-b"}
			owner := &owner{id: "session-a"}
			response := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{test.operation}}, "postgresql", policy)
			token := response.Assessment.Authorization
			command := protocol.Command{Type: test.operation.Type, SQL: test.operation.SQL, Export: test.operation.Export, Changes: test.operation.Changes, Authorization: token}
			if other.authorize(command, "postgresql", policy) {
				t.Fatal("cross-session replay succeeded")
			}
			test.mutate(&command)
			if owner.authorize(command, "postgresql", policy) {
				t.Fatal("changed operation reused confirmation")
			}
			command = protocol.Command{Type: test.operation.Type, SQL: test.operation.SQL, Export: test.operation.Export, Changes: test.operation.Changes, Authorization: token}
			if owner.authorize(command, "postgresql", policy) {
				t.Fatal("invalidated confirmation survived mutation")
			}
		})
	}
	owner := &owner{id: "session-a"}
	operations := []protocol.OperationRequest{{Type: "execute", SQL: "SELECT 1"}, {Type: "execute", SQL: "DELETE FROM demo"}}
	token := owner.assess(protocol.Command{Operations: operations}, "postgresql", policy).Assessment.Authorization
	if owner.authorize(protocol.Command{Type: "execute", SQL: operations[1].SQL, Authorization: token}, "postgresql", policy) {
		t.Fatal("script order changed")
	}
}

type readonlyFixture struct {
	testSession
	enabled    atomic.Bool
	executions atomic.Int32
}

func (physical *readonlyFixture) SetReadOnly(context.Context, bool) error {
	physical.enabled.Store(true)
	return nil
}
func (physical *readonlyFixture) Execute(_ context.Context, command protocol.Command) protocol.Response {
	physical.executions.Add(1)
	return fakeResult(command)
}

func TestReadonlyManagerBlocksAllRawExecutionPathsBeforeAdapter(t *testing.T) {
	physical := &readonlyFixture{testSession: testSession{closed: make(chan struct{})}}
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer manager.Close()
	policy := protocol.ExecutionPolicy{Environment: "production", ReadOnly: true}
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Policy: &policy}})
	connected := receive(t, manager)
	if connected.Type != "connect.result" || !physical.enabled.Load() {
		t.Fatal("server readonly was not installed before connection acknowledgement")
	}
	for index, command := range []protocol.Command{
		{Type: "execute", SQL: "INSERT INTO demo VALUES(1)"},
		{Type: "execute", SQL: "WITH d AS (DELETE FROM demo RETURNING *) SELECT * FROM d"},
		{Type: "execute", SQL: "SELECT custom_side_effect()"},
		{Type: "execute", SQL: "DELETE FROM demo", Export: &protocol.ExportRequest{Path: "/tmp/rejected.json", Format: "json"}},
		{Type: "changes.apply", Changes: applyFixture()},
	} {
		command.RequestID = string(rune('a' + index))
		command.QueryID = command.RequestID
		command.SessionID = connected.SessionID
		submit(t, manager, command)
		response := receive(t, manager)
		if response.Type != "error" || response.Category != "policy" || !response.Connected || physical.executions.Load() != 0 {
			t.Fatal("readonly operation reached adapter")
		}
	}
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "read", QueryID: "read", SessionID: connected.SessionID, SQL: "SELECT 1"})
	if receive(t, manager).Type != "query.started" || receive(t, manager).Type != "query.result" || physical.executions.Load() != 1 {
		t.Fatal("readonly blocked a known read")
	}
}

func TestBatchAuthorizationIsDestroyedByCancelAndExecutionError(t *testing.T) {
	var executions atomic.Int32
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		return &testSession{closed: make(chan struct{}), run: func(_ context.Context, command protocol.Command) protocol.Response {
			executions.Add(1)
			response := protocol.ErrorResponse(command, "sql", "Fixture error.")
			response.Connected = true
			response.TransactionStatus = "idle"
			return response
		}}, nil
	})
	defer manager.Close()
	id := openTestSession(t, manager, "connect")
	operations := []protocol.OperationRequest{{Type: "execute", SQL: "SELECT 1"}, {Type: "execute", SQL: "DELETE FROM demo"}}
	assess := func(request string) string {
		submit(t, manager, protocol.Command{Type: "operation.assess", RequestID: request, SessionID: id, QueryID: request, Operations: operations})
		response := receive(t, manager)
		if response.Type != "operation.assessment" || response.Assessment == nil {
			t.Fatal("batch was not assessed")
		}
		return response.Assessment.Authorization
	}
	token := assess("assessment-error")
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "first", SessionID: id, QueryID: "first", SQL: operations[0].SQL, Authorization: token})
	if receive(t, manager).Type != "query.started" || receive(t, manager).Category != "sql" {
		t.Fatal("fixture did not fail its first execution")
	}
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "second", SessionID: id, QueryID: "second", SQL: operations[1].SQL, Authorization: token})
	if receive(t, manager).Category != "policy" || executions.Load() != 1 {
		t.Fatal("error left the remaining script authorization usable")
	}
	token = assess("assessment-cancel")
	response := manager.Control(protocol.Command{Type: "cancel", RequestID: "cancel", SessionID: id, QueryID: "assessment-cancel"})
	if response == nil || response.Type != "cancel.ack" {
		t.Fatal("batch cancellation was not acknowledged")
	}
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "after-cancel", SessionID: id, QueryID: "after-cancel", SQL: operations[0].SQL, Authorization: token})
	if receive(t, manager).Category != "policy" || executions.Load() != 1 {
		t.Fatal("cancel left batch authorization usable")
	}
}
