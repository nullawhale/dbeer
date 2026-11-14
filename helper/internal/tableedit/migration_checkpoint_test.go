package tableedit

import (
	"reflect"
	"testing"
)

func TestMigrationClonePreservesObservedCollectionPresence(t *testing.T) {
	for _, b := range []Baseline{{}, {Columns: []ObservedColumn{}, Keys: []Key{}, Indexes: []Index{}}, {Keys: []Key{{Columns: []string{}, ReferenceColumns: []string{}}}, Indexes: []Index{{Columns: []string{}}}}} {
		cloned := migrationClone(b)
		if !reflect.DeepEqual(b.Columns, cloned.Columns) || !reflect.DeepEqual(b.Keys, cloned.Keys) || !reflect.DeepEqual(b.Indexes, cloned.Indexes) {
			t.Fatal("migration projection changed an observed empty collection into an absent collection")
		}
	}
	b := Baseline{Columns: []ObservedColumn{{Name: "retained"}}, Keys: []Key{{Columns: []string{"retained"}, ReferenceColumns: []string{"id"}}}, Indexes: []Index{{Columns: []string{"retained"}}}}
	cloned := migrationClone(b)
	cloned.Columns[0].Name = "changed"
	cloned.Keys[0].Columns[0] = "changed"
	cloned.Keys[0].ReferenceColumns[0] = "changed"
	cloned.Indexes[0].Columns[0] = "changed"
	if b.Columns[0].Name != "retained" || b.Keys[0].Columns[0] != "retained" || b.Keys[0].ReferenceColumns[0] != "id" || b.Indexes[0].Columns[0] != "retained" {
		t.Fatal("migration projection aliased the original captured collections")
	}
}

func TestMigrationCheckpointCannotChangeReviewedAuthority(t *testing.T) {
	target := Target{Schema: "fixture", Table: "owner"}
	original := Plan{ID: "retained-plan", Digest: Fingerprint("retained-review"), Target: target, SQL: []string{"synthetic reviewed unit"}, Conditions: []Condition{{Operation: Operation{Kind: "addKey", Key: &KeyEdit{Action: "add", Kind: "foreign", Name: "retained_key"}}}}, References: []Baseline{{ID: "captured", Target: Target{Schema: "fixture", Table: "referenced"}, Scope: "original-scope", Identity: "original-identity", Guard: "original-guard", Attributes: map[string]map[string]any{"id": {"atttypid": float64(23)}}, NativeDefinition: "synthetic native definition"}}, AdvancedProof: &AdvancedEvidence{Targets: []Target{target}, Rows: map[string][]map[string]any{"native/class": {{"oid": "before"}}}}}
	witness := original
	witness.AdvancedProof = CloneAdvancedEvidence(original.AdvancedProof)
	witness.AdvancedProof.Rows["native/class"][0]["oid"] = "acknowledged-after"
	if !migrationCheckpointBindingMatches(original, witness) {
		t.Fatal("a private checkpoint with unchanged reviewed authority was rejected")
	}
	for _, mutate := range []func(*Plan){
		func(p *Plan) { p.SQL = []string{"different unreviewed unit"} },
		func(p *Plan) { p.ID = "different-plan" },
		func(p *Plan) { p.Digest = Fingerprint("different-review") },
		func(p *Plan) { p.Conditions = []Condition{{Operation: Operation{Kind: "dropTable"}}} },
		func(p *Plan) { p.References = []Baseline{{Target: Target{Schema: "outside", Table: "unreviewed"}}} },
		func(p *Plan) { p.AdvancedProof.Targets = []Target{{Schema: "outside", Table: "unreviewed"}} },
		func(p *Plan) { p.References[0].Scope = "changed" },
		func(p *Plan) { p.References[0].Identity = "changed" },
		func(p *Plan) { p.References[0].Guard = "changed" },
		func(p *Plan) { p.References[0].Attributes["id"]["atttypid"] = float64(20) },
		func(p *Plan) { p.References[0].NativeDefinition = "different native definition" },
		func(p *Plan) { p.AdvancedProof = nil },
	} {
		changed := witness
		changed.AdvancedProof = CloneAdvancedEvidence(witness.AdvancedProof)
		changed.References = append([]Baseline(nil), witness.References...)
		for i := range changed.References {
			changed.References[i].Attributes = copyAttrs(changed.References[i].Attributes)
		}
		mutate(&changed)
		if migrationCheckpointBindingMatches(original, changed) {
			t.Fatal("a checkpoint altered retained execution authority")
		}
	}
	if original.AdvancedProof.Rows["native/class"][0]["oid"] != "before" {
		t.Fatal("checkpoint comparison mutated original evidence")
	}
}
