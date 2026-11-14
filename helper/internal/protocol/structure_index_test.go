package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestStructureIndexAuthoringSharedContract(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/table-structure-index-authoring-v1.json")
	if err != nil {
		t.Fatal("index authoring fixture unavailable")
	}
	var fixture struct {
		Valid   []json.RawMessage `json:"valid"`
		Invalid []string          `json:"invalid"`
	}
	if json.Unmarshal(raw, &fixture) != nil {
		t.Fatal("invalid index fixture")
	}
	for i, raw := range fixture.Valid {
		if _, err := ParseCommand(raw); err != nil {
			t.Errorf("valid index contract case %d rejected", i)
		}
	}
	for i, raw := range fixture.Invalid {
		if _, err := ParseCommand([]byte(raw)); err == nil {
			t.Errorf("invalid index contract case %d admitted", i)
		}
	}
}
func TestStructureIndexAuthoringStrictOriginalNestedShape(t *testing.T) {
	base := `{"type":"structure.preview","requestId":"r","sessionId":"s","queryId":"q","structure":{"baselineId":"b","draft":{"authoringVersion":3,"columns":[],"indexes":[{"action":"add","name":"idx","definition":{"method":"btree","terms":[{"column":"value"}]}}]}}}`
	if _, err := ParseCommand([]byte(base)); err != nil {
		t.Fatal("valid index definition rejected")
	}
	for _, raw := range []string{
		strings.Replace(base, `"column":"value"`, `"column":"value","column":"other"`, 1),
		strings.Replace(base, `"column":"value"`, `"column":"value","future":true`, 1),
		strings.Replace(base, `"column":"value"`, `"column":"value","opclass":{"schema":"pg_catalog","name":"int4_ops","future":true}`, 1),
		strings.Replace(base, `"column":"value"`, `"column":"value","options":[{"name":"flag","value":"true","future":true}]`, 1),
		strings.Replace(base, `"column":"value"`, `"column":"\ud800"`, 1),
		strings.Replace(base, `"column":"value"`, `"column":null`, 1),
		strings.Replace(base, `"method":"btree"`, `"method":"btree","options":null`, 1),
	} {
		if _, err := ParseCommand([]byte(raw)); err == nil {
			t.Fatal("invalid original advanced-index shape was admitted")
		}
	}
}
