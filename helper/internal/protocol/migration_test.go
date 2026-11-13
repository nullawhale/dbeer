package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestMigrationSharedContract(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/table-structure-migrations-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Valid   []json.RawMessage
		Invalid []string
	}
	if json.Unmarshal(raw, &fixture) != nil {
		t.Fatal("invalid fixture")
	}
	for i, raw := range fixture.Valid {
		if _, err := ParseCommand(raw); err != nil {
			t.Errorf("valid migration %d rejected: %v", i, err)
		}
	}
	for i, raw := range fixture.Invalid {
		if _, err := ParseCommand([]byte(raw)); err == nil {
			t.Errorf("invalid migration %d accepted", i)
		}
	}
}
func TestMigrationExactGrantCannotHideSQL(t *testing.T) {
	valid := `[{"type":"structure.migration.apply","structure":{"planId":"p","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executionId":"e"}}]`
	if _, ok := parseOperations([]byte(valid)); !ok {
		t.Fatal("exact migration assessment rejected")
	}
	for _, raw := range []string{`[{"type":"structure.migration.apply","sql":"DROP TABLE hidden","structure":{"planId":"p","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executionId":"e"}}]`, `[{"type":"execute","sql":"SELECT 1","structure":{"planId":"p","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executionId":"e"}}]`} {
		if _, ok := parseOperations([]byte(raw)); ok {
			t.Fatal("mixed migration authority accepted")
		}
	}
}
