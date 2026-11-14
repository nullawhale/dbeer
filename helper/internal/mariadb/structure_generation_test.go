package mariadb

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestMariaDBGenerationComparisonKeepsUnselectedNativeSlots(t *testing.T) {
	b := tableedit.Baseline{Target: tableedit.Target{Schema: "s", Table: "t"}, NativeDefinition: "CREATE TABLE `t` (`id` bigint NOT NULL,`g` int GENERATED ALWAYS AS (`id` * 2) STORED COMMENT 'retained') ENGINE=InnoDB"}
	a := b
	a.NativeDefinition = "CREATE TABLE `t` (`id` bigint NOT NULL,`g` int GENERATED ALWAYS AS (`id` * 3) STORED COMMENT 'retained') ENGINE=InnoDB"
	c := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: "g", Generated: &tableedit.Generation{Storage: "stored", Expression: "id*3"}}}}
	if !mariaDBNativeStructurePreserved(b, a, c) {
		t.Fatal("selected native generation slot could not be compared")
	}
	a.NativeDefinition = "CREATE TABLE `t` (`id` bigint NOT NULL,`g` int GENERATED ALWAYS AS (`id` * 3) STORED COMMENT 'changed') ENGINE=InnoDB"
	if mariaDBNativeStructurePreserved(b, a, c) {
		t.Fatal("generation proof erased an unselected comment")
	}
	id := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: "id", Identity: &tableedit.Identity{Kind: "autoIncrement"}}}}
	a = b
	a.NativeDefinition = "CREATE TABLE `t` (`id` bigint NOT NULL AUTO_INCREMENT,`g` int GENERATED ALWAYS AS (`id` * 2) STORED COMMENT 'retained') ENGINE=InnoDB AUTO_INCREMENT=9007199254741105"
	if !mariaDBNativeStructurePreserved(b, a, id) {
		t.Fatal("native selected identity/counter slots refused")
	}
	a.NativeDefinition = "CREATE TABLE `t` (`id` bigint NOT NULL AUTO_INCREMENT,`g` int GENERATED ALWAYS AS (`id` * 2) STORED COMMENT 'retained') ENGINE=InnoDB AUTO_INCREMENT=01"
	if mariaDBNativeStructurePreserved(b, a, id) {
		t.Fatal("noncanonical native counter origin admitted")
	}
}
func TestMariaDBIdentityDataProofRetainsEveryRowAndSessionValue(t *testing.T) {
	b := tableedit.Baseline{Facts: &tableedit.Facts{
		Table: sc.Table{Columns: sc.Complete([]sc.Column{
			{Ref: sc.Ref{Name: "id"}, Identity: sc.Known(sc.Identity{Kind: "none"})},
		})},
	}}

	condition := []tableedit.Condition{{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: "id", Identity: &tableedit.Identity{Kind: "autoIncrement"}}}}}
	last := "0"
	counter := "9007199254741105"
	before := &mariaDBStructureRows{names: []string{"id"}, rows: map[string]int{"exact": 2}, lastID: &last}
	after := &mariaDBStructureRows{names: []string{"id"}, rows: map[string]int{"exact": 2}, lastID: &last, counter: &counter}
	if !mariaDBStructureDataPreserved(b, before, after, condition) {
		t.Fatal("explicit counter creation rejected exact retained data")
	}
	for _, mutate := range []func(*mariaDBStructureRows){func(p *mariaDBStructureRows) { p.rows = map[string]int{"exact": 1} }, func(p *mariaDBStructureRows) { v := "1"; p.lastID = &v }, func(p *mariaDBStructureRows) { v := "rounded"; p.counter = &v }, func(p *mariaDBStructureRows) { p.counter = nil }} {
		copy := *after
		mutate(&copy)
		if mariaDBStructureDataPreserved(b, before, &copy, condition) {
			t.Fatal("identity effect admitted retained-data/session/counter drift")
		}
	}
}

func TestMariaDBIdentityCannotDropItsOnlyLeadingKeyBeforeReplacement(t *testing.T) {
	b := tableedit.Baseline{Facts: &tableedit.Facts{Table: sc.Table{Columns: sc.Complete([]sc.Column{{Ref: sc.Ref{Name: "id"}, Identity: sc.Known(sc.Identity{Kind: "autoIncrement"})}})}}, Indexes: []tableedit.Index{{Name: "PRIMARY", Owner: "PRIMARY", Columns: []string{"id"}, Supported: true}}}
	d := tableedit.Draft{Keys: []tableedit.KeyEdit{{Action: "replace", Name: "PRIMARY", Kind: "primary", Columns: []string{"id"}}}}
	if _, _, e := mariaDBIdentityDraft(b, d); e == nil {
		t.Fatal("identity's sole leading key was allowed to disappear before replacement")
	}
}
