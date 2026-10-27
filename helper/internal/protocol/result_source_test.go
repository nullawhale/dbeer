package protocol

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestSharedResultSourceContract(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/sql-result-source-v1.json")
	if err != nil {
		t.Fatal("cannot read shared source fixture")
	}
	var fixture struct {
		Version   int
		Responses []json.RawMessage
	}
	if json.Unmarshal(raw, &fixture) != nil || fixture.Version != 1 || len(fixture.Responses) != 3 {
		t.Fatal("invalid shared source fixture")
	}
	for _, raw := range fixture.Responses {
		var response Response
		if json.Unmarshal(raw, &response) != nil || response.Source == nil {
			t.Fatal("source fixture omitted provenance")
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			t.Fatal("cannot marshal source response")
		}
		var before, after any
		if json.Unmarshal(raw, &before) != nil || json.Unmarshal(encoded, &after) != nil || !reflect.DeepEqual(before, after) {
			t.Fatal("source contract changed exact values or mappings")
		}
	}
	var result Response
	_ = json.Unmarshal(fixture.Responses[0], &result)
	if result.Source.Columns[0].TableIndex != 1 || result.Source.Columns[1].PrimaryKey != 1 || *result.Rows[0][1] != "9223372036854775807" || result.Rows[1][0] != nil {
		t.Fatal("source mapping collapsed aliases, order or exact values")
	}
}

func TestSourceOnlyAppearsOnCompletedResult(t *testing.T) {
	source := &ResultSource{ReadOnlyReason: "Read only."}
	for _, kind := range []string{"query.started", "query.chunk", "query.result", "error"} {
		response := Response{Type: kind, RequestID: "r", Source: source}
		data, err := json.Marshal(response)
		if err != nil {
			t.Fatal(err)
		}
		var fields map[string]json.RawMessage
		_ = json.Unmarshal(data, &fields)
		if (fields["source"] != nil) != (kind == "query.result") {
			t.Fatal("incomplete execution exposed source provenance")
		}
	}
	data, err := json.Marshal(ResultSet{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(data, &fields)
	var value struct{ Columns []ResultSourceColumn }
	if json.Unmarshal(fields["source"], &value) != nil || value.Columns == nil {
		t.Fatal("unsupported source needs explicit empty columns")
	}
}
