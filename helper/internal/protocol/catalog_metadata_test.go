package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestCatalogMetadataSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/catalog-metadata-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Valid     []json.RawMessage
		Invalid   []string
		Responses []json.RawMessage
	}
	if err = json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, raw := range fixture.Valid {
		if _, err := ParseCommand(raw); err != nil {
			t.Fatalf("valid command rejected: %s: %v", raw, err)
		}
	}
	for _, raw := range fixture.Invalid {
		if _, err := ParseCommand([]byte(raw)); err == nil {
			t.Fatalf("invalid command accepted: %s", raw)
		}
	}
	for _, raw := range fixture.Responses {
		var response struct {
			CatalogMetadata CatalogMetadataReply `json:"catalogMetadata"`
		}
		if err := json.Unmarshal(raw, &response); err != nil || !response.CatalogMetadata.Valid() {
			t.Fatalf("invalid response fixture: %v", err)
		}
	}
}

func TestLegacyForeignKeyPagingStillRejected(t *testing.T) {
	_, err := ParseCommand([]byte(`{"type":"catalog","requestId":"r","sessionId":"s","queryId":"q","catalog":{"kind":"foreignKeys","schema":"public","object":"orders","page":0}}`))
	if err == nil {
		t.Fatal("legacy foreignKeys accepted page field")
	}
}
