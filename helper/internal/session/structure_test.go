package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"testing"
)

type structureFake struct{}

func (structureFake) StructureLoad(_ context.Context, t tableedit.Target) (tableedit.Baseline, error) {
	return tableedit.Baseline{Target: t, Engine: "postgresql", Fingerprint: tableedit.Fingerprint(t), Columns: []tableedit.ObservedColumn{}}, nil
}
func (structureFake) StructureRender(tableedit.Baseline, tableedit.Draft) ([]string, []string, error) {
	return []string{"synthetic DDL"}, []string{}, nil
}
func (structureFake) StructureApply(context.Context, tableedit.Baseline, []string) tableedit.Execution {
	return tableedit.Execution{State: "applied"}
}
func structurePlan(t *testing.T, o *owner) tableedit.Apply {
	o.structureOnly = true
	t.Helper()
	a := structureFake{}
	b, e := o.structure.Load(context.Background(), a, tableedit.Target{Schema: "public", Table: "samples", Create: true})
	if e != nil {
		t.Fatal(e)
	}
	p, e := o.structure.Preview(a, b.Baseline.ID, tableedit.Draft{Columns: []tableedit.Column{{Name: "label", Nullable: true, Type: tableedit.DataType{Kind: "text"}, Default: tableedit.Default{Kind: "none"}}}})
	if e != nil {
		t.Fatal(e)
	}
	return tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "exec"}
}
func TestStructurePolicyRequiresExactSingleUseGrant(t *testing.T) {
	for _, environment := range []string{"development", "production"} {
		for _, readonly := range []bool{false, true} {
			o := &owner{id: "session"}
			a := structurePlan(t, o)
			policy := protocol.ExecutionPolicy{Environment: environment, ReadOnly: readonly}
			op := protocol.OperationRequest{Type: "structure.apply", Structure: &a}
			command := protocol.Command{Type: "structure.apply", Structure: &tableedit.Request{Apply: &a}}
			if o.authorize(command, "postgresql", policy) {
				t.Fatal("ungranted DDL admitted")
			}
			r := o.assess(protocol.Command{Operations: []protocol.OperationRequest{op}}, "postgresql", policy)
			if r.Assessment == nil {
				t.Fatal("assessment missing")
			}
			if readonly {
				if r.Assessment.Decision != "deny" {
					t.Fatal("readonly DDL admitted")
				}
				continue
			}
			if environment == "production" && r.Assessment.Decision != "confirm" {
				t.Fatal("production confirmation bypassed")
			}
			command.Authorization = r.Assessment.Authorization
			if !o.authorize(command, "postgresql", policy) {
				t.Fatal("exact reviewed apply rejected")
			}
			if o.authorize(command, "postgresql", policy) {
				t.Fatal("grant reused")
			}
		}
	}
}
func TestStructureGrantRejectsChangedExecutionPlanAndSession(t *testing.T) {
	for _, field := range []string{"execution", "digest", "plan", "session"} {
		o := &owner{id: "owner"}
		a := structurePlan(t, o)
		policy := protocol.ExecutionPolicy{Environment: "production"}
		r := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "structure.apply", Structure: &a}}}, "mysql", policy)
		changed := a
		switch field {
		case "execution":
			changed.ExecutionID = "different"
		case "digest":
			changed.Digest = tableedit.Fingerprint("different")
		case "plan":
			changed.PlanID = "different"
		case "session":
			o = &owner{id: "other"}
		}
		if o.authorize(protocol.Command{Type: "structure.apply", Authorization: r.Assessment.Authorization, Structure: &tableedit.Request{Apply: &changed}}, "mysql", policy) {
			t.Fatal("changed binding reused grant")
		}
	}
}

type isolatedStructureFake struct {
	testSession
	structureFake
	loads    int
	sqlCalls int
}

func (f *isolatedStructureFake) StructureLoad(ctx context.Context, t tableedit.Target) (tableedit.Baseline, error) {
	f.loads++
	return f.structureFake.StructureLoad(ctx, t)
}
func TestStructureSessionsAreExclusiveAndOrdinarySessionsCannotLoadDrafts(t *testing.T) {
	for _, purpose := range []string{"", "structure"} {
		physical := &isolatedStructureFake{testSession: testSession{closed: make(chan struct{})}}
		physical.run = func(ctx context.Context, c protocol.Command) protocol.Response {
			physical.sqlCalls++
			return fakeResult(c)
		}
		manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
		submit(t, manager, protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{SessionPurpose: purpose}})
		connected := receive(t, manager)
		if purpose == "" {
			submit(t, manager, protocol.Command{Type: "structure.load", RequestID: "load", SessionID: connected.SessionID, QueryID: "load-query", Structure: &tableedit.Request{Target: &tableedit.Target{Schema: "public", Table: "samples", Create: true}}})
			if started := receive(t, manager); started.Type != "query.started" {
				t.Fatal("started event missing")
			}
			if response := receive(t, manager); response.Type != "error" || physical.loads != 0 {
				t.Fatal("ordinary session was used for DDL metadata")
			}
		} else {
			submit(t, manager, protocol.Command{Type: "execute", RequestID: "sql", SessionID: connected.SessionID, QueryID: "sql-query", SQL: "SELECT 1"})
			if response := receive(t, manager); response.Type != "error" || !response.SQLNotExecuted || physical.sqlCalls != 0 {
				t.Fatal("dedicated DDL session admitted ordinary SQL")
			}
		}
		manager.Close()
	}
}

func TestClosedStructureSessionHasPositiveIdempotentDisconnectOnlyForKnownDDLIDs(t *testing.T) {
	for _, purpose := range []string{"", "structure"} {
		physical := &testSession{closed: make(chan struct{}), run: func(ctx context.Context, c protocol.Command) protocol.Response { return fakeResult(c) }}
		manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
		submit(t, manager, protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{SessionPurpose: purpose}})
		connected := receive(t, manager)
		if immediate := manager.Control(protocol.Command{Type: "disconnect", RequestID: "first-close", SessionID: connected.SessionID}); immediate != nil {
			t.Fatal("active disconnect did not await physical closure")
		}
		if ack := receive(t, manager); ack.Type != "disconnect.ack" {
			t.Fatal("physical close acknowledgement missing")
		}
		repeated := manager.Control(protocol.Command{Type: "disconnect", RequestID: "repeat-close", SessionID: connected.SessionID})
		if purpose == "structure" && (repeated == nil || repeated.Type != "disconnect.ack") {
			t.Fatal("known closed DDL session could not be cleaned up")
		}
		if purpose == "" && (repeated == nil || repeated.Type != "error") {
			t.Fatal("ordinary SQL disconnect semantics changed")
		}
		unknown := manager.Control(protocol.Command{Type: "disconnect", RequestID: "unknown-close", SessionID: "never-opened"})
		if unknown == nil || unknown.Type != "error" {
			t.Fatal("unknown session was mistaken for positive closure")
		}
		manager.Close()
	}
}
