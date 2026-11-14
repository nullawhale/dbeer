package sqlite

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func nativeSQLiteFilter(kind, value, engine, native, policy string) protocol.CatalogFilter {
	return protocol.CatalogFilter{Column: "v", Operator: "eq", NativeValue: &protocol.NativeCellFilterValue{Cell: protocol.CellValue{Kind: kind, Value: &value}, SourceEngine: engine, SourceType: native, SQLiteStorage: policy}}
}

func TestSQLiteNativeFiltersRetainANYStorageAndExplicitPolicies(t *testing.T) {
	s, _ := openCore(t, false)
	runCore(t, s, `CREATE TABLE native_filters(id INTEGER PRIMARY KEY,v ANY) STRICT`)
	runCore(t, s, `INSERT INTO native_filters VALUES (1,9223372036854775807),(2,1.5),(3,'1.5'),(4,X'00ff80'),(5,CAST(X'610062' AS TEXT)),(6,NULL),(7,X''),(8,''),(9,'NULL'),(10,1e999),(11,0.5),(12,1),(13,CAST(X'ff' AS TEXT))`)
	tests := []struct {
		filter protocol.CatalogFilter
		id     string
	}{
		{nativeSQLiteFilter("sqliteInteger", "9223372036854775807", "sqlite", "ANY", "preserve"), "1"},
		{nativeSQLiteFilter("sqliteReal", "3ff8000000000000", "sqlite", "ANY", "preserve"), "2"},
		{nativeSQLiteFilter("sqliteText", "MS41", "sqlite", "ANY", "preserve"), "3"},
		{nativeSQLiteFilter("sqliteBlob", "AP+A", "sqlite", "ANY", "preserve"), "4"},
		{nativeSQLiteFilter("sqliteText", "YQBi", "sqlite", "ANY", "text"), "5"},
		{nativeSQLiteFilter("binary", "", "mysql", "blob", "blob"), "7"},
		{nativeSQLiteFilter("text", "", "postgresql", "text", "text"), "8"},
		{nativeSQLiteFilter("text", "NULL", "postgresql", "text", "text"), "9"},
		{nativeSQLiteFilter("sqliteReal", "7ff0000000000000", "sqlite", "ANY", "preserve"), "10"},
		{nativeSQLiteFilter("text", "0.5", "postgresql", "numeric", "real"), "11"},
		{nativeSQLiteFilter("text", "1.000", "postgresql", "numeric", "integer"), "12"},
		{nativeSQLiteFilter("sqliteText", "/w==", "sqlite", "ANY", "text"), "13"},
	}
	for i, test := range tests {
		request := protocol.CatalogRequest{Kind: "browse", Schema: "main", Object: "native_filters", ObjectKind: "table", Filters: []protocol.CatalogFilter{test.filter}}
		response := s.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &request})
		if response.Type != "query.result" || len(response.SQLiteValues) != 1 || response.SQLiteValues[0][0].Value != test.id {
			t.Fatalf("native SQLite binding case %d changed storage or bytes", i)
		}
	}
	for _, filter := range []protocol.CatalogFilter{
		nativeSQLiteFilter("text", "0.1", "postgresql", "numeric", "real"),
		nativeSQLiteFilter("text", "9007199254740993", "postgresql", "bigint", "real"),
		nativeSQLiteFilter("text", "9223372036854775808", "mysql", "bigint unsigned", "integer"),
		nativeSQLiteFilter("sqliteBlob", "MS41", "sqlite", "ANY", "text"),
		nativeSQLiteFilter("sqliteText", "MS41", "sqlite", "ANY", "blob"),
		nativeSQLiteFilter("text", "0.5", "postgresql", "numeric", "preserve"),
	} {
		request := protocol.CatalogRequest{Kind: "browse", Schema: "main", Object: "native_filters", ObjectKind: "table", Filters: []protocol.CatalogFilter{filter}}
		if response := s.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &request}); response.Type != "error" {
			t.Fatal("lossy native conversion was executed")
		}
	}
	left, right := tests[0].filter, tests[7].filter
	expr := protocol.CatalogFilterExpression{Kind: "or", Children: []protocol.CatalogFilterExpression{{Kind: "condition", Condition: &left}, {Kind: "condition", Condition: &right}}}
	request := protocol.CatalogRequest{Kind: "browse", Schema: "main", Object: "native_filters", ObjectKind: "table", FilterExpression: &expr}
	response := s.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &request})
	if response.Type != "query.result" || len(response.SQLiteValues) != 2 || response.SQLiteValues[0][0].Value != "1" || response.SQLiteValues[1][0].Value != "9" {
		t.Fatal("native OR grouping changed")
	}
	count := runCore(t, s, "SELECT count(*) FROM native_filters")
	if len(count.SQLiteValues) != 1 || count.SQLiteValues[0][0].Value != "13" {
		t.Fatal("native browse mutated fixture")
	}
}
