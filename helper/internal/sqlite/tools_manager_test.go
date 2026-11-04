package sqlite_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"dbeer/helper/internal/datacomparisonjob"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/schemajob"
	"dbeer/helper/internal/sqlite"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
)

func managerFile(t *testing.T, name, value string) protocol.Connection {
	t.Helper()
	path := filepath.Join(t.TempDir(), name+".sqlite")
	if err := sqlite.Create(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	c := protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}}
	s, err := sqlite.Open(context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, sql := range []string{"CREATE TABLE records(id INTEGER PRIMARY KEY,value)", "INSERT INTO records VALUES(1," + value + ")"} {
		if r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql}); r.Type == "error" {
			t.Fatalf("fixture SQL: %#v", r)
		}
	}
	return c
}
func TestSQLiteSchemaManagerAndSQLPlan(t *testing.T) {
	a := managerFile(t, "a", "42")
	b := managerFile(t, "b", "'42'")
	m, err := schemajob.New(sqlite.Open, schemajob.Options{Root: t.TempDir(), RenderDefinition: sqlite.RenderSchemaDefinition, RenderPlan: func(ctx context.Context, r sc.Report) (syncplan.Plan, error) {
		return syncplan.Schema(ctx, r, sqlite.RenderSynchronizationSchema)
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	r := m.Handle(protocol.Command{Type: "schema.start", SchemaComparison: &protocol.SchemaComparisonRequest{Source: &protocol.SchemaSide{Connection: a}, Target: &protocol.SchemaSide{Connection: b}, Mappings: &sc.Mappings{Schemas: []sc.NamePair{{Source: "main", Target: "main"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}}})
	if r.SchemaComparison == nil {
		t.Fatalf("schema rejected: %#v", r)
	}
	id := r.SchemaComparison.JobID
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		r = m.Handle(protocol.Command{Type: "schema.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
		if r.SchemaComparison.State == "completed" {
			if !r.SchemaComparison.Summary.FullEquality {
				t.Fatalf("identical schema not equal: %#v", r.SchemaComparison.Summary)
			}
			plan := m.Handle(protocol.Command{Type: "schema.plan", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, ModelDigest: r.SchemaComparison.Summary.ModelDigest}})
			if plan.SchemaComparison == nil || plan.SchemaComparison.Plan == nil {
				t.Fatalf("plan unavailable: %#v", plan)
			}
			return
		}
		if r.SchemaComparison.State == "failed" {
			t.Fatalf("schema failed: %#v", r.SchemaComparison)
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("schema manager timed out")
}
func TestSQLiteDataManagerDistinguishesStorageClass(t *testing.T) {
	a := managerFile(t, "a", "42")
	b := managerFile(t, "b", "'42'")
	m, err := datacomparisonjob.New(sqlite.Open, datacomparisonjob.Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	filters := []tc.Filter{}
	sideA := protocol.DataReadSide{Connection: a, Table: tc.Table{Schema: "main", Name: "records"}, Filters: &filters, ReadLimit: 10000}
	sideB := sideA
	sideB.Connection = b
	wait := func(r protocol.Response) *protocol.DataComparisonResponse {
		t.Helper()
		if r.DataComparison == nil {
			t.Fatalf("data rejected: %#v", r)
		}
		id := r.DataComparison.JobID
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			r = m.Handle(protocol.Command{Type: "data.status", DataComparison: &protocol.DataComparisonRequest{JobID: id}})
			if r.DataComparison.State != "pending" && r.DataComparison.State != "running" {
				if r.DataComparison.State != "completed" {
					t.Fatalf("data failed: %#v", r.DataComparison)
				}
				return r.DataComparison
			}
			time.Sleep(time.Millisecond)
		}
		t.Fatal("data manager timed out")
		return nil
	}
	described := wait(m.Handle(protocol.Command{Type: "data.describe", DataComparison: &protocol.DataComparisonRequest{Source: &sideA, Target: &sideB}}))
	sideA.DescriptorDigest = described.Descriptors.Source.Digest
	sideB.DescriptorDigest = described.Descriptors.Target.Digest
	m.Close()
	m, err = datacomparisonjob.New(sqlite.Open, datacomparisonjob.Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	result := wait(m.Handle(protocol.Command{Type: "data.start", DataComparison: &protocol.DataComparisonRequest{Source: &sideA, Target: &sideB, Columns: []tc.Mapping{{Source: "id", Target: "id", Key: true}, {Source: "value", Target: "value"}}, Originals: "allColumns"}}))
	if result.Summary.Comparison.ChangedRows != 1 || result.Summary.Comparison.FullEquality {
		t.Fatalf("integer and text were merged: %#v", result.Summary)
	}
}
