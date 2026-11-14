package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"encoding/json"
	"slices"
	"testing"
)

type dmlPolicySession struct {
	*explainTestSession
	tx string
}

func (s *dmlPolicySession) TransactionStatus() string { return s.tx }
func TestExplainDMLPolicyAndExactOneUseAuthority(t *testing.T) {
	physical := &dmlPolicySession{explainTestSession: &explainTestSession{testSession: blockingSession()}, tx: "idle"}
	owner := &owner{id: "session"}
	request := protocol.ExplainRequest{SQL: "UPDATE sample SET note=:note WHERE id=1", Mode: "analyze", Context: &protocol.ExplainContext{DocumentID: "doc", TargetDocumentID: "target", ProfileID: "profile", SessionID: owner.id, RangeLocation: 19, RangeLength: len("UPDATE sample SET note=:note WHERE id=1"), TransactionStatus: "idle"}, WriteIntent: &protocol.ExplainWriteIntent{Disposition: "currentSession", ExpectedTransactionStatus: "idle"}}
	empty := ""
	request.Parameters = []protocol.QueryParameter{{Name: "note", Type: "text", Value: &empty}}
	assess := func(readonly bool) protocol.Response {
		return owner.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: &request}}}, "postgresql", protocol.ExecutionPolicy{Environment: "development", ReadOnly: readonly}, physical)
	}
	if r := assess(true); r.Assessment == nil || r.Assessment.Decision != "deny" {
		t.Fatal("readonly actual DML allowed")
	}
	if r := assess(false); r.Assessment == nil || r.Assessment.Decision != "confirm" || r.Assessment.Operations[0].Explain.DML == nil {
		t.Fatal("actual DML not forced to exact review")
	}
	for _, mutate := range []func(*protocol.ExplainRequest){
		func(r *protocol.ExplainRequest) { r.WriteIntent.Disposition = "rollback" },
		func(r *protocol.ExplainRequest) { r.WriteIntent.ExpectedTransactionStatus = "transaction" },
		func(r *protocol.ExplainRequest) { r.Context.DocumentID = "changed" },
		func(r *protocol.ExplainRequest) { r.Context.RangeLocation++ },
		func(r *protocol.ExplainRequest) { text := "NULL"; r.Parameters[0].Value = &text },
		func(r *protocol.ExplainRequest) { r.Parameters[0].Value = nil },
	} {
		r := assess(false)
		var changed protocol.ExplainRequest
		raw, _ := json.Marshal(request)
		_ = json.Unmarshal(raw, &changed)
		mutate(&changed)
		if owner.authorize(protocol.Command{Type: "explain.run", Explain: &changed, Authorization: r.Assessment.Authorization}, "postgresql", protocol.ExecutionPolicy{Environment: "development"}, physical) {
			t.Fatal("changed exact DML intent reused grant")
		}
	}
	grant := assess(false).Assessment.Authorization
	physical.tx = "transaction"
	if owner.authorize(protocol.Command{Type: "explain.run", Explain: &request, Authorization: grant}, "postgresql", protocol.ExecutionPolicy{Environment: "development"}, physical) {
		t.Fatal("changed physical transaction reused grant")
	}
	physical.tx = "idle"
	grant = assess(false).Assessment.Authorization
	command := protocol.Command{Type: "explain.run", Explain: &request, Authorization: grant}
	if !owner.authorize(command, "postgresql", protocol.ExecutionPolicy{Environment: "development"}, physical) || owner.takeApprovedExplainSQL() == "" || owner.authorize(command, "postgresql", protocol.ExecutionPolicy{Environment: "development"}, physical) {
		t.Fatal("DML grant not exact and single use")
	}
	request.Mode = "plan"
	request.WriteIntent = nil
	request.Context = nil
	if r := assess(true); r.Assessment == nil || r.Assessment.Decision != "allow" || r.Assessment.Operations[0].Kind != "read" || r.Assessment.Operations[0].Explain.DML == nil {
		t.Fatal("estimated DML is not a read-only plan")
	}
}
func TestExplainDMLOwnerCapability(t *testing.T) {
	physical := &explainTestSession{testSession: blockingSession()}
	manager := New(func(_ context.Context, _ protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer manager.Close()
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Engine: "postgresql", Host: "localhost", Port: 5432, User: "fixture", Database: "fixture"}})
	r := receive(t, manager)
	if r.Type != "connect.result" || !slices.Contains(r.Capabilities, protocol.ExplainDMLCapability) || r.ExplainSupport.DML == nil {
		t.Fatal("owner DML capability missing")
	}
}

type dmlEstimatePolicySession struct {
	*explainTestSession
	engine string
}

func (s *dmlEstimatePolicySession) ExplainSupport() protocol.ExplainSupport {
	return adapter.ExplainSupport(s.engine, map[string]string{"postgresql": "17.6", "mysql": "8.4.13"}[s.engine])
}
func (s *dmlEstimatePolicySession) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	return adapter.PrepareExplain(s.ExplainSupport(), r)
}
func TestEstimatedExplainDMLRetainsReadonlyAndExactRoutineReview(t *testing.T) {
	for _, item := range []struct{ engine, sql, kind string }{
		{"mysql", "INSERT INTO sample(id) VALUES(1)", "read"},
		{"mysql", "INSERT INTO sample SELECT a.id FROM source a JOIN (SELECT fixture_write()) b", "unknown"},
		{"mysql", "UPDATE sample SET id=(SELECT fixture_write()) WHERE id=1", "unknown"},
		{"mysql", "DELETE FROM sample WHERE id=(SELECT fixture_write())", "unknown"},
		{"mysql", "WITH a AS (SELECT fixture_write()) UPDATE sample SET id=1 WHERE id IN (SELECT * FROM a)", "unknown"},
		{"postgresql", "WITH a AS (DELETE FROM sample WHERE id=fixture_write() RETURNING *) SELECT * FROM a", "unknown"},
		{"postgresql", "INSERT INTO sample(id) VALUES(nextval('sequence_name'))", "write"},
		{"mysql", "INSERT INTO sample(id) VALUES(last_insert_id(2))", "write"},
	} {
		physical := &dmlEstimatePolicySession{explainTestSession: &explainTestSession{testSession: blockingSession()}, engine: item.engine}
		owner := &owner{id: "estimate-owner"}
		request := &protocol.ExplainRequest{SQL: item.sql, Mode: "plan"}
		for _, readonly := range []bool{false, true} {
			policy := protocol.ExecutionPolicy{Environment: "development", ReadOnly: readonly}
			r := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: request}}}, item.engine, policy, physical)
			expected := "allow"
			if item.kind != "read" {
				expected = "confirm"
				if readonly {
					expected = "deny"
				}
			}
			if r.Assessment == nil || r.Assessment.Decision != expected || r.Assessment.Operations[0].Kind != item.kind || len(r.Assessment.Operations[0].Statements) != 1 {
				t.Fatal("estimated DML bypassed routine assessment")
			}
			if physical.calls.Load() != 0 {
				t.Fatal("routine review executed estimated SQL")
			}
		}
	}
}
