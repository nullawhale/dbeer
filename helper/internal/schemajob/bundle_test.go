package schemajob

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
)

func bundleStartCommand() protocol.Command {
	return protocol.Command{Type: "schema.bundle.start", RequestID: "bundle-start", SchemaComparison: &protocol.SchemaComparisonRequest{Source: &protocol.SchemaSide{Connection: protocol.Connection{}}, Schemas: []string{"public"}}}
}
func waitBundle(t *testing.T, m *Manager, id, state string) *protocol.SchemaComparisonResponse {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r := m.Handle(protocol.Command{Type: "schema.bundle.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
		if r.SchemaComparison != nil && r.SchemaComparison.State == state {
			return r.SchemaComparison
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("bundle worker did not reach " + state)
	return nil
}
func bundleRenderer(context.Context, sc.Capture, sc.Ref) (sc.Definition, error) {
	return sc.Definition{SQL: "CREATE SCHEMA unsafe_prefix;", Limited: true}, nil
}
func TestBundleOwnsExactlyOneReadonlyCapture(t *testing.T) {
	var opened atomic.Int32
	var session *fakeSession
	m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		opened.Add(1)
		session = &fakeSession{}
		return session, nil
	}, Options{Root: t.TempDir(), RenderDefinition: bundleRenderer})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	started := m.Handle(bundleStartCommand())
	if started.SchemaComparison == nil {
		t.Fatal("bundle did not start")
	}
	id := started.SchemaComparison.JobID
	status := waitBundle(t, m, id, "completed")
	if status.Summary != nil || status.BundleSummary == nil || status.BundleSummary.Engine != "postgresql" || opened.Load() != 1 || !session.closed.Load() || !session.readonly.Load() {
		t.Fatal("bundle fabricated a comparison or shared an owner")
	}
	for _, kind := range []string{"schema.status", "schema.cancel", "schema.export"} {
		if r := m.Handle(protocol.Command{Type: kind, SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}}); r.Type != "error" {
			t.Fatal("bundle accessible as comparison")
		}
	}
	r := m.Handle(protocol.Command{Type: "schema.bundle.export", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, ValueRef: "manifest", MaxBytes: 17}})
	if r.SchemaComparison == nil || r.SchemaComparison.Export == nil || r.SchemaComparison.BundleSummary != nil || r.SchemaComparison.Export.SHA256 != status.BundleSummary.Manifest.SHA256 || r.SchemaComparison.Export.ValueRef != "manifest" {
		t.Fatal("bundle file not correlated")
	}
	for _, ref := range []string{"../capture.json", "capture.json", strings.Repeat("a", 64)} {
		if r := m.Handle(protocol.Command{Type: "schema.bundle.export", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, ValueRef: ref}}); r.Type != "error" {
			t.Fatal("unlisted file readable")
		}
	}
}
func TestBundleCancellationAndDeadlineReleaseOwner(t *testing.T) {
	for _, deadline := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "deadline"}[deadline], func(t *testing.T) {
			entered := make(chan struct{}, 1)
			gate := make(chan struct{})
			session := &fakeSession{gate: gate, entered: entered}
			timeout := time.Second
			if deadline {
				timeout = 15 * time.Millisecond
			}
			m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return session, nil }, Options{Root: t.TempDir(), Deadline: timeout, RenderDefinition: bundleRenderer})
			if e != nil {
				t.Fatal(e)
			}
			defer m.Close()
			id := m.Handle(bundleStartCommand()).SchemaComparison.JobID
			<-entered
			if deadline {
				r := waitBundle(t, m, id, "failed")
				if r.Code != "deadline" {
					t.Fatal("deadline not explicit")
				}
			} else {
				r := m.Handle(protocol.Command{Type: "schema.bundle.cancel", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
				if r.SchemaComparison.State != "cancelled" {
					t.Fatal("cancel not acknowledged")
				}
			}
			m.Close()
			if !session.closed.Load() {
				t.Fatal("dedicated owner leaked")
			}
			r := m.Handle(protocol.Command{Type: "schema.bundle.export", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, ValueRef: "manifest"}})
			if r.Type != "error" {
				t.Fatal("retired bundle readable")
			}
		})
	}
}

type deniedBundleSession struct{ fakeSession }

func (s *deniedBundleSession) ReadSchema(context.Context, sc.CaptureSpec, sc.Sink) error {
	return errors.New("synthetic secret must not escape")
}
func TestBundleMetadataFailureIsSanitized(t *testing.T) {
	m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		return &deniedBundleSession{}, nil
	}, Options{Root: t.TempDir(), RenderDefinition: bundleRenderer})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	id := m.Handle(bundleStartCommand()).SchemaComparison.JobID
	r := waitBundle(t, m, id, "failed")
	if r.BundleSummary != nil || r.Code != "bundleUnavailable" || strings.Contains(r.Message, "secret") {
		t.Fatal("failure exposed internals or apparently complete bundle")
	}
}
