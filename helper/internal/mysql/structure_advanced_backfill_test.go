package mysql

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"reflect"
	"testing"
)

func TestStructureAdvancedReviewedBackfillNullDefault(t *testing.T) {
	required := false
	change := tableedit.ColumnChange{Name: "required", Nullable: &required}
	baseline := tableedit.Baseline{Facts: &tableedit.Facts{Table: sc.Table{Columns: sc.Complete([]sc.Column{{Ref: sc.Ref{Kind: "column", Name: "required"}, Default: sc.Known(sc.Default{Kind: "none"})}})}}}
	nullable := "`required` varchar(40) DEFAULT NULL"
	notNull := "`required` varchar(40) NOT NULL"
	a, ok := myAdvancedColumn(nullable, change, baseline, true)
	if !ok {
		t.Fatal("reviewed nullable backfill column unavailable")
	}
	b, ok := myAdvancedColumn(notNull, change, baseline, true)
	if !ok || !reflect.DeepEqual(a, b) {
		t.Fatal("native backfill NOT NULL normalization lost exact default semantics")
	}
	ordinary, ok := myAdvancedColumn(nullable, change, baseline)
	if !ok || reflect.DeepEqual(ordinary, b) {
		t.Fatal("unrelated existing-column defaults were normalized as a new backfill")
	}
	for _, raw := range []string{"`required` varchar(40) DEFAULT 'NULL'", "`required` varchar(40) DEFAULT ''", "`required` varchar(40) DEFAULT ('NULL')"} {
		original := baseline
		original.Facts = &tableedit.Facts{Table: sc.Table{Columns: sc.Complete([]sc.Column{{Ref: sc.Ref{Kind: "column", Name: "required"}, Default: sc.Known(sc.Default{Kind: "expression"})}})}}
		value, ok := myAdvancedColumn(raw, change, original, true)
		if !ok || reflect.DeepEqual(value, b) {
			t.Fatal("authored text/empty/expression default was erased by nullable normalization")
		}
	}
}
