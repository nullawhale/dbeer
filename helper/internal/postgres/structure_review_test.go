package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestStructureExistingIdentityRejectsForeignEngineMode(t *testing.T) {
	for _, kind := range []string{"none", "always"} {
		b := tableedit.Baseline{Facts: &tableedit.Facts{Table: sc.Table{Columns: sc.Complete([]sc.Column{{Ref: sc.Ref{Name: "id"}, Identity: sc.Known(sc.Identity{Kind: kind})}})}}}
		if sql, err := pgIdentityChange(b, tableedit.ColumnChange{Name: "id", Identity: &tableedit.Identity{Kind: "autoIncrement"}}, `"public"."fixture"`); err == nil || len(sql) != 0 {
			t.Fatal("foreign identity mode produced executable PostgreSQL SQL")
		}
	}
}
