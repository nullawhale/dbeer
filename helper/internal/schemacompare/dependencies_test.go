package schemacompare

import (
	"reflect"
	"testing"
)

func TestLinkDependenciesPreservesDeclaredSemanticEdgesAndVisibility(t *testing.T) {
	view := Ref{Kind: "table", Schema: "ks", Name: "view"}
	base := Ref{Kind: "table", Schema: "ks", Name: "base"}
	edge := Dependency{From: view, To: base, Kind: "materializedView", State: "known"}
	table := Table{Ref: view, Dependencies: Collection[Dependency]{Items: []Dependency{edge}, State: "unsupported", Complete: false, Code: "missingDependency"}}
	linkDependencies(&table)
	if table.Dependencies.Complete || table.Dependencies.State != "unsupported" || table.Dependencies.Code != "missingDependency" || !reflect.DeepEqual(table.Dependencies.Items, []Dependency{edge}) {
		t.Fatal("declared semantic edge or incomplete visibility lost")
	}
	original := table.Dependencies
	linkDependencies(&table)
	if !reflect.DeepEqual(original, table.Dependencies) {
		t.Fatal("relinking duplicated or changed dependencies")
	}
}
