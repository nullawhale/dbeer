package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestCellFilterSharedOperands(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/cell-filter-operands-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Capability string            `json:"capability"`
		Valid      []json.RawMessage `json:"valid"`
		Invalid    []json.RawMessage `json:"invalid"`
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Capability != SQLiteCellFilterCapability {
		t.Fatal("invalid fixture")
	}
	for i, raw := range fixture.Valid {
		var value CatalogFilter
		if err := json.Unmarshal(raw, &value); err != nil || !value.Valid() {
			t.Fatalf("valid operand %d rejected", i)
		}
	}
	for i, raw := range fixture.Invalid {
		var value CatalogFilter
		if json.Unmarshal(raw, &value) == nil {
			t.Fatalf("invalid operand %d accepted", i)
		}
	}
}
