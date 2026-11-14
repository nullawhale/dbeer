package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestExplainParametersSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-parameters-v1/contract.json")
	if err != nil {
		t.Fatal("missing shared Explain parameter fixture")
	}
	var f struct {
		Version         int
		Capability      string
		Commands        []json.RawMessage
		InvalidCommands []struct {
			ID      string
			Command json.RawMessage
		}
	}
	if json.Unmarshal(data, &f) != nil || f.Version != 1 || f.Capability != ExplainParametersCapability {
		t.Fatal("invalid fixture")
	}
	for i, raw := range f.Commands {
		c, err := ParseCommand(raw)
		if err != nil {
			t.Fatalf("valid command %d rejected", i)
		}
		if c.Type == "explain.run" && (!c.Explain.Valid() || len(c.Explain.Parameters) != 4) {
			t.Fatal("lost exact bindings/context")
		}
	}
	for _, item := range f.InvalidCommands {
		if _, err := ParseCommand(item.Command); err == nil {
			t.Fatalf("accepted %s", item.ID)
		}
	}
	for _, raw := range []string{`{"sql":"SELECT :n","mode":"plan","parameters":[{"name":"n","type":"text","value":"a","value":"b"}]}`, `{"sql":"SELECT 1","mode":"plan","planKind":null}`} {
		if _, err := ParseCommand([]byte(`{"type":"explain.run","requestId":"r","sessionId":"s","queryId":"q","explain":` + raw + `}`)); err == nil {
			t.Fatal("accepted ambiguous Explain request")
		}
	}
}
