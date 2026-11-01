package session

import (
	"context"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type explainTestSession struct {
	*testSession
	calls atomic.Int32
}

func (s *explainTestSession) ExplainSupport() protocol.ExplainSupport {
	return adapter.ExplainSupport("postgresql", "17.6")
}
func (s *explainTestSession) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	return adapter.PrepareExplain(s.ExplainSupport(), r)
}
func (s *explainTestSession) ExecuteExplain(ctx context.Context, c protocol.Command) protocol.Response {
	s.calls.Add(1)
	p, _ := s.PrepareExplain(*c.Explain)
	if p.Preview.SQL != c.PreparedExplainSQL {
		return protocol.ErrorResponse(c, "policy", "prepared SQL changed")
	}
	return s.run(ctx, c)
}
func TestExplainPolicyGrantBindsModeSQLSessionAndPreparedSQL(t *testing.T) {
	physical := &explainTestSession{testSession: blockingSession()}
	for _, readOnly := range []bool{false, true} {
		for _, mode := range []string{"plan", "analyze"} {
			for _, sql := range []string{"SELECT 1", "SELECT fixture_unknown()"} {
				policy := protocol.ExecutionPolicy{Environment: "production", ReadOnly: readOnly}
				o := &owner{id: "sql-a"}
				r := &protocol.ExplainRequest{SQL: sql, Mode: mode}
				operation := protocol.OperationRequest{Type: "explain.run", Explain: r}
				assess := func() protocol.Response {
					return o.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, "postgresql", policy, physical)
				}
				a := assess().Assessment
				if a == nil {
					t.Fatal("assessment")
				}
				expected := "allow"
				if sql != "SELECT 1" || mode == "analyze" {
					expected = "confirm"
				}
				if readOnly && sql != "SELECT 1" {
					expected = "deny"
				}
				if a.Decision != expected || a.Operations[0].Explain == nil {
					t.Fatal("decision/preview")
				}
				c := protocol.Command{Type: "explain.run", Explain: r}
				if o.authorize(c, "postgresql", policy) {
					t.Fatal("ungranted explain")
				}
				a = assess().Assessment
				c.Authorization = a.Authorization
				if o.authorize(c, "postgresql", policy) != (expected != "deny") {
					t.Fatal("policy enforcement")
				}
				if expected != "deny" && o.takeApprovedExplainSQL() != a.Operations[0].Explain.SQL {
					t.Fatal("exact generated SQL not retained")
				}
				if o.authorize(c, "postgresql", policy) {
					t.Fatal("reused grant")
				}
				for _, mutation := range []string{"sql", "mode", "session"} {
					a = assess().Assessment
					c.Authorization = a.Authorization
					changed := *r
					c.Explain = &changed
					if mutation == "sql" {
						changed.SQL += " "
					}
					if mutation == "mode" {
						changed.Mode = map[string]string{"plan": "analyze", "analyze": "plan"}[mode]
					}
					if mutation == "session" {
						other := &owner{id: "sql-b"}
						if other.authorize(c, "postgresql", policy) {
							t.Fatal("cross-session grant")
						}
					} else if o.authorize(c, "postgresql", policy) {
						t.Fatal("changed request reused grant")
					}
				}
			}
		}
	}
}
func TestExplainManagerLifecycleAndPreDispatchCancellation(t *testing.T) {
	physical := &explainTestSession{testSession: blockingSession()}
	entered := make(chan struct{}, 1)
	physical.run = func(ctx context.Context, c protocol.Command) protocol.Response {
		entered <- struct{}{}
		<-ctx.Done()
		r := protocol.ErrorResponse(c, "cancelled", "Cancelled")
		r.Connected = true
		r.TransactionStatus = "idle"
		return r
	}
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer manager.Close()
	id := openTestSession(t, manager, "open")
	request := &protocol.ExplainRequest{SQL: "SELECT 1", Mode: "analyze"}
	assess := func() string {
		submit(t, manager, protocol.Command{Type: "operation.assess", RequestID: "review", SessionID: id, QueryID: "review", Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: request}}})
		a := receive(t, manager)
		if a.Assessment == nil || a.Assessment.Decision != "confirm" {
			t.Fatal("review")
		}
		return a.Assessment.Authorization
	}
	c := protocol.Command{Type: "explain.run", RequestID: "run", SessionID: id, QueryID: "run", Explain: request, Authorization: assess()}
	submit(t, manager, c)
	if r := receive(t, manager); r.Type != "query.started" {
		t.Fatal("started")
	}
	<-entered
	ack := manager.Control(protocol.Command{Type: "cancel", RequestID: "stop", SessionID: id, QueryID: c.QueryID})
	if ack == nil || ack.Status != "accepted" {
		t.Fatal("cancel ack")
	}
	terminal := receive(t, manager)
	if terminal.Type != "error" || terminal.Category != "cancelled" || terminal.OutcomeUnknown || physical.calls.Load() != 1 {
		t.Fatal("terminal cancellation")
	}
	c.RequestID = "queued"
	c.QueryID = "queued"
	c.Authorization = assess()
	manager.markPending(c)
	ack = manager.Control(protocol.Command{Type: "cancel", RequestID: "stop-queued", SessionID: id, QueryID: c.QueryID})
	if ack == nil || ack.Status != "accepted" {
		t.Fatal("queued cancel")
	}
	manager.Commands() <- c
	terminal = receive(t, manager)
	if !terminal.SQLNotExecuted || terminal.OutcomeUnknown || physical.calls.Load() != 1 {
		t.Fatal("queued command reached SQL")
	}
}
