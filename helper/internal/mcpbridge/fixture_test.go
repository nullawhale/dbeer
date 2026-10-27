package mcpbridge

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestSharedAgentProtocolFixture(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/agent-access-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version   int               `json:"version"`
		Requests  []json.RawMessage `json:"requests"`
		Responses []json.RawMessage `json:"responses"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil || fixture.Version != 1 {
		t.Fatal("invalid fixture")
	}
	methods := make(map[string]bool)
	for _, encoded := range fixture.Requests {
		var command request
		if err := json.Unmarshal(encoded, &command); err != nil {
			t.Fatal(err)
		}
		switch command.Method {
		case "hello", "connections", "catalog", "query", "cancel":
			methods[command.Method] = true
		default:
			t.Fatal("fixture includes a non-allowlisted operation")
		}
		assertJSONRoundtrip(t, encoded, command)
	}
	if len(methods) != 5 {
		t.Fatal("fixture omits an allowed method")
	}
	for _, encoded := range fixture.Responses {
		var reply response
		if err := json.Unmarshal(encoded, &reply); err != nil {
			t.Fatal(err)
		}
		assertJSONRoundtrip(t, encoded, reply)
		if len(reply.Results) != 0 {
			row := reply.Results[0].Rows[0]
			if len(row) != 5 || row[0] != nil || row[1] == nil || *row[1] != "" || *row[2] != "NULL" || *row[3] != "12345678901234567890.123456789" || *row[4] != "AP8=" || reply.Results[0].Columns[4].Encoding != "base64" {
				t.Fatal("exact fixture values changed")
			}
		}
	}
}

func assertJSONRoundtrip(t *testing.T, original []byte, value any) {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var expected, actual any
	if json.Unmarshal(original, &expected) != nil || json.Unmarshal(encoded, &actual) != nil || !reflect.DeepEqual(expected, actual) {
		t.Fatalf("protocol roundtrip changed fields: %s", encoded)
	}
}
