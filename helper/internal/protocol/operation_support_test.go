package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestSharedOperationSupportContract(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/operation-support-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version int
		Valid   []json.RawMessage
		Invalid []struct {
			ID    string
			Value json.RawMessage
		}
	}
	if err := json.Unmarshal(raw, &fixture); err != nil || fixture.Version != 1 {
		t.Fatal("invalid operation support fixture")
	}
	for _, raw := range fixture.Valid {
		var support OperationSupport
		if err := json.Unmarshal(raw, &support); err != nil || !support.Valid() {
			t.Fatalf("valid support rejected: %v", err)
		}
		encoded, err := json.Marshal(support)
		if err != nil || json.Unmarshal(encoded, &support) != nil {
			t.Fatal("support did not roundtrip")
		}
	}
	for _, fixture := range fixture.Invalid {
		var support OperationSupport
		if json.Unmarshal(fixture.Value, &support) == nil {
			t.Errorf("accepted %s", fixture.ID)
		}
	}
}

func TestOperationSupportResponseScopeAndBounds(t *testing.T) {
	support := &OperationSupport{Version: 1, Engine: "sqlite", Scope: "session", Operations: []OperationAvailability{{Operation: "execute", State: "available"}}}
	response := Response{Type: "connect.result", RequestID: "r", Engine: "sqlite", OperationSupport: support}
	if _, err := json.Marshal(response); err != nil {
		t.Fatal(err)
	}
	response.Engine = "postgresql"
	if _, err := json.Marshal(response); err == nil {
		t.Fatal("engine mismatch was accepted")
	}
	response.Engine = "sqlite"
	response.Type = "query.started"
	if _, err := json.Marshal(response); err == nil {
		t.Fatal("wrong response kind was accepted")
	}
	support.Scope = "structure"
	response.Type = "structure.load.result"
	if _, err := json.Marshal(response); err != nil {
		t.Fatal(err)
	}
	support.Operations[0] = OperationAvailability{Operation: "execute", State: "unavailable", Reason: string(make([]byte, 1025))}
	if support.Valid() {
		t.Fatal("oversized reason accepted")
	}
	support.Operations = make([]OperationAvailability, 65)
	if support.Valid() {
		t.Fatal("oversized descriptor accepted")
	}
}
