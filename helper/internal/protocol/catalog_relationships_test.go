package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestRelationshipDiscoverySharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/relationship-discovery-v1.json")
	if err != nil {
		t.Fatal("relationship fixture unavailable")
	}
	var fixture struct {
		Valid            []json.RawMessage
		Invalid          []string
		Responses        []json.RawMessage
		InvalidResponses []string
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("relationship fixture malformed")
	}
	for index, raw := range fixture.Valid {
		if _, err := ParseCommand(raw); err != nil {
			t.Fatalf("valid relationship command %d rejected", index)
		}
	}
	for index, raw := range fixture.Invalid {
		if _, err := ParseCommand([]byte(raw)); err == nil {
			t.Fatalf("invalid relationship command %d accepted", index)
		}
	}
	for index, raw := range fixture.Responses {
		var response struct {
			CatalogMetadata CatalogMetadataReply `json:"catalogMetadata"`
		}
		if json.Unmarshal(raw, &response) != nil || !response.CatalogMetadata.Valid() {
			t.Fatalf("invalid relationship response %d", index)
		}
	}
	for index, raw := range fixture.InvalidResponses {
		var response struct {
			CatalogMetadata CatalogMetadataReply `json:"catalogMetadata"`
		}
		if json.Unmarshal([]byte(raw), &response) == nil && response.CatalogMetadata.Valid() {
			t.Fatalf("invalid canonical relationship response %d accepted", index)
		}
	}
}

func TestRelationshipDiscoveryCannotCarryLegacyPagingOrChangeIdentity(t *testing.T) {
	for _, kind := range []string{"foreignKeys", "referencingTables", "name"} {
		for _, field := range []string{`,"page":0`, `,"cursor":""`, `,"sort":[]`, `,"filters":[]`} {
			raw := `{"type":"catalog","requestId":"r","sessionId":"s","queryId":"q","catalog":{"kind":"` + kind + `","schema":"public","object":"Parent"` + field + `}}`
			if _, err := ParseCommand([]byte(raw)); err == nil {
				t.Fatalf("legacy %s accepted extra paging/filter field", kind)
			}
		}
	}
}
