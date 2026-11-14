package sqlite

import (
	"context"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func TestSQLiteAuthoredDefaultsGeneratedAndIdentity(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	expression := "lower('ORIGINAL')"
	target := tableedit.Target{Schema: "main", Table: "authored", Create: true}
	b, e := store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{
		{Name: "id", Type: tableedit.DataType{Kind: "integer"}, Nullable: false, Default: tableedit.Default{Kind: "none"}, Identity: &tableedit.Identity{Kind: "autoIncrement"}},
		{Name: "value", Type: tableedit.DataType{Kind: "text"}, Nullable: true, Default: tableedit.Default{Kind: "expression", Value: &expression}},
		{Name: "derived", Type: tableedit.DataType{Kind: "text"}, Nullable: true, Default: tableedit.Default{Kind: "none"}, Generated: &tableedit.Generation{Storage: "stored", Expression: "value || '-derived'"}},
	}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "primary", Name: "authored_id", Columns: []string{"id"}}}}
	p, e := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	rows, _, e := s.query(ctx, "SELECT count(*) FROM sqlite_schema WHERE name='authored'")
	if e != nil || cellInt(rows[0][0]) != 0 {
		t.Fatal("Preview created or evaluated the authored table")
	}
	out, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "create-authored"})
	if e != nil || out.Outcome.State != "applied" {
		t.Fatal("SQLite authored create failed")
	}
	toolExec(t, s, "INSERT INTO authored DEFAULT VALUES")
	rows, _, e = s.query(ctx, "SELECT id,value,derived FROM authored")
	if e != nil || cellInt(rows[0][0]) != 1 || cellText(rows[0][1]) != "original" || cellText(rows[0][2]) != "original-derived" {
		t.Fatal("authored properties lost")
	}
	target.Create = false
	b, e = store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	d = tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "virtual_added", Type: tableedit.DataType{Kind: "text"}, Nullable: true, Default: tableedit.Default{Kind: "none"}, Generated: &tableedit.Generation{Storage: "virtual", Expression: "value || '-virtual'"}}}}
	p, e = store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	out, e = store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "virtual-add"})
	if e != nil || out.Outcome.State != "applied" {
		t.Fatal("SQLite virtual generated addition failed")
	}
	rows, _, e = s.query(ctx, "SELECT virtual_added FROM authored")
	if e != nil || cellText(rows[0][0]) != "original-virtual" {
		t.Fatal("virtual expression semantics lost")
	}
	b, e = store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	d.Columns[0].Name = "stored_added"
	d.Columns[0].Generated.Storage = "stored"
	if _, e = store.PreviewContext(ctx, s, b.Baseline.ID, d); e == nil {
		t.Fatal("SQLite unsupported stored ADD was silently accepted")
	}
	d.Columns[0].Generated = nil
	d.Columns[0].Default = tableedit.Default{Kind: "expression", Value: &expression}
	if _, e = store.PreviewContext(ctx, s, b.Baseline.ID, d); e == nil {
		t.Fatal("SQLite unsupported expression-default ADD was silently accepted")
	}
}
