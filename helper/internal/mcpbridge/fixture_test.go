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
		if reply.ID == "request-query" {
			row := reply.Results[0].Rows[0]
			if len(row) != 5 || row[0] != nil || row[1] == nil || *row[1] != "" || *row[2] != "NULL" || *row[3] != "12345678901234567890.123456789" || *row[4] != "AP8=" || reply.Results[0].Columns[4].Encoding != "base64" {
				t.Fatal("exact fixture values changed")
			}
			if reply.Results[0].AffectedRowCountKnown != nil || reply.Results[0].DisplayNotice != "" {
				t.Fatal("legacy fixture gained inferred result metadata")
			}
		}
		switch reply.ID {
		case "request-list":
			if reply.Connections[0].QueryLanguage != "" || reply.Connections[0].ReadOnlyEnforcement != "" {
				t.Fatal("legacy fixture gained inferred connection capabilities")
			}
		case "request-list-engines":
			languages := map[string]string{"postgresql": "sql", "mysql": "sql", "cassandra": "cql", "mongodb": "mongodb-json"}
			if len(reply.Connections) != len(languages) {
				t.Fatal("fixture omits an engine")
			}
			for _, connection := range reply.Connections {
				if connection.QueryLanguage != languages[connection.Engine] || connection.ReadOnlyEnforcement == "" {
					t.Fatal("connection language or readonly scope changed")
				}
			}
		case "request-mongodb-fields":
			result := reply.Results[0]
			if result.AffectedRowCountKnown == nil || *result.AffectedRowCountKnown || result.DisplayNotice == "" || *result.Rows[0][2] != "sampled" {
				t.Fatal("sampled fields became an exhaustive schema or known affected count")
			}
		case "request-mongodb-documents":
			result := reply.Results[0]
			if result.AffectedRowCountKnown == nil || *result.AffectedRowCountKnown || result.Columns[0].Type != "BSON document" {
				t.Fatal("MongoDB result model changed")
			}
			var row struct {
				N struct {
					Number string `json:"$numberLong"`
				} `json:"n"`
				Amount struct {
					Decimal string `json:"$numberDecimal"`
				} `json:"amount"`
				Payload struct {
					Binary struct {
						Base64 string `json:"base64"`
					} `json:"$binary"`
				} `json:"payload"`
			}
			if json.Unmarshal([]byte(*result.Rows[0][0]), &row) != nil || row.N.Number != "9007199254740993" || row.Amount.Decimal != "12345678901234567890.123456789" || row.Payload.Binary.Base64 != "AP8=" {
				t.Fatal("MongoDB canonical BSON values changed")
			}
		case "request-cql-write":
			result := reply.Results[0]
			if result.AffectedRowCountKnown == nil || *result.AffectedRowCountKnown || result.RowCount != 0 {
				t.Fatal("Cassandra missing affected count became a confirmed zero")
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
