package schemajob

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"strings"
	"testing"
)

type diffSession struct {
	fakeSession
	value string
}

func (s *diffSession) ReadSchema(ctx context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	if !s.readonly.Load() {
		panic("definition capture is not read-only")
	}
	ref := sc.Ref{Kind: "table", Schema: spec.Schemas[0], Name: "fixture"}
	typ := sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: "pg_catalog", Name: "text"}, Kind: "builtin", Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
	value := strings.Repeat("unchanged ", 40) + s.value
	column := sc.Column{Ref: sc.Ref{Kind: "column", Schema: ref.Schema, Table: ref.Name, Name: "label"}, Ordinal: sc.Known(0), Type: sc.Known(typ), Nullable: sc.Known(true), Default: sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: "text", Value: &value}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}
	table := sc.Table{Ref: ref, Kind: sc.Known("r"), Storage: sc.Known("p"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete([]sc.Column{column}), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	if e := sink.Table(table); e != nil {
		return e
	}
	if e := sink.Inventory(sc.Inventory{Schema: ref.Schema, Existence: "present", Tables: sc.Complete([]sc.Ref{ref}), Types: sc.Complete[sc.Ref](nil)}); e != nil {
		return e
	}
	return sink.Context(sc.CaptureContext{Engine: "postgresql", Version: "17", Database: "fixture", StartedAt: "2026-10-22T00:00:00Z", FinishedAt: "2026-10-22T00:00:01Z", Visibility: "complete", Consistency: "repeatableRead", EngineContext: sc.Known([]sc.Option{})})
}
func TestDiffOperationBindsCapturedDifference(t *testing.T) {
	m, e := New(func(_ context.Context, c protocol.Connection) (adapter.Session, error) {
		return &diffSession{value: c.Database}, nil
	}, Options{Root: t.TempDir(), RenderDefinition: postgres.RenderSchemaDefinition})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	c := startCommand()
	c.SchemaComparison.Source.Connection.Database = "before"
	c.SchemaComparison.Target.Connection.Database = "after"
	started := m.Handle(c)
	id := started.SchemaComparison.JobID
	waitState(t, m, id, "completed")
	r := m.Handle(protocol.Command{Type: "schema.diff", RequestID: "diff", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, Offset: 0}})
	if r.SchemaComparison == nil || r.SchemaComparison.Diff == nil || r.SchemaComparison.Offset == nil || *r.SchemaComparison.Offset != 0 || r.RequestID != "diff" {
		t.Fatal("bound diff unavailable")
	}
	if r.SchemaComparison.Diff.Status != "complete" {
		t.Fatal("small captured property diff incomplete")
	}
	if r.SchemaComparison.Diff.Lines[0].Source.Text != `CREATE TABLE "b"."fixture" (` {
		t.Fatal("diff is not mapped readable SQL")
	}
	found := false
	for _, line := range r.SchemaComparison.Diff.Lines {
		if line.Source != nil && strings.Contains(line.Source.Text, "before") && line.Target != nil && strings.Contains(line.Target.Text, "after") {
			found = true
		}
	}
	if !found {
		t.Fatal("SQL definition did not retain full captured default")
	}
	for _, request := range []*protocol.SchemaComparisonRequest{{JobID: id, Offset: -1}, {JobID: id, Offset: 100}, {JobID: "other"}} {
		if out := m.Handle(protocol.Command{Type: "schema.diff", SchemaComparison: request}); out.Type != "error" {
			t.Fatal("invalid selection accepted")
		}
	}
}
