package sqllsp

import (
	"dbeer/helper/internal/sqlcomplete"
	"testing"
)

func TestExactTypeEntryAndLogicalOriginConfigurationBounds(t *testing.T) {
	relation := catalogEntry{Schema: "public", Name: "items", Kind: "table", Columns: []string{"é", "e\u0301"},
		ColumnTypeEntries: []sqlcomplete.ColumnTypeEntry{{Name: "é", NativeType: "text"}, {Name: "e\u0301", NativeType: "bigint"}},
		ForeignKeys:       []sqlcomplete.ForeignKey{{Origin: "logical", Name: "local", TargetSchema: "public", TargetTable: "other", Columns: []sqlcomplete.ForeignKeyColumn{{Source: "é", Target: "id"}}}}}
	configuration := configuration{URI: "fixture://document", Engine: "postgresql", Catalog: []catalogEntry{relation}}
	if !boundedConfiguration(configuration) {
		t.Fatal("byte-distinct native entries or logical origin rejected")
	}
	configuration.Catalog[0].ColumnTypeEntries[1].Name = "é"
	if boundedConfiguration(configuration) {
		t.Fatal("duplicate exact type entry accepted")
	}
	configuration.Catalog[0].ColumnTypeEntries = relation.ColumnTypeEntries[:1]
	configuration.Catalog[0].ForeignKeys[0].Origin = "inferred"
	if boundedConfiguration(configuration) {
		t.Fatal("unconfirmed origin accepted")
	}
}
