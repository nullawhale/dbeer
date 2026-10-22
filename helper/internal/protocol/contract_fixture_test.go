package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Native v5 fixtures exercise existing operations and the SSH runtime boundary.
// Export destinations are lexical fixtures, remapped for native path semantics;
// parsing never executes SQL, publishes a file or opens a database connection.
func TestSharedV5OperationContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/contract-v5.json")
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
	foreignKeyRequest, foreignKeyResponse := false, false
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
		if command.RequestID == "foreign-keys-1" {
			foreignKeyRequest = command.Catalog != nil && command.Catalog.Kind == "foreignKeys" && command.Catalog.ObjectKind == "table"
			if !foreignKeyRequest {
				t.Fatal("lost structured foreign key catalog request")
			}
		}
		if command.RequestID == "cassandra-cluster-nodes" && (command.Catalog == nil || command.Catalog.Kind != "clusterNodes") {
			t.Fatal("lost Cassandra cluster snapshot request")
		}
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
	for _, kind := range []string{"catalog", "execute", "changes.preview", "changes.apply", "operation.assess", "stream.ack", "connect", "ssh.probe", "ssh.trust"} {
		if !kinds[kind] {
			t.Fatal("missing operation fixture")
		}
	}
	for index, raw := range fixture.Responses {
		var response Response
		if json.Unmarshal(raw, &response) != nil {
			t.Fatalf("invalid response fixture %d", index)
		}
		if response.RequestID == "foreign-keys-1" {
			foreignKeyResponse = true
			if response.Type != "query.result" || response.Truncated || len(response.Columns) != 6 || len(response.Rows) != 2 {
				t.Fatal("lost composite foreign key catalog response")
			}
			for row, expected := range [][]string{{"order_customer_fk", `odd"schema`, "Customers", "tenant_id", "tenant", "1"}, {"order_customer_fk", `odd"schema`, "Customers", "customer_id", "id", "2"}} {
				if len(response.Rows[row]) != len(expected) {
					t.Fatal("foreign key response lost a paired column")
				}
				for column, value := range expected {
					if response.Rows[row][column] == nil || *response.Rows[row][column] != value {
						t.Fatal("foreign key response changed constraint order or identifiers")
					}
				}
			}
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
	if !foreignKeyRequest || !foreignKeyResponse {
		t.Fatal("missing structured foreign key fixtures")
	}
}
