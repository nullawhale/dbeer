package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Additional v4 fixtures exercise the existing contract needed by all frontends.
// Export destinations are lexical fixtures, remapped for native path semantics;
// parsing never executes SQL, publishes a file or opens a database connection.
func TestSharedV4OperationContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/contract-v4.json")
	if err != nil {
		t.Fatal("cannot read shared contract fixtures")
	}
	var fixture struct {
		Version   int
		Commands  []json.RawMessage
		Responses []json.RawMessage
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != Version {
		t.Fatal("invalid fixture version")
	}
	destination := filepath.Join(t.TempDir(), "result.json")
	var remap func(any)
	remap = func(value any) {
		switch typed := value.(type) {
		case map[string]any:
			if _, ok := typed["path"]; ok {
				typed["path"] = destination
			}
			for _, child := range typed {
				remap(child)
			}
		case []any:
			for _, child := range typed {
				remap(child)
			}
		}
	}
	kinds := map[string]bool{}
	for index, raw := range fixture.Commands {
		var value any
		if json.Unmarshal(raw, &value) != nil {
			t.Fatalf("invalid command fixture %d", index)
		}
		remap(value)
		frame, _ := json.Marshal(value)
		command, err := ParseCommand(frame)
		if err != nil {
			t.Fatalf("command fixture %d failed the existing parser", index)
		}
		kinds[command.Type] = true
		if command.RequestID == "cassandra-grid-preview" && (command.Changes.Columns[0].Engine != "cassandra" || command.Changes.Changes[0].Original[2].Kind != "binary") {
			t.Fatal("lost Cassandra snapshot engine or binary value")
		}
		if command.Type == "changes.apply" && (len(command.Changes.Changes) != 3 || command.Authorization == "") {
			t.Fatal("lost typed change batch or authorization")
		}
		if command.Catalog != nil && command.Catalog.Kind == "browse" && (len(command.Catalog.Filters) != 10 || len(command.Catalog.Sort) != 2) {
			t.Fatal("lost typed browse filters")
		}
	}
	for _, kind := range []string{"catalog", "execute", "changes.preview", "changes.apply", "operation.assess", "stream.ack"} {
		if !kinds[kind] {
			t.Fatal("missing operation fixture")
		}
	}
	for index, raw := range fixture.Responses {
		var response Response
		if json.Unmarshal(raw, &response) != nil {
			t.Fatalf("invalid response fixture %d", index)
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			t.Fatalf("cannot encode response fixture %d", index)
		}
		var before, after any
		if json.Unmarshal(raw, &before) != nil || json.Unmarshal(encoded, &after) != nil {
			t.Fatal("invalid response JSON")
		}
		a, _ := json.Marshal(before)
		b, _ := json.Marshal(after)
		if string(a) != string(b) {
			t.Fatalf("response fixture %d did not preserve the wire shape", index)
		}
	}
}
