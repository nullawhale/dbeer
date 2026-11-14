package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/mongodb"
	"dbeer/helper/internal/protocol"
	"testing"
)

type engineDiagnosticPolicySession struct {
	*testSession
	diagnostics adapter.ExplainSession
}

func (*engineDiagnosticPolicySession) TransactionStatus() string { return "unsupported" }
func (s *engineDiagnosticPolicySession) ExplainSupport() protocol.ExplainSupport {
	return s.diagnostics.ExplainSupport()
}
func (s *engineDiagnosticPolicySession) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	return s.diagnostics.PrepareExplain(r)
}
func (s *engineDiagnosticPolicySession) ExecuteExplain(ctx context.Context, c protocol.Command) protocol.Response {
	return s.run(ctx, c)
}
func TestEngineDiagnosticGrantsBindActualModeExactBytesAndNoSQLContext(t *testing.T) {
	for _, engine := range []string{"mongodb", "cassandra"} {
		physical := &engineDiagnosticPolicySession{testSession: blockingSession()}
		sql := "SELECT * FROM fixture.items WHERE id=1"
		physical.diagnostics = &cassandra.Session{}
		if engine == "mongodb" {
			sql = `{"database":"fixture","collection":"items","find":{}}`
			physical.diagnostics = &mongodb.Session{}
		}
		request := protocol.ExplainRequest{SQL: sql, Mode: "analyze", Context: &protocol.ExplainContext{DocumentID: "source", TargetDocumentID: "target", RangeLength: len(sql), ProfileID: "profile", SessionID: "diagnostic-owner", TransactionStatus: "unsupported"}}
		owner := &owner{id: "diagnostic-owner"}
		policy := protocol.ExecutionPolicy{Environment: "production", ReadOnly: true}
		assess := func() string {
			t.Helper()
			r := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: &request}}}, engine, policy, physical)
			if r.Assessment == nil || r.Assessment.Decision != "confirm" {
				t.Fatal("actual NoSQL diagnostic was not separately confirmed")
			}
			return r.Assessment.Authorization
		}
		token := assess()
		command := protocol.Command{Type: "explain.run", Explain: &request, Authorization: token}
		if !owner.authorize(command, engine, policy, physical) || owner.takeApprovedExplainSQL() == "" {
			t.Fatal("exact approved NoSQL diagnostic blocked")
		}
		if owner.authorize(command, engine, policy, physical) {
			t.Fatal("consumed diagnostic grant replayed")
		}
		for _, mutate := range []func(*protocol.ExplainRequest){func(r *protocol.ExplainRequest) { r.SQL += " " }, func(r *protocol.ExplainRequest) { r.Mode = "plan" }, func(r *protocol.ExplainRequest) {
			binding := *r.Context
			binding.ProfileID = "changed"
			r.Context = &binding
		}, func(r *protocol.ExplainRequest) {
			binding := *r.Context
			binding.SessionID = "other-owner"
			r.Context = &binding
		}} {
			token = assess()
			changed := request
			mutate(&changed)
			if owner.authorize(protocol.Command{Type: "explain.run", Explain: &changed, Authorization: token}, engine, policy, physical) {
				t.Fatal("mutated exact operation consumed original grant")
			}
		}
		if engine == "mongodb" {
			planned := request
			planned.Mode = "plan"
			r := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: &planned}}}, engine, policy, physical)
			if r.Assessment == nil || r.Assessment.Decision != "allow" {
				t.Fatal("Mongo queryPlanner forced actual-execution semantics")
			}
		}
		if diagnosticContextEngine("postgresql", "unsupported", physical) || diagnosticContextEngine("mysql", "unsupported", physical) {
			t.Fatal("NoSQL context widened relational admission")
		}
	}
}
