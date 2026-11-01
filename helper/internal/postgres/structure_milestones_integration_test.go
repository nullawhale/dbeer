package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func structureRunDraft(t *testing.T, s *Session, target tableedit.Target, d tableedit.Draft, id string) tableedit.Outcome {
	t.Helper()
	store := &tableedit.Store{}
	loaded, e := store.Load(context.Background(), s, target)
	if e != nil {
		t.Fatal("cannot load structure scenario baseline")
	}
	p, e := store.Preview(s, loaded.Baseline.ID, d)
	if e != nil {
		t.Fatalf("structure preview rejected: %v", e)
	}
	r, e := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: id})
	if e != nil || r.Outcome.State != "applied" {
		t.Fatalf("structure scenario %s did not apply: states=%v", id, r.Outcome.Steps)
	}
	for _, step := range r.Outcome.Steps {
		if step.Message != "" {
			t.Fatalf("structure transition not verified: %s", step.Message)
		}
	}
	return *r.Outcome
}
func TestStructureM2M3Integration(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	schema := f.schema
	exec := f.exec
	name := func(n string) string { return f.table(n) }
	ctx := context.Background()
	parentName := "structure_parent"
	childName := "structure_child"
	parent := tableedit.Target{Schema: schema, Table: parentName, Create: true}
	child := tableedit.Target{Schema: schema, Table: childName, Create: true}
	cleanup := func() {
		exec("DROP TABLE IF EXISTS " + name("structure_child"))
		exec("DROP TABLE IF EXISTS " + name("structure_parent"))
	}
	defer cleanup()
	integer := tableedit.DataType{Kind: "integer"}
	varchar := tableedit.DataType{Kind: "varchar", Length: 20}
	none := tableedit.Default{Kind: "none"}
	col := func(n string, typ tableedit.DataType, nullable bool) tableedit.Column {
		return tableedit.Column{Name: n, Type: typ, Nullable: nullable, Default: none}
	}
	pkName := "parent_pk"
	childPK := "child_pk"
	structureRunDraft(t, s, parent, tableedit.Draft{Columns: []tableedit.Column{col("id", integer, false), col("code", varchar, false)}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "primary", Name: pkName, Columns: []string{"id", "code"}}}}, "create_parent")
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{col("id", integer, true), col("code", varchar, true), col("counter", integer, true)}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "primary", Name: childPK, Columns: []string{"id"}}}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "code_index", Columns: []string{"code"}}}}, "create_child")
	child.Create = false
	parent.Create = false
	exec("INSERT INTO " + name("structure_parent") + " (id,code) VALUES (1,'a')")
	exec("INSERT INTO " + name("structure_child") + " (id,code,counter) VALUES (1,'a',3),(2,NULL,3)")
	bigint := tableedit.DataType{Kind: "bigint"}
	required := false
	number := "99"
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "counter", Type: &bigint, Nullable: &required, Default: &tableedit.Default{Kind: "numeric", Value: &number}}}}, "widen")
	var retained int
	if f.observer.QueryRow(ctx, "SELECT count(*) FROM "+name("structure_child")+" WHERE counter=3").Scan(&retained) != nil || retained != 2 {
		t.Fatal("widening did not preserve sample data")
	}
	// A violation is a known server rejection, without an implicit backfill.
	store := &tableedit.Store{}
	b, e := store.Load(ctx, s, child)
	if e != nil {
		t.Fatal(e)
	}
	p, e := store.Preview(s, b.Baseline.ID, tableedit.Draft{Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "code", Nullable: &required}}})
	if e != nil {
		t.Fatal(e)
	}
	r, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "not_null_rejected"})
	if e != nil || r.Outcome.State != "failed" {
		t.Fatal("NOT NULL violation was not a known failure")
	}
	fk := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: "child_foreign", Columns: []string{"id", "code"}, Reference: &parent, ReferenceColumns: []string{"id", "code"}, OnUpdate: "NO ACTION", OnDelete: "RESTRICT"}
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{fk}}, "foreign")
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "unique", Name: "counter_code_unique", Columns: []string{"counter", "code"}}}}, "unique")
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{}, AllowDestructive: true, Keys: []tableedit.KeyEdit{{Action: "replace", Kind: "unique", Name: "counter_code_unique", Columns: []string{"code", "counter"}}}}, "replace_unique")
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{}, AllowDestructive: true, Indexes: []tableedit.IndexEdit{{Action: "replace", Name: "code_index", Columns: []string{"counter", "code"}}}}, "replace_index")
	// Referenced external keys cannot be removed within a one-table draft.
	parentStore := &tableedit.Store{}
	b, e = parentStore.Load(ctx, s, parent)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = parentStore.Preview(s, b.Baseline.ID, tableedit.Draft{Columns: []tableedit.Column{}, AllowDestructive: true, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "primary", Name: pkName}}}); e == nil {
		t.Fatal("incoming external FK dependency was ignored")
	}
	fk.Action = "replace"
	fk.OnDelete = "NO ACTION"
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{}, AllowDestructive: true, Keys: []tableedit.KeyEdit{fk}}, "replace_foreign")
	// Explicit removals and PK replacement are reviewed operations, including
	// their constraint-owned backing indexes. Remove the referencing FK first.
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{}, AllowDestructive: true, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "foreign", Name: "child_foreign"}, {Action: "drop", Kind: "unique", Name: "counter_code_unique"}}, Indexes: []tableedit.IndexEdit{{Action: "drop", Name: "code_index"}}}, "remove_owned_objects")
	structureRunDraft(t, s, parent, tableedit.Draft{Columns: []tableedit.Column{}, AllowDestructive: true, Keys: []tableedit.KeyEdit{{Action: "replace", Kind: "primary", Name: pkName, Columns: []string{"code", "id"}}}}, "replace_primary")
	structureRunDraft(t, s, child, tableedit.Draft{Columns: []tableedit.Column{}, AllowDestructive: true, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "primary", Name: childPK}}}, "remove_primary")
	removed, e := s.StructureLoad(ctx, child)
	if e != nil {
		t.Fatal(e)
	}
	for _, key := range removed.Keys {
		if key.Name == "child_foreign" || key.Name == "counter_code_unique" || key.Name == childPK {
			t.Fatal("removed key remains observed")
		}
	}
	for _, index := range removed.Indexes {
		if index.Name == "code_index" {
			t.Fatal("removed index remains observed")
		}
	}
	// A later failed step leaves the earlier column durable and the final index unstarted.
	b, e = store.Load(ctx, s, child)
	if e != nil {
		t.Fatal(e)
	}
	p, e = store.Preview(s, b.Baseline.ID, tableedit.Draft{Columns: []tableedit.Column{col("partial_added", integer, true)}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "unique", Name: "duplicate_counter_unique", Columns: []string{"counter"}}}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "never_started", Columns: []string{"counter"}}}})
	if e != nil {
		t.Fatal(e)
	}
	r, e = store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "partial"})
	if e != nil || r.Outcome.State != "partiallyApplied" || len(r.Outcome.Steps) != 3 || r.Outcome.Steps[0].State != "applied" || r.Outcome.Steps[1].State != "failed" || r.Outcome.Steps[2].State != "notStarted" {
		t.Fatal("partial completion evidence is incorrect")
	}
	// A cancelled plan cannot dispatch its next step or promise to undo the first.
	b, e = store.Load(ctx, s, child)
	if e != nil {
		t.Fatal(e)
	}
	p, e = store.Preview(s, b.Baseline.ID, tableedit.Draft{Columns: []tableedit.Column{col("cancel_added", integer, true)}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "cancel_unstarted", Columns: []string{"counter"}}}})
	if e != nil {
		t.Fatal(e)
	}
	cancelCtx, cancel := context.WithCancel(ctx)
	s.afterStructureStep = func(i int) {
		if i == 0 {
			cancel()
		}
	}
	r, e = store.Apply(cancelCtx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "cancelled_partial"})
	s.afterStructureStep = nil
	cancel()
	if e != nil || r.Outcome.State != "partiallyApplied" || r.Outcome.Steps[0].State != "applied" || r.Outcome.Steps[1].State != "notStarted" {
		t.Fatal("cancellation lost the acknowledged prefix")
	}
}
