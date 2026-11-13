package sqlite

import (
	"context"
	"encoding/json"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestSQLiteCatalogColumnEntriesKeepExactNamesAndTargetAffinity(t *testing.T) {
	s, _ := openCore(t, false)
	runCore(t, s, `CREATE TABLE exact_columns("é" TEXT COLLATE NOCASE,"é" INTEGER,untyped,opaque ANY)`)
	request := protocol.CatalogRequest{Kind: "completion", Schema: "main"}
	response := s.catalog(context.Background(), protocol.Command{Type: "catalog", Catalog: &request}, nil)
	indices := map[string]int{}
	for i, c := range response.Columns {
		indices[c.Name] = i
	}
	var entries []protocol.CatalogColumnTypeEntry
	if response.Type != "query.result" || len(response.Rows) != 1 || indices["columnTypeEntries"] == 0 || json.Unmarshal([]byte(*response.Rows[0][indices["columnTypeEntries"]]), &entries) != nil {
		t.Fatal("ordered completion entries unavailable")
	}
	if len(entries) != 4 || entries[0].Name != "é" || entries[1].Name != "e\u0301" || entries[0].Comparison.BaseType != "text" || entries[1].Comparison.BaseType != "integer" || entries[2].NativeType != "dynamic" || entries[2].Comparison.BaseType != "blob" || entries[3].Comparison.Kind != "unknown" {
		t.Fatal("exact identities or native affinities changed")
	}
	request.Kind, request.Object, request.ObjectKind = "columns", "exact_columns", "table"
	columns := s.catalog(context.Background(), protocol.Command{Type: "catalog", Catalog: &request}, nil)
	comparisonIndex := -1
	for i, c := range columns.Columns {
		if c.Name == "comparison" {
			comparisonIndex = i
		}
	}
	if columns.Type != "query.result" || len(columns.Rows) != 4 || comparisonIndex < 0 {
		t.Fatal("column facts missing")
	}
	for i, row := range columns.Rows {
		var fact protocol.CatalogColumnComparison
		if json.Unmarshal([]byte(*row[comparisonIndex]), &fact) != nil || fact != *entries[i].Comparison {
			t.Fatal("column and completion facts disagree")
		}
	}
}

func TestSQLiteLogicalJoinMatchesNativeTargetBinding(t *testing.T) {
	s, _ := openCore(t, false)
	runCore(t, s, `CREATE TABLE targets(id INTEGER PRIMARY KEY,v TEXT COLLATE NOCASE)`)
	runCore(t, s, `INSERT INTO targets VALUES(1,'1'),(2,'01'),(3,'A'),(4,'a')`)
	runCore(t, s, `CREATE TABLE sources(id INTEGER PRIMARY KEY,v ANY) STRICT`)
	runCore(t, s, `INSERT INTO sources VALUES(1,1),(2,'a')`)
	for _, test := range []struct {
		id     string
		filter protocol.CatalogFilter
		want   []string
	}{
		{"1", nativeSQLiteFilter("sqliteInteger", "1", "sqlite", "ANY", "preserve"), []string{"1"}},
		{"2", nativeSQLiteFilter("sqliteText", "YQ==", "sqlite", "ANY", "preserve"), []string{"3", "4"}},
	} {
		joined := runCore(t, s, `SELECT target.id FROM targets target JOIN sources source ON target.v = +source.v WHERE source.id=`+test.id+` ORDER BY target.id`)
		request := protocol.CatalogRequest{Kind: "browse", Schema: "main", Object: "targets", ObjectKind: "table", Filters: []protocol.CatalogFilter{test.filter}}
		bound := s.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &request})
		if bound.Type != "query.result" || len(joined.Rows) != len(test.want) || len(bound.Rows) != len(test.want) {
			t.Fatal("logical JOIN and native binding have different target comparison semantics")
		}
		for i, expected := range test.want {
			if *joined.Rows[i][0] != expected || *bound.Rows[i][0] != expected {
				t.Fatal("source affinity or collation overrode the actual target column")
			}
		}
	}
}
