package protocol

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestSharedV5PostgresTypeContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/types-v5.json")
	if err != nil {
		t.Fatal("cannot read shared PostgreSQL type fixtures")
	}
	var fixture struct {
		Version   int
		Commands  []json.RawMessage
		Responses []json.RawMessage
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != Version {
		t.Fatal("invalid PostgreSQL type fixture version")
	}
	operations := map[string]bool{}
	emptyValue := false
	for index, raw := range fixture.Commands {
		command, err := ParseCommand(raw)
		if err != nil || command.Catalog == nil {
			t.Fatalf("invalid PostgreSQL type command fixture %d", index)
		}
		operations[command.Catalog.Kind] = true
		if change := command.Catalog.TypeChange; change != nil {
			operations[change.Operation] = true
			if change.Operation == "addEnumValue" {
				emptyValue = change.Value != nil && *change.Value == ""
			}
		}
	}
	for _, kind := range []string{"objects", "name", "definition", "typeDetails", "enumValues", "typeDependencies", "typeDDL", "renameType", "addEnumValue", "renameEnumValue"} {
		if !operations[kind] {
			t.Fatal("shared type fixture omitted an operation")
		}
	}
	if !emptyValue {
		t.Fatal("shared type fixture lost empty-label presence")
	}
	seenEmptyDependencies, seenEmptyValues, seenIncompleteValues := false, false, false
	for index, raw := range fixture.Responses {
		var response Response
		if json.Unmarshal(raw, &response) != nil || response.Type != "query.result" {
			t.Fatalf("invalid type response fixture %d", index)
		}
		if response.SQL != "" {
			t.Fatal("type SQL preview became read provenance")
		}
		switch response.RequestID {
		case "types-details":
			if len(response.Columns) != 14 || len(response.Rows) != 1 || *response.Rows[0][7] != "complete" {
				t.Fatal("type details lost its fixed response shape")
			}
		case "types-values":
			if len(response.Rows) != 3 || response.Rows[1][0] == nil || *response.Rows[1][0] != "" || *response.Rows[1][2] != "1.5" {
				t.Fatal("ordered enum fixture lost empty labels or fractional sort order")
			}
		case "types-dependencies":
			if len(response.Columns) != 12 || len(response.Rows) != 2 || response.Rows[0][3] != nil || *response.Rows[0][8] != "2" {
				t.Fatal("dependency fixture lost subobjects or optional simple names")
			}
		case "types-dependencies-empty":
			seenEmptyDependencies = !response.Truncated && len(response.Rows) == 0 && len(response.Columns) == 12
		case "types-values-empty":
			seenEmptyValues = !response.Truncated && len(response.Rows) == 0 && len(response.Columns) == 3
		case "types-values-partial":
			seenIncompleteValues = response.Truncated && len(response.Rows) == 0 && response.RowCount > 0
		case "types-add-empty":
			if len(response.Columns) != 2 || response.Columns[0].Name != "sql" || len(response.Rows) != 1 {
				t.Fatal("type preview fixture lost its SQL text cell")
			}
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			t.Fatal("cannot encode type response")
		}
		var before, after any
		if json.Unmarshal(raw, &before) != nil || json.Unmarshal(encoded, &after) != nil || !reflect.DeepEqual(before, after) {
			t.Fatalf("type response fixture %d changed wire shape", index)
		}
	}
	if !seenEmptyDependencies || !seenEmptyValues || !seenIncompleteValues {
		t.Fatal("type fixtures omitted empty-versus-incomplete catalog states")
	}
}
