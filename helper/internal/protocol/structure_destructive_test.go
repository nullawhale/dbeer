package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestStructureDestructiveSharedContract(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/table-structure-destructive-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Valid   []json.RawMessage `json:"valid"`
		Invalid []string          `json:"invalid"`
	}
	if json.Unmarshal(raw, &fixture) != nil {
		t.Fatal("bad fixture")
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
func TestStructureValidationRequestAndGrantCannotMixApply(t *testing.T) {
	raw := `{"type":"structure.validate","requestId":"r","sessionId":"s","queryId":"q","structure":{"validation":{"planId":"p","digest":"` + strings.Repeat("a", 64) + `","executionId":"v"}}}`
	if _, err := ParseCommand([]byte(raw)); err != nil {
		t.Fatal("valid validation request rejected")
	}
	for _, bad := range []string{strings.Replace(raw, `"validation":`, `"apply":`, 1), strings.Replace(raw, `"executionId":"v"`, `"executionId":"v","digest":"`+strings.Repeat("b", 64)+`"`, 1), strings.Replace(raw, `"structure":{`, `"sql":"SELECT 1","structure":{`, 1)} {
		if _, err := ParseCommand([]byte(bad)); err == nil {
			t.Fatal("mixed, duplicated or injected validation admitted")
		}
	}
}
