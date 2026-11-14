package tableedit

import (
	sc "dbeer/helper/internal/schemacompare"
	"testing"
)

func TestRenameRequiresCompleteStructuralCollections(t *testing.T) {
	for _, field := range []string{"columns", "constraints", "indexes"} {
		b := transitionFixture("postgresql")
		b.Facts.Table.Ref = sc.Ref{Kind: "table", Schema: b.Target.Schema, Name: b.Target.Table}
		switch field {
		case "columns":
			b.Facts.Table.Columns.Complete = false
		case "constraints":
			b.Facts.Table.Constraints.Complete = false
		case "indexes":
			b.Facts.Table.Indexes.Complete = false
		}
		for _, column := range []string{"", "value"} {
			if CheckRename(b, column) == nil {
				t.Fatalf("rename accepted incomplete %s", field)
			}
		}
	}
}

func TestRenameChangesOnlyIncomingReferencedColumnsOfItsOwner(t *testing.T) {
	target := Target{Schema: "public", Table: "parent"}
	for _, owner := range []string{"parent", "child"} {
		f := &Facts{Table: sc.Table{Ref: sc.Ref{Kind: "table", Schema: "public", Name: owner}}, Incoming: []Incoming{{Schema: "public", Table: "parent", Name: "self_or_reverse", Columns: []string{"id"}}, {Schema: "other", Table: "grandchild", Name: "external", Columns: []string{"id"}}}}
		fk := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "public", Table: owner, Name: "fk"}, "f")
		fk.ForeignKeys = sc.Complete([]sc.ColumnPair{{Source: sc.Ref{Kind: "column", Schema: "public", Table: owner, Name: "id"}, Target: sc.Ref{Kind: "column", Schema: "public", Table: "parent", Name: "id"}}})
		f.Table.Constraints = sc.Complete([]sc.Constraint{fk})
		renameFacts(f, target, "id", "renamed_id")
		for _, incoming := range f.Incoming {
			want := "id"
			if owner == "parent" {
				want = "renamed_id"
			}
			if incoming.Columns[0] != want || incoming.Table == "renamed_id" {
				t.Fatal("incoming metadata was rebound to a column from another table")
			}
		}
		pair := f.Table.Constraints.Items[0].ForeignKeys.Items[0]
		if pair.Target.Name != "renamed_id" || owner == "child" && pair.Source.Name != "id" {
			t.Fatal("typed reference rewrite changed an unrelated source column")
		}
	}
}
