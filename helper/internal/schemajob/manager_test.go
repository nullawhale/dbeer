package schemajob

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

type fakeSession struct {
	readonly, closed atomic.Bool
	gate             <-chan struct{}
	entered          chan<- struct{}
}

func (s *fakeSession) Execute(context.Context, protocol.Command) protocol.Response {
	panic("schema comparison executed caller SQL")
}
func (s *fakeSession) TransactionStatus() string                   { return "idle" }
func (s *fakeSession) Close()                                      { s.closed.Store(true) }
func (s *fakeSession) SetReadOnly(_ context.Context, v bool) error { s.readonly.Store(v); return nil }
func (s *fakeSession) ReadSchema(ctx context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	if !s.readonly.Load() {
		panic("metadata not read only")
	}
	if s.entered != nil {
		s.entered <- struct{}{}
	}
	if s.gate != nil {
		select {
		case <-s.gate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	for _, name := range spec.Schemas {
		if e := sink.Inventory(sc.Inventory{Schema: name, Existence: "present", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}); e != nil {
			return e
		}
	}
	return sink.Context(sc.CaptureContext{Engine: "postgresql", Version: "17", Database: "fixture", StartedAt: "2026-10-22T00:00:00Z", FinishedAt: "2026-10-22T00:00:01Z", Visibility: "complete", Consistency: "repeatableRead", EngineContext: sc.Known([]sc.Option{})})
}
func startCommand() protocol.Command {
	return protocol.Command{Type: "schema.start", RequestID: "start", SchemaComparison: &protocol.SchemaComparisonRequest{Source: &protocol.SchemaSide{Connection: protocol.Connection{}}, Target: &protocol.SchemaSide{Connection: protocol.Connection{}}, Mappings: &sc.Mappings{Schemas: []sc.NamePair{{Source: "a", Target: "b"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}}}
}
func waitState(t *testing.T, m *Manager, id, state string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r := m.Handle(protocol.Command{Type: "schema.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
		if r.SchemaComparison != nil && r.SchemaComparison.State == state {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("schema worker did not reach " + state)
}
func TestTwoIndependentReadOnlyOwnersAndImmutableReport(t *testing.T) {
	var opened atomic.Int32
	sessions := make(chan *fakeSession, 2)
	m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		s := &fakeSession{}
		opened.Add(1)
		sessions <- s
		return s, nil
	}, Options{Root: t.TempDir(), Deadline: time.Second})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	r := m.Handle(startCommand())
	if r.SchemaComparison == nil || r.SchemaComparison.State != "pending" {
		t.Fatal("start did not return pending")
	}
	id := r.SchemaComparison.JobID
	waitState(t, m, id, "completed")
	if opened.Load() != 2 {
		t.Fatal("sessions shared")
	}
	for range 2 {
		if s := <-sessions; !s.closed.Load() || !s.readonly.Load() {
			t.Fatal("session lifecycle incorrect")
		}
	}
	page := m.Handle(protocol.Command{Type: "schema.export", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, MaxBytes: 32}})
	if page.SchemaComparison == nil || page.SchemaComparison.Export == nil {
		t.Fatal("completed report could not be read")
	}
	root := m.root
	m.Close()
	if _, e = os.Stat(root); !os.IsNotExist(e) {
		t.Fatal("scratch survived shutdown")
	}
}
func TestCancelDuringLateOpenClosesOnOwner(t *testing.T) {
	gate := make(chan struct{})
	entered := make(chan struct{}, 2)
	sessions := make(chan *fakeSession, 2)
	m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		entered <- struct{}{}
		<-gate
		s := &fakeSession{}
		sessions <- s
		return s, nil
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	r := m.Handle(startCommand())
	id := r.SchemaComparison.JobID
	<-entered
	<-entered
	out := m.Handle(protocol.Command{Type: "schema.cancel", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
	if out.SchemaComparison.State != "cancelled" {
		t.Fatal("cancel did not acknowledge promptly")
	}
	close(gate)
	m.Close()
	for range 2 {
		if !(<-sessions).closed.Load() {
			t.Fatal("late open leaked")
		}
	}
}
