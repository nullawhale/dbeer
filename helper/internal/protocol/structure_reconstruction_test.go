package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestStructureReconstructionStrictWireVersion(t *testing.T) {
	raw := `{"baselineId":"baseline","draft":{"authoringVersion":5,"columns":[{"name":"required","type":{"kind":"text"},"nullable":false,"default":{"kind":"none"}}],"backfills":[{"column":"required","expression":"'NULL'"}],"columnOrder":["required","old"],"reconstruct":true,"allowDestructive":true}}`
	if _, ok := parseStructure(json.RawMessage(raw), "structure.preview"); !ok {
		t.Fatal("valid reconstruction rejected")
	}
	bad := []string{strings.Replace(raw, `"authoringVersion":5`, `"authoringVersion":4`, 1), strings.Replace(raw, `"reconstruct":true`, `"reconstruct":null`, 1), strings.Replace(raw, `"columnOrder":["required","old"]`, `"columnOrder":null`, 1), strings.Replace(raw, `"expression":"'NULL'"`, `"expression":"'NULL'","unknown":true`, 1), strings.Replace(raw, `"backfills":[{"column":"required","expression":"'NULL'"}]`, `"backfills":[{"column":"required","expression":null}]`, 1), strings.Replace(raw, `"columnOrder":["required","old"]`, `"columnOrder":["required",null]`, 1)}
	for i, x := range bad {
		if _, ok := parseStructure(json.RawMessage(x), "structure.preview"); ok {
			t.Fatal("invalid reconstruction admitted", i)
		}
	}
}

func TestStructureReconstructionSharedContract(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/table-structure-reconstruction-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Valid   []json.RawMessage `json:"valid"`
		Invalid []string          `json:"invalid"`
	}
	if json.Unmarshal(raw, &fixture) != nil {
		t.Fatal("invalid fixture")
	}
	for i, r := range fixture.Valid {
		if _, err := ParseCommand(r); err != nil {
			t.Errorf("valid case %d rejected", i)
		}
	}
	for i, r := range fixture.Invalid {
		if _, err := ParseCommand([]byte(r)); err == nil {
			t.Errorf("invalid case %d admitted", i)
		}
	}
}
