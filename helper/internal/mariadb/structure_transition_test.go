package mariadb

import (
	"dbeer/helper/internal/mysql"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"testing"
)

func TestMariaDBForeignNameTransitionBindsOnlyReviewedInventoryDelta(t *testing.T) {
	source := tableedit.Baseline{Engine: "mariadb", Target: tableedit.Target{Schema: "s", Table: "owner"}}
	baseline := func(rows [][]string) tableedit.Baseline {
		native := make([][]*string, len(rows))
		for i, row := range rows {
			native[i] = make([]*string, len(row))
			for j, value := range row {
				native[i][j] = &value
			}
		}
		raw, _ := json.Marshal(mysql.CatalogRawRows(native))
		b := source
		b.Facts = &tableedit.Facts{EngineContext: []sc.Option{{Name: "schemaForeignKeyNames", Value: string(raw)}, {Name: "principal", Value: "native@host"}}}
		return b
	}
	before := baseline([][]string{{"untouched", "external_fk"}})
	after := baseline([][]string{{"owner", "selected_fk"}, {"untouched", "external_fk"}})
	c := tableedit.Condition{Operation: tableedit.Operation{Kind: "addKey", Key: &tableedit.KeyEdit{Name: "selected_fk", Kind: "foreign"}}}
	normalized, ok := mariaDBExpectedForeignNames(before, after, source, c)
	if !ok || normalized.Facts.EngineContext[0].Value != before.Facts.EngineContext[0].Value || after.Facts.EngineContext[0].Value == before.Facts.EngineContext[0].Value {
		t.Fatal("exact FK inventory delta was not confined to a comparison clone")
	}
	for _, rows := range [][][]string{{{"owner", "selected_fk"}}, {{"owner", "selected_fk"}, {"untouched", "renamed_fk"}}, {{"owner", "selected_fk"}, {"untouched", "external_fk"}, {"owner", "unselected_fk"}}, {{"owner", "selected_fk"}, {"owner", "selected_fk"}, {"untouched", "external_fk"}}} {
		if _, ok := mariaDBExpectedForeignNames(before, baseline(rows), source, c); ok {
			t.Fatal("unknown external/global FK inventory drift was accepted")
		}
	}
}

func TestMariaDBForeignNameTransitionRejectsUnencodedAndMalformedInventory(t *testing.T) {
	source := tableedit.Baseline{Engine: "mariadb", Target: tableedit.Target{Schema: "s", Table: "owner"}}
	baseline := func(raw string) tableedit.Baseline {
		b := source
		b.Facts = &tableedit.Facts{EngineContext: []sc.Option{{Name: "schemaForeignKeyNames", Value: raw}}}
		return b
	}
	c := tableedit.Condition{Operation: tableedit.Operation{Kind: "addKey", Key: &tableedit.KeyEdit{Name: "selected_fk", Kind: "foreign"}}}
	for _, raw := range []string{`null`, `{}`, `[["","eA=="]]`, `[["owner","selected_fk"]]`, `[[null,"eA=="]]`, `[["!","eA=="]]`, `[["eA=="]]`} {
		if _, ok := mariaDBExpectedForeignNames(baseline(raw), baseline(raw), source, c); ok {
			t.Fatal("invalid byte-preserving catalog scalar inventory was accepted")
		}
	}
}

func TestMariaDBForeignNameAggregateBindsWholeReviewedDraft(t *testing.T) {
	source := tableedit.Baseline{Engine: "mariadb", Target: tableedit.Target{Schema: "s", Table: "owner"}}
	baseline := func(rows [][]string) tableedit.Baseline {
		native := make([][]*string, len(rows))
		for i, row := range rows {
			for _, value := range row {
				native[i] = append(native[i], &value)
			}
		}
		raw, _ := json.Marshal(mysql.CatalogRawRows(native))
		b := source
		b.Facts = &tableedit.Facts{EngineContext: []sc.Option{{Name: "schemaForeignKeyNames", Value: string(raw)}, {Name: "unselected", Value: "exact"}}, RawExpressions: map[string]string{"retained": "native"}}
		return b
	}
	before := baseline([][]string{{"owner", "old_fk"}, {"owner", "second_fk"}, {"other", "external_fk"}})
	renamed := "renamed"
	operations := []tableedit.Operation{
		{Kind: "dropKey", Key: &tableedit.KeyEdit{Name: "old_fk", Kind: "foreign"}},
		{Kind: "addKey", Key: &tableedit.KeyEdit{Name: "new_fk", Kind: "foreign"}},
		{Kind: "renameTable", Name: &renamed},
		{Kind: "dropKey", Key: &tableedit.KeyEdit{Name: "second_fk", Kind: "foreign"}},
	}
	after := baseline([][]string{{"renamed", "new_fk"}, {"other", "external_fk"}})
	normalized, ok := mariaDBExpectedForeignNamesOperations(before, after, source, operations)
	if !ok || normalized.Facts.EngineContext[0].Value != before.Facts.EngineContext[0].Value || after.Facts.EngineContext[0].Value == before.Facts.EngineContext[0].Value || normalized.Facts.RawExpressions["retained"] != "native" {
		t.Fatal("whole reviewed draft did not bind its exact inventory delta on a clone")
	}
	for _, rows := range [][][]string{
		{{"owner", "new_fk"}, {"other", "external_fk"}},
		{{"renamed", "new_fk"}, {"other", "changed_fk"}},
		{{"renamed", "new_fk"}, {"renamed", "unselected_fk"}, {"other", "external_fk"}},
	} {
		if _, ok := mariaDBExpectedForeignNamesOperations(before, baseline(rows), source, operations); ok {
			t.Fatal("unselected or missing aggregate effect accepted")
		}
	}
	drop := append(append([]tableedit.Operation{}, operations...), tableedit.Operation{Kind: "dropTable"})
	if _, ok := mariaDBExpectedForeignNamesOperations(before, baseline([][]string{{"other", "external_fk"}}), source, drop); !ok {
		t.Fatal("reviewed table removal did not remove exactly its owned FK names")
	}
	drop = append(drop, tableedit.Operation{Kind: "addKey", Key: &tableedit.KeyEdit{Name: "impossible_fk", Kind: "foreign"}})
	if _, ok := mariaDBExpectedForeignNamesOperations(before, baseline([][]string{{"other", "external_fk"}}), source, drop); ok {
		t.Fatal("post-drop synthetic effects accepted")
	}
}
