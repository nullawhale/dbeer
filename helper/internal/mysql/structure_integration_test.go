package mysql

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"testing"
	"time"
)

func TestStructureCreateAppendAndDriftIntegration(t *testing.T) {
	s := integrationSession(t)
	settings := integrationSettings(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: settings.Database, Table: fmt.Sprintf("structure_%d", time.Now().UnixNano()), Create: true}
	defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(target.Table))
	load, e := store.Load(ctx, s, target)
	if e != nil {
		t.Fatal("cannot load create baseline")
	}
	value := "NULL"
	draft := tableedit.Draft{Columns: []tableedit.Column{{Name: "label", Type: tableedit.DataType{Kind: "varchar", Length: 100}, Nullable: true, Default: tableedit.Default{Kind: "text", Value: &value}}}}
	p, e := store.Preview(s, load.Baseline.ID, draft)
	if e != nil {
		t.Fatal(e)
	}
	r, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "create"})
	if e != nil || r.Outcome.State != "applied" || r.Outcome.Observed == nil {
		t.Fatal("create not acknowledged and observed")
	}
	target.Create = false
	load, e = store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	draft.Columns[0].Name = "appended"
	draft.Columns[0].Default = tableedit.Default{Kind: "none"}
	p, e = store.Preview(s, load.Baseline.ID, draft)
	if e != nil {
		t.Fatal(e)
	}
	r, e = store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "append"})
	if e != nil || r.Outcome.State != "applied" || len(r.Outcome.Observed.Columns) != 2 {
		t.Fatal("append not acknowledged and observed")
	}
	load, e = store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	draft.Columns[0].Name = "must_not_exist"
	p, e = store.Preview(s, load.Baseline.ID, draft)
	if e != nil {
		t.Fatal(e)
	}
	run(t, s, "ALTER TABLE "+QuoteIdentifier(target.Table)+" ADD COLUMN external_change INT")
	r, e = store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "drift"})
	if e != nil || r.Outcome.Steps[0].State != "notStarted" {
		t.Fatal("stale baseline dispatched DDL")
	}
	for _, c := range r.Outcome.Observed.Columns {
		if c.Name == "must_not_exist" {
			t.Fatal("stale column applied")
		}
	}
}
