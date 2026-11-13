package mysql

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"os"
	"testing"
	"time"
)

func TestStructureAuthoringRenameAndMultipleAppendLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	settings := integrationSettings(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	name := fmt.Sprintf("e1_rename_%d", time.Now().UnixNano())
	next := name + "_new"
	child := name + "_child"
	defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(name)+","+QuoteIdentifier(next))
	defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(child))
	run(t, s, "CREATE TABLE "+QuoteIdentifier(name)+"(id INT PRIMARY KEY,label VARCHAR(40) DEFAULT 'kept' COMMENT 'preserved comment',KEY label_idx(label)) ENGINE=InnoDB")
	run(t, s, "INSERT INTO "+QuoteIdentifier(name)+" VALUES(7,'original')")
	run(t, s, "CREATE TABLE "+QuoteIdentifier(child)+"(owner INT,CONSTRAINT child_owner FOREIGN KEY(owner) REFERENCES "+QuoteIdentifier(name)+"(id)) ENGINE=InnoDB")
	b, e := store.Load(ctx, s, tableedit.Target{Schema: settings.Database, Table: name})
	if e != nil {
		t.Fatal(e)
	}
	col := "renamed_id"
	draft := tableedit.Draft{AuthoringVersion: 2, RenameTable: &next, Columns: []tableedit.Column{{Name: "first_added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}, {Name: "second_added", Type: tableedit.DataType{Kind: "varchar", Length: 20}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}, Changes: []tableedit.ColumnChange{{Name: "id", RenameTo: &col}}}
	p, e := store.PreviewContext(ctx, s, b.Baseline.ID, draft)
	if e != nil {
		t.Fatal(e)
	}
	if len(p.Plan.SQL) != 4 || p.Plan.Target.Table != name || p.Plan.ResultTarget == nil || p.Plan.ResultTarget.Table != next {
		t.Fatal("original identity or intent lost")
	}
	out, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "rename"})
	if e != nil {
		t.Fatal(e)
	}
	if out.Outcome.State != "applied" || out.Outcome.Observed == nil || out.Outcome.Observed.Target.Table != next || len(out.Outcome.Observed.Columns) != 4 {
		t.Fatalf("rename outcomes or preservation failed: state=%s steps=%v refresh=%s", out.Outcome.State, out.Outcome.Steps, out.Outcome.RefreshError)
	}
}
