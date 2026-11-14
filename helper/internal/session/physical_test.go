package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
)

type physicalPolicyFake struct{}

func (physicalPolicyFake) PhysicalPrepare(_ context.Context, d tableedit.PhysicalDraft) (tableedit.PhysicalPlan, error) {
	return tableedit.PhysicalPlan{Engine: "mysql", ServerVersion: 80400, SQL: []string{"reviewed"}, Objects: []tableedit.PhysicalObject{{Target: d.Target}}, EvidenceDigest: strings.Repeat("a", 64)}, nil
}
func (physicalPolicyFake) PhysicalExecute(context.Context, tableedit.PhysicalPlan, func(int, string)) []tableedit.Execution {
	return []tableedit.Execution{{State: "applied"}}
}
func (physicalPolicyFake) PhysicalObserve(context.Context, tableedit.PhysicalPlan) ([]tableedit.PhysicalObject, error) {
	return nil, nil
}
func TestPhysicalGrantRequiresExactConfirmationAndOwningSession(t *testing.T) {
	o := &owner{id: "owner", structureOnly: true}
	draft := tableedit.PhysicalDraft{Version: 1, Target: tableedit.Target{Schema: "app", Table: "t"}, Intent: tableedit.PhysicalIntent{Kind: "storageEngine", Engine: "MyISAM", Algorithm: "COPY", Lock: "EXCLUSIVE"}}
	r, e := o.physicalDDL.Preview(context.Background(), physicalPolicyFake{}, draft)
	if e != nil {
		t.Fatal(e)
	}
	apply := tableedit.Apply{PlanID: r.Plan.ID, Digest: r.Plan.Digest, ExecutionID: "e"}
	op := protocol.OperationRequest{Type: "structure.physical.apply", Structure: &apply}
	c := protocol.Command{Type: op.Type, Structure: &tableedit.Request{Physical: &tableedit.PhysicalRequest{Apply: &apply}}}
	policy := protocol.ExecutionPolicy{Environment: "development"}
	if o.authorize(c, "mysql", policy) {
		t.Fatal("missing exact grant admitted")
	}
	assessment := o.assess(protocol.Command{Operations: []protocol.OperationRequest{op}}, "mysql", policy)
	if assessment.Assessment == nil || assessment.Assessment.Decision != "confirm" {
		t.Fatal(assessment)
	}
	c.Authorization = assessment.Assessment.Authorization
	other := &owner{id: "other", structureOnly: true}
	if other.authorize(c, "mysql", policy) {
		t.Fatal("grant crossed owner")
	}
	changed := c
	copyApply := apply
	copyApply.ExecutionID = "other"
	changed.Structure = &tableedit.Request{Physical: &tableedit.PhysicalRequest{Apply: &copyApply}}
	if o.authorize(changed, "mysql", policy) {
		t.Fatal("grant accepted changed execution ID")
	}
	assessment = o.assess(protocol.Command{Operations: []protocol.OperationRequest{op}}, "mysql", policy)
	c.Authorization = assessment.Assessment.Authorization
	if !o.authorize(c, "mysql", policy) || o.authorize(c, "mysql", policy) {
		t.Fatal("grant not exact single use")
	}
	policy.ReadOnly = true
	assessment = o.assess(protocol.Command{Operations: []protocol.OperationRequest{op}}, "mysql", policy)
	if assessment.Assessment == nil || assessment.Assessment.Decision != "deny" {
		t.Fatal("readonly physical DDL admitted")
	}
}

type physicalManagerFake struct {
	entered chan struct{}
	release chan struct{}
	calls   atomic.Int32
}

func (f *physicalManagerFake) Execute(context.Context, protocol.Command) protocol.Response {
	panic("physical status ran SQL")
}
func (f *physicalManagerFake) Close()                    {}
func (f *physicalManagerFake) TransactionStatus() string { return "idle" }
func (f *physicalManagerFake) PhysicalPrepare(context.Context, tableedit.PhysicalDraft) (tableedit.PhysicalPlan, error) {
	return tableedit.PhysicalPlan{}, tableedit.ErrUnsupported
}
func (f *physicalManagerFake) PhysicalExecute(context.Context, tableedit.PhysicalPlan, func(int, string)) []tableedit.Execution {
	panic("physical status dispatched DDL")
}
func (f *physicalManagerFake) PhysicalObserve(context.Context, tableedit.PhysicalPlan) ([]tableedit.PhysicalObject, error) {
	panic("physical status observed the database")
}
func (f *physicalManagerFake) PhysicalInspect(ctx context.Context, t tableedit.Target) (tableedit.PhysicalInspection, error) {
	f.calls.Add(1)
	close(f.entered)
	select {
	case <-f.release:
	case <-ctx.Done():
	}
	return tableedit.PhysicalInspection{Version: 1, Engine: "postgresql", ServerVersion: 170000, Objects: []tableedit.PhysicalObject{{Target: t, Identity: "1", Kind: "r", Fingerprint: strings.Repeat("a", 64), Columns: []tableedit.ObservedColumn{}, Partitions: []tableedit.PhysicalPartition{}, Indexes: []tableedit.PhysicalIndexState{}, Limitations: []string{}}}, Operations: []string{"concurrentIndex"}}, nil
}
func TestPhysicalManagerStatusFastPathHasExactCorrelationWithoutStarted(t *testing.T) {
	f := &physicalManagerFake{entered: make(chan struct{}), release: make(chan struct{})}
	m := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return f, nil })
	defer m.Close()
	submit(t, m, protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Database: "fixture", SessionPurpose: "structure"}})
	connected := receive(t, m)
	sessionID := connected.SessionID
	if connected.Type != "connect.result" {
		t.Fatal("fixture connection rejected")
	}
	inspect := protocol.Command{Type: "structure.physical.inspect", RequestID: "inspect", SessionID: sessionID, QueryID: "inspect-query", Structure: &tableedit.Request{Physical: &tableedit.PhysicalRequest{Target: &tableedit.Target{Schema: "app", Table: "t"}}}}
	submit(t, m, inspect)
	if r := receive(t, m); r.Type != "query.started" {
		t.Fatal("fixture worker did not start")
	}
	<-f.entered
	for _, invalid := range []bool{false, true} {
		request := &tableedit.PhysicalRequest{}
		if invalid {
			request.Draft = &tableedit.PhysicalDraft{Version: 1}
		}
		c := protocol.Command{Type: "structure.physical.status", RequestID: fmt.Sprintf("status-%t", invalid), SessionID: sessionID, QueryID: fmt.Sprintf("status-query-%t", invalid), Structure: &tableedit.Request{Physical: request}}
		submit(t, m, c)
		r := receive(t, m)
		if r.RequestID != c.RequestID || r.SessionID != sessionID || r.QueryID != c.QueryID {
			t.Fatal("status fast path lost request/session/query correlation")
		}
		if invalid && r.Type != "error" || !invalid && (r.Type != "structure.physical.status.result" || r.Structure == nil || r.Structure.Physical == nil) {
			t.Fatal("status fast path admitted the wrong request shape")
		}
		if f.calls.Load() != 1 {
			t.Fatal("status fast path touched physical metadata")
		}
	}
	close(f.release)
	if r := receive(t, m); r.Type != "structure.physical.inspect.result" || r.RequestID != inspect.RequestID {
		t.Fatal("status interrupted the active worker")
	}
	ordinary := openTestSession(t, m, "ordinary")
	c := protocol.Command{Type: "structure.physical.status", RequestID: "ordinary-status", SessionID: ordinary, QueryID: "ordinary-status-query", Structure: &tableedit.Request{Physical: &tableedit.PhysicalRequest{}}}
	submit(t, m, c)
	if r := receive(t, m); r.Type != "error" || r.RequestID != c.RequestID || r.QueryID != c.QueryID || r.SessionID != ordinary {
		t.Fatal("ordinary session obtained physical status or lost rejection correlation")
	}
}
