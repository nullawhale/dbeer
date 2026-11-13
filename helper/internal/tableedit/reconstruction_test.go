package tableedit

import (
	"reflect"
	"testing"
)

func reconstructionDraft() Draft {
	return Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []Column{{Name: "required", Type: DataType{Kind: "text"}, Default: Default{Kind: "none"}}}, Backfills: []Backfill{{Column: "required", Expression: "'NULL'"}}}
}
func TestReconstructionDraftAdmission(t *testing.T) {
	good := reconstructionDraft()
	if !good.Valid() || !good.Destructive() || !good.RequiresEffectConfirmation() {
		t.Fatal("missing explicit severity")
	}
	for name, change := range map[string]func(*Draft){
		"oldEnvelope": func(d *Draft) { d.AuthoringVersion = 4 }, "noPermission": func(d *Draft) { d.AllowDestructive = false }, "existingColumn": func(d *Draft) { d.Backfills[0].Column = "existing" }, "duplicateBackfill": func(d *Draft) { d.Backfills = append(d.Backfills, d.Backfills[0]) }, "nullable": func(d *Draft) { d.Columns[0].Nullable = true }, "default": func(d *Draft) { d.Columns[0].Default = Default{Kind: "null"} }, "mixedChange": func(d *Draft) { v := true; d.Changes = []ColumnChange{{Name: "other", Nullable: &v}} }, "mixedDrop": func(d *Draft) { d.DropTable = true }, "missingBackfill": func(d *Draft) { d.Backfills = nil; d.Reconstruct = true }, "duplicateOrder": func(d *Draft) { d.ColumnOrder = []string{"required", "required"} },
	} {
		t.Run(name, func(t *testing.T) {
			d := reconstructionDraft()
			change(&d)
			if d.Valid() {
				t.Fatal("invalid draft admitted")
			}
		})
	}
}
func TestReconstructionOrderIsExactAndExpressionIsSingleSlot(t *testing.T) {
	b := Baseline{Engine: "sqlite", Columns: []ObservedColumn{{Name: "old"}}}
	d := reconstructionDraft()
	d.ColumnOrder = []string{"required", "old"}
	if order, err := ReconstructionOrder(b, d); err != nil || len(order) != 2 || order[0] != "required" {
		t.Fatal(err)
	}
	d.ColumnOrder = []string{"required"}
	if _, err := ReconstructionOrder(b, d); err == nil {
		t.Fatal("missing retained column")
	}
	d.ColumnOrder = nil
	d.Backfills[0].Expression = "1); DROP TABLE old; --"
	if _, err := ReconstructionOrder(b, d); err == nil {
		t.Fatal("expression escaped slot")
	}
}
func TestReconstructionVersionFivePreservesDestructiveConversionSemantics(t *testing.T) {
	d := Draft{AuthoringVersion: 5, Columns: []Column{}, Changes: []ColumnChange{{Name: "x", Type: &DataType{Kind: "integer"}}}, AllowDestructive: true}
	if !d.NeedsAuthoringV4() || !d.Destructive() || !d.Valid() {
		t.Fatal("v5 converted column lost E3 intent")
	}
}

func TestReconstructionPostgresEmptyOptionsAreVersionSafe(t *testing.T) {
	if !EmptyPostgresOptions(nil) || !EmptyPostgresOptions([]any{}) || EmptyPostgresOptions([]any{"custom=value"}) || EmptyPostgresOptions("") {
		t.Fatal("attribute options were guessed or discarded")
	}
}

func TestReconstructionPostgresInternalAttributeVersionIsNarrowlyExcluded(t *testing.T) {
	for _, v := range []any{[]any{"pg_attver=12345678"}, []any{"pg_attver=0/ABCDEF01"}} {
		if !EmptyPostgresOptions(v) {
			t.Fatal("server-owned layout version became a user option")
		}
	}
	for _, v := range []any{[]any{"pg_attver="}, []any{"pg_attver=not-a-version"}, []any{"pg_attver=1", "pg_attver=2"}, []any{"pg_unknown=1"}, []any{"n_distinct=0.1"}, []any{"pg_attver=1", "n_distinct=0.1"}} {
		if EmptyPostgresOptions(v) {
			t.Fatal("custom, unknown or malformed option was discarded")
		}
	}
	input := []any{"pg_attver=1", "n_distinct=0.1"}
	if !reflect.DeepEqual(SemanticPostgresAttributeOptions(input), []any{"n_distinct=0.1"}) || len(input) != 2 {
		t.Fatal("user options or raw evidence mutated")
	}
}
