package protocol

import (
	"dbeer/helper/internal/syncplan"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSynchronizationPlanSharedWire(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/synchronization-plan-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version    int               `json:"version"`
		Capability string            `json:"capability"`
		Commands   []json.RawMessage `json:"commands"`
		Responses  []json.RawMessage `json:"responses"`
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != Version || fixture.Capability != syncplan.Capability || len(fixture.Commands) != 2 || len(fixture.Responses) != 2 {
		t.Fatal("invalid synchronization fixture")
	}
	for _, raw := range fixture.Commands {
		command, err := ParseCommand(raw)
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := json.Marshal(command)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := ParseCommand(encoded); err != nil {
			t.Fatal("command failed round trip")
		}
	}
	for _, raw := range fixture.Responses {
		var envelope struct {
			Type      string                    `json:"type"`
			RequestID string                    `json:"requestId"`
			Schema    *SchemaComparisonResponse `json:"schemaComparison"`
			Data      *DataComparisonResponse   `json:"dataComparison"`
		}
		if json.Unmarshal(raw, &envelope) != nil {
			t.Fatal("invalid response")
		}
		var plan *syncplan.Plan
		if envelope.Schema != nil {
			plan = envelope.Schema.Plan
		} else if envelope.Data != nil {
			plan = envelope.Data.Plan
		}
		if plan == nil || plan.Validate() != nil {
			t.Fatal("invalid plan")
		}
		encoded, err := json.Marshal(Response{Type: envelope.Type, RequestID: envelope.RequestID, SchemaComparison: envelope.Schema, DataComparison: envelope.Data})
		if err != nil {
			t.Fatal(err)
		}
		var original, roundTrip any
		_ = json.Unmarshal(raw, &original)
		_ = json.Unmarshal(encoded, &roundTrip)
		a, _ := json.Marshal(original)
		b, _ := json.Marshal(roundTrip)
		if string(a) != string(b) {
			t.Fatal("response failed round trip")
		}
	}
}

func TestSynchronizationPlanRejectsUnboundAndUnexpectedFields(t *testing.T) {
	for _, kind := range []string{"schema", "data"} {
		prefix := `{"type":"` + kind + `.plan","requestId":"plan","` + kind + `Comparison":{`
		body := `"jobId":"job","modelDigest":"` + strings.Repeat("a", 64) + `"`
		for _, fields := range []string{
			`"jobId":"job"`, `"modelDigest":"` + strings.Repeat("a", 64) + `"`,
			strings.Replace(body, strings.Repeat("a", 64), strings.Repeat("A", 64), 1),
			strings.Replace(body, strings.Repeat("a", 64), "oid:42", 1),
			body + `,"offset":0`, body + `,"sql":"DELETE FROM records"`,
			body + `,"modelDigest":"` + strings.Repeat("b", 64) + `"`,
		} {
			if _, err := ParseCommand([]byte(prefix + fields + `}}`)); err == nil {
				t.Fatal("invalid plan request admitted")
			}
		}
		if _, err := ParseCommand([]byte(strings.TrimSuffix(prefix+body+`}}`, "}") + `,"sql":"SELECT 1"}`)); err == nil {
			t.Fatal("foreign command fields admitted")
		}
	}
}
