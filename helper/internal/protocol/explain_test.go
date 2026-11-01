package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestExplainSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-v1/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Version         int
		Commands        []json.RawMessage
		InvalidCommands []struct {
			ID      string
			Command json.RawMessage
		}
		Results        []ExplainResult
		InvalidResults []struct {
			ID     string
			Result ExplainResult
		}
	}
	if json.Unmarshal(data, &f) != nil || f.Version != 1 {
		t.Fatal("fixture")
	}
	for i, raw := range f.Commands {
		if _, err := ParseCommand(raw); err != nil {
			t.Fatalf("valid command %d", i)
		}
	}
	for _, item := range f.InvalidCommands {
		if _, err := ParseCommand(item.Command); err == nil {
			t.Fatalf("accepted %s", item.ID)
		}
	}
	for i, r := range f.Results {
		if !r.Valid() {
			t.Fatalf("valid result %d", i)
		}
	}
	for _, item := range f.InvalidResults {
		if item.Result.Valid() {
			t.Fatalf("accepted %s", item.ID)
		}
	}
	for _, raw := range []string{`{"type":"explain.run","requestId":"r","sessionId":"s","queryId":"q","explain":{"sql":"SELECT 1","mode":"plan","mode":"analyze"}}`, `{"type":"operation.assess","requestId":"r","sessionId":"s","queryId":"q","operations":[{"type":"execute","sql":"SELECT 1","explain":{"sql":"SELECT 1","mode":"plan"}}]}`} {
		if _, err := ParseCommand([]byte(raw)); err == nil {
			t.Fatal("ambiguous request accepted")
		}
	}
}
