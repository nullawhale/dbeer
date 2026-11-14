package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"strings"
	"testing"
)

func TestStructureAdvancedNewIndexAttributesLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("index_attributes") + "(id integer,payload text)")
	f.exec("ALTER TABLE " + f.table("index_attributes") + " ENABLE ROW LEVEL SECURITY")
	f.exec("INSERT INTO " + f.table("index_attributes") + " VALUES(1,''),(2,'NULL'),(3,NULL)")
	s := &Session{conn: f.conn}
	target := tableedit.Target{Schema: f.schema, Table: "index_attributes"}
	before, err := s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	f.exec("CREATE INDEX fresh_native ON " + f.table("index_attributes") + "(id,payload)")
	after, err := s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	condition := tableedit.Condition{Operation: tableedit.Operation{Kind: "addIndex", Index: &tableedit.IndexEdit{Action: "add", Name: "fresh_native", Columns: []string{"id", "payload"}}}}
	if err = pgAdvancedPreservationError(before, after, condition); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(map[string]any){func(row map[string]any) { row["attstattarget"] = float64(321) }, func(row map[string]any) { row["unknownNativeProperty"] = true }, func(row map[string]any) { row["attnum"] = float64(0) }, func(row map[string]any) { row["atttypid"] = float64(20) }, func(row map[string]any) { row["attoptions"] = []any{"n_distinct=0.5"} }} {
		changed := after
		changed.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
		for _, row := range changed.AdvancedEvidence.Rows[after.Identity+"/indexAttributes"] {
			if row["attname"] == "id" {
				mutate(row)
				break
			}
		}
		if pgAdvancedPreservationError(before, changed, condition) == nil {
			t.Fatal("unreviewed created-index attributes were discarded")
		}
	}
	// A retained index's genuine expression statistics stay in the raw proof.
	f.exec("CREATE INDEX retained_expression ON " + f.table("index_attributes") + "((id+1))")
	f.exec("ALTER INDEX " + f.table("retained_expression") + " ALTER COLUMN 1 SET STATISTICS 321")
	baseline, err := s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	store := &tableedit.Store{}
	authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "another_native", Columns: []string{"id"}}}})
	observed, err := s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	if len(baseline.AdvancedEvidence.Rows[baseline.Identity+"/indexAttributes"])+1 != len(observed.AdvancedEvidence.Rows[observed.Identity+"/indexAttributes"]) {
		t.Fatal("retained native attributes disappeared")
	}
	guarded, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal(err)
	}
	unsupported := tableedit.Draft{AuthoringVersion: 4, AllowDestructive: true, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "drop", Name: "retained_expression"}}}
	if _, err = store.PreviewContext(ctx, s, guarded.Baseline.ID, unsupported); err == nil || !strings.Contains(err.Error(), "statisticsTargets") {
		t.Fatal("unmodeled index statistics removal lost its explicit client guard")
	}
	loaded, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal(err)
	}
	drop := tableedit.Draft{AuthoringVersion: 4, AllowDestructive: true, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "drop", Name: "fresh_native"}}}
	preview, err := store.PreviewContext(ctx, s, loaded.Baseline.ID, drop)
	if err != nil {
		t.Fatal(err)
	}
	disclosed := false
	for _, effect := range preview.Plan.Consequences {
		disclosed = disclosed || strings.Contains(effect.Message, `"attname":"id"`)
	}
	if !disclosed {
		t.Fatal("reviewed index removal omitted its complete native column properties")
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: tableedit.Token()})
	if err != nil || out.Outcome.State != "applied" {
		t.Fatal("reviewed native index attribute removal failed")
	}
}
