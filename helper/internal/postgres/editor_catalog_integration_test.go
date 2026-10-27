package postgres

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestPostgresEditorCompletionNativeTypesLive(t *testing.T) {
	fixture := newChangeFixture(t)
	fixture.exec("CREATE DOMAIN " + fixture.table("money_amount") + " AS numeric(20,4)")
	fixture.exec("CREATE TABLE " + fixture.table("Odd Table") + " (id bigint, amount numeric(20,4), labels text[], detail jsonb, custom " + fixture.table("money_amount") + ")")
	fixture.exec("CREATE VIEW " + fixture.table("readable") + " AS SELECT id,amount FROM " + fixture.table("Odd Table"))
	fixture.exec("CREATE FUNCTION " + fixture.table("lookup") + "(input_value integer) RETURNS numeric LANGUAGE sql AS $$SELECT $1::numeric$$")
	request := protocol.CatalogRequest{Kind: "completion", Schema: fixture.schema}
	response := catalog(context.Background(), fixture.conn, protocol.Command{Type: "catalog", RequestID: "editor-types", Catalog: &request})
	if response.Type != "query.result" {
		t.Fatalf("completion failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
	}
	indices := map[string]int{}
	for i, column := range response.Columns {
		indices[column.Name] = i
	}
	for _, name := range []string{"name", "columns", "columnTypes", "signatures"} {
		if _, ok := indices[name]; !ok {
			t.Fatal("missing completion field", name)
		}
	}
	seen := map[string]bool{}
	for _, row := range response.Rows {
		if row[indices["name"]] == nil {
			t.Fatal("missing object identity")
		}
		name := *row[indices["name"]]
		if seen[name] {
			t.Fatal("duplicate completion object")
		}
		seen[name] = true
		var nativeTypes map[string]string
		raw := row[indices["columnTypes"]]
		if raw == nil || json.Unmarshal([]byte(*raw), &nativeTypes) != nil {
			t.Fatal("type map is not valid JSON")
		}
		var columns []string
		if row[indices["columns"]] == nil || json.Unmarshal([]byte(*row[indices["columns"]]), &columns) != nil {
			t.Fatal("column list is not valid JSON")
		}
		if len(nativeTypes) != len(columns) {
			t.Fatal("native types do not match returned columns")
		}
		switch name {
		case "Odd Table":
			if nativeTypes["id"] != "bigint" || nativeTypes["amount"] != "numeric(20,4)" || nativeTypes["labels"] != "text[]" || nativeTypes["detail"] != "jsonb" || !strings.HasSuffix(nativeTypes["custom"], ".money_amount") {
				t.Fatal("completion did not retain native type modifiers, arrays and domain identity")
			}
		case "readable":
			if nativeTypes["id"] != "bigint" || nativeTypes["amount"] != "numeric(20,4)" {
				t.Fatal("view column types missing")
			}
		case "lookup":
			if len(nativeTypes) != 0 || len(columns) != 0 {
				t.Fatal("function inherited unrelated table column types")
			}
		}
	}
	if !seen["Odd Table"] || !seen["readable"] || !seen["lookup"] {
		t.Fatal("completion omitted fixture table/view/function")
	}
}
