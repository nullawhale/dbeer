package mysql

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLCatalogColumnEntriesLive(t *testing.T) {
	s := integrationSession(t)
	schema := integrationSettings(t).Database
	table := fmt.Sprintf("dbeer_column_types_%x", s.connectionID)
	qualified := QuoteIdentifier(schema) + "." + QuoteIdentifier(table)
	t.Cleanup(func() {
		s.Execute(context.Background(), protocol.Command{SQL: "SET NAMES utf8mb4"})
		s.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
	})
	run(t, s, "CREATE TABLE "+qualified+" (`é` VARCHAR(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin,`é` BIGINT,other TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci) ENGINE=InnoDB")
	request := protocol.CatalogRequest{Kind: "completion", Schema: schema}
	response := catalogRequest(t, s, request)
	indices := map[string]int{}
	for i, c := range response.Columns {
		indices[c.Name] = i
	}
	if indices["columnTypeEntries"] == 0 {
		t.Fatal("ordered completion entries unavailable")
	}
	var entries []protocol.CatalogColumnTypeEntry
	for _, row := range response.Rows {
		if *row[indices["name"]] == table && json.Unmarshal([]byte(*row[indices["columnTypeEntries"]]), &entries) != nil {
			t.Fatal("completion entries invalid")
		}
	}
	if len(entries) != 3 || entries[0].Name != "é" || entries[1].Name != "e\u0301" || entries[0].NativeType != "varchar(30)" || entries[1].NativeType != "bigint" {
		t.Fatal("ordered entries changed exact column names/types")
	}
	left, right := entries[0].Comparison, entries[2].Comparison
	if left == nil || right == nil || left.Kind != "text" || left.BaseType != "varchar" || left.Charset != "utf8mb4" || left.CollationName != "utf8mb4_bin" || left.CollationIdentity == "" || left.CollationIdentity == right.CollationIdentity {
		t.Fatal("column comparison facts lost actual charset/collation identity")
	}
	request.Kind, request.Object, request.ObjectKind = "columns", table, "table"
	columns := catalogRequest(t, s, request)
	comparisonIndex := -1
	for i, c := range columns.Columns {
		if c.Name == "comparison" {
			comparisonIndex = i
		}
	}
	if len(columns.Rows) != 3 || comparisonIndex < 0 {
		t.Fatal("column comparison facts missing")
	}
	for i, row := range columns.Rows {
		var fact protocol.CatalogColumnComparison
		if row[comparisonIndex] == nil || json.Unmarshal([]byte(*row[comparisonIndex]), &fact) != nil || fact != *entries[i].Comparison {
			t.Fatal("columns and completion comparison facts disagree")
		}
	}
	run(t, s, "SET NAMES latin1")
	before := nativeCharsetSettings(t, s)
	for _, kind := range []string{"columns", "completion"} {
		request.Kind = kind
		if kind == "completion" {
			request.Object, request.ObjectKind = "", ""
		}
		rejected := s.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &request})
		if rejected.Type != "error" || rejected.Category != "validation" || len(rejected.Rows) != 0 || nativeCharsetSettings(t, s) != before {
			t.Fatal("non-UTF8 metadata read executed or settings changed")
		}
	}
}
