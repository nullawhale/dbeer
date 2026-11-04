package sqlite

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func TestSQLiteRebuildBeyondFormerCaptureLimits(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, `CREATE TABLE large_records(id INTEGER PRIMARY KEY, value TEXT CHECK(length(value)=200))`)
	toolExec(t, s, `WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100005) INSERT INTO large_records SELECT x,printf('%0200d',x) FROM n`)
	var store tableedit.Store
	loaded, err := store.Load(ctx, s, tableedit.Target{Schema: "main", Table: "large_records"})
	if err != nil {
		t.Fatal(err)
	}
	value := strings.Repeat("z", 200)
	preview, err := store.PreviewContext(ctx, s, loaded.Baseline.ID, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: "value", Default: &tableedit.Default{Kind: "text", Value: &value}}}})
	if err != nil {
		t.Fatal(err)
	}
	result, err := store.Apply(ctx, s, tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: "large-rebuild"})
	if err != nil || result.Outcome == nil || result.Outcome.State != "applied" {
		t.Fatalf("large rebuild did not apply: %v %#v", err, result.Outcome)
	}
	rows, _, err := s.query(ctx, `SELECT count(*),sum(length(value)),min(id),max(id) FROM large_records`)
	if err != nil || len(rows) != 1 || cellInt(rows[0][0]) != 100005 || cellInt(rows[0][1]) != 20001000 || cellInt(rows[0][2]) != 1 || cellInt(rows[0][3]) != 100005 {
		t.Fatal("large rebuild changed source rows", err)
	}
	toolExec(t, s, `INSERT INTO large_records(id) VALUES(100006)`)
	rows, _, err = s.query(ctx, `SELECT value FROM large_records WHERE id=100006`)
	if err != nil || len(rows) != 1 || cellText(rows[0][0]) != value {
		t.Fatal("large rebuild lost the reviewed default", err)
	}
	if err = s.exec(ctx, `INSERT INTO large_records(id,value) VALUES(100007,'invalid')`); err == nil {
		t.Fatal("large rebuild lost the original CHECK constraint")
	}
}
