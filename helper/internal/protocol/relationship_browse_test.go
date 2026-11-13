package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestSQLiteRelationshipScopeSharedStrictContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/sqlite-relationship-scope-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Valid   []json.RawMessage
		Invalid []string
	}
	if json.Unmarshal(data, &f) != nil {
		t.Fatal("invalid scope fixture")
	}
	for i, raw := range f.Valid {
		c, e := ParseCommand(raw)
		if e != nil || c.Catalog.RelationshipScope == nil || !c.Catalog.RelationshipScope.Valid() {
			t.Fatalf("valid scope %d rejected", i)
		}
	}
	for i, raw := range f.Invalid {
		if _, e := ParseCommand([]byte(raw)); e == nil {
			t.Fatalf("invalid scope %d accepted", i)
		}
	}
}
