package postgres

import (
	"testing"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
)

func TestAdvancedMigrationCheckpointRetainsUnknownEvidence(t *testing.T) {
	target := tableedit.Target{Schema: "fixture", Table: "secured"}
	facts := &tableedit.Facts{Table: sc.Table{Ref: sc.Ref{Schema: target.Schema, Name: target.Table}}}
	before := &tableedit.AdvancedEvidence{Facts: map[string]*tableedit.Facts{"42": facts}, Rows: map[string][]map[string]any{"42/future": {{"unknown": "retained"}, {"unknown": "retained"}}, "42/empty": {}}}
	b := tableedit.Baseline{Target: target, Identity: "42", Facts: facts, AdvancedEvidence: before}
	proof := tableedit.CloneAdvancedEvidence(before)
	proof.Rows["43/class"] = []map[string]any{{"independent": true}}
	if !pgAdvancedMigrationEvidenceCovers(b, proof) {
		t.Fatal("complete evidence with separately proved members was rejected")
	}
	for _, mutate := range []func(*tableedit.AdvancedEvidence){
		func(e *tableedit.AdvancedEvidence) { delete(e.Rows, "42/future") },
		func(e *tableedit.AdvancedEvidence) { e.Rows["42/future"] = e.Rows["42/future"][:1] },
		func(e *tableedit.AdvancedEvidence) { e.Rows["42/future"][0]["unknown"] = "changed" },
		func(e *tableedit.AdvancedEvidence) { e.Rows["42/empty"] = nil },
	} {
		changed := tableedit.CloneAdvancedEvidence(proof)
		mutate(changed)
		if pgAdvancedMigrationEvidenceCovers(b, changed) {
			t.Fatal("checkpoint lost an unknown property, duplicate or category presence")
		}
	}
	if before.Rows["42/future"][0]["unknown"] != "retained" {
		t.Fatal("checkpoint comparison mutated observed evidence")
	}
}

func TestAdvancedMigrationForeignUnitRequiresSingleReviewedTransition(t *testing.T) {
	foreign := tableedit.Condition{Operation: tableedit.Operation{Kind: "dropKey", Key: &tableedit.KeyEdit{Kind: "foreign", Action: "drop", Name: "selected"}}}
	if !pgAdvancedMigrationForeignUnit([]tableedit.Condition{foreign}) {
		t.Fatal("single selected repair transition was rejected")
	}
	for _, conditions := range [][]tableedit.Condition{nil, {foreign, foreign}, {{Operation: tableedit.Operation{Kind: "addColumn"}}}, {{Operation: tableedit.Operation{Kind: "dropKey", Key: &tableedit.KeyEdit{Kind: "unique"}}}}} {
		if pgAdvancedMigrationForeignUnit(conditions) {
			t.Fatal("unsupported composite migration checkpoint was admitted")
		}
	}
}
