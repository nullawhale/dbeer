package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestCatalogColumnTypeEntriesSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/catalog-column-types-v1.json")
	var fixture struct {
		Version    int                        `json:"version"`
		Capability string                     `json:"capability"`
		Valid      [][]CatalogColumnTypeEntry `json:"valid"`
	}
	if err != nil || json.Unmarshal(data, &fixture) != nil || fixture.Version != Version || fixture.Capability != CatalogColumnTypesCapability || len(fixture.Valid) != 5 {
		t.Fatal("invalid catalog column fixture")
	}
	entries := fixture.Valid[0]
	if len(entries) != 2 || entries[0].Name != "é" || entries[1].Name != "e\u0301" || entries[0].Name == entries[1].Name || entries[0].NativeType == entries[1].NativeType {
		t.Fatal("ordered entries collapsed canonically equivalent identifiers or their types")
	}
}
