package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestStructureAuthoringRenameAndMultipleAppendLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	f.exec("CREATE TABLE " + f.table("rename_source") + " (id integer PRIMARY KEY,label varchar(40) DEFAULT 'kept')")
	f.exec("COMMENT ON COLUMN " + f.table("rename_source") + ".label IS 'preserved comment'")
	f.exec("CREATE INDEX rename_label_index ON " + f.table("rename_source") + "(label)")
	f.exec("INSERT INTO " + f.table("rename_source") + " VALUES(7,'original')")
	f.exec("CREATE TABLE " + f.table("rename_child") + "(owner integer REFERENCES " + f.table("rename_source") + "(id))")
	b, e := store.Load(ctx, s, tableedit.Target{Schema: f.schema, Table: "rename_source"})
	if e != nil {
		t.Fatal(e)
	}
	name, column := "rename_result", "renamed_id"
	draft := tableedit.Draft{AuthoringVersion: 2, RenameTable: &name, Columns: []tableedit.Column{{Name: "first_added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}, {Name: "second_added", Type: tableedit.DataType{Kind: "text"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}, Changes: []tableedit.ColumnChange{{Name: "id", RenameTo: &column}}}
	p, e := store.PreviewContext(ctx, s, b.Baseline.ID, draft)
	if e != nil {
		t.Fatal(e)
	}
	if len(p.Plan.SQL) != 4 || p.Plan.Target.Table != "rename_source" || p.Plan.ResultTarget == nil || p.Plan.ResultTarget.Table != name {
		t.Fatal("rename changed original identity or lost complete multi-step intent")
	}
	out, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "rename"})
	if e != nil {
		t.Fatal(e)
	}
	if out.Outcome.State != "applied" || out.Outcome.Observed == nil || out.Outcome.Observed.Target.Table != name || len(out.Outcome.Observed.Columns) != 4 {
		t.Fatalf("rename outcomes or preservation failed: state=%s steps=%v refresh=%s", out.Outcome.State, out.Outcome.Steps, out.Outcome.RefreshError)
	}
	var count int
	var value string
	if f.observer.QueryRow(ctx, "SELECT count(*),min(label) FROM "+f.table(name)).Scan(&count, &value) != nil || count != 1 || value != "original" {
		t.Fatal("stored rows changed")
	}
}
